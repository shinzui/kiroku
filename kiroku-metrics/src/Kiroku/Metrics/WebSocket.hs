{-# LANGUAGE ScopedTypeVariables #-}

{- | The WebSocket endpoint for the Kiroku metrics server.

Fills the IP-3 seam EP-2 left stubbed ('Kiroku.Metrics.Server.stubWebSocketApp')
with a real 'WS.ServerApp' that dispatches on the request path:

  * @\/ws\/metrics@ — the /metrics channel/: a 'MetricsSnapshot' on connect,
    then a fresh snapshot every @wsPushIntervalUs@ microseconds; @ping@ → @pong@.
  * @\/ws\/events@ — the /event channel/: after a @subscribe_events@ message, a
    JSON message per appended 'RecordedEvent' in global-position order, live.
    Optionally replays history from a chosen @from_position@ and/or restricts to
    a single @category@.

The event tail is built on the /public/ 'EventPublisher' broadcast
('subscribePublisher') for live "from-now" delivery and the public effectful
reads ('readAllForward' / 'readCategory' via 'runStoreIO') for replay and
category filtering. It creates /no persistent subscription/ and writes nothing to
the @subscriptions@ checkpoint table — transient watchers leave no trace. See the
plan's Decision Log.

This module owns IP-4: the 'ClientMessage' / 'ServerMessage' protocol and the
explicit 'recordedEventToJSON' encoder (an orphan-free function, not a @ToJSON@
instance — 'RecordedEvent' has none and @kiroku-store@ keeps its @Types@ module
instance-light).
-}
module Kiroku.Metrics.WebSocket (
    -- * Protocol
    ClientMessage (..),
    ServerMessage (..),
    recordedEventToJSON,

    -- * Connection limiting
    WebSocketState (..),
    newWebSocketState,

    -- * The WebSocket application (the IP-3 seam)
    websocketApp,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, link)
import Control.Concurrent.STM (
    STM,
    TBQueue,
    TVar,
    atomically,
    check,
    modifyTVar',
    newTVarIO,
    readTBQueue,
    readTVar,
    writeTVar,
 )
import Control.Exception (catch, finally)
import Control.Monad (forever)
import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    Value,
    eitherDecode',
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector (Vector)
import Data.Vector qualified as V
import Network.WebSockets qualified as WS

import Kiroku.Metrics.Collector (KirokuMetrics, snapshotMetrics)
import Kiroku.Metrics.Config (MetricsServerConfig (..))
import Kiroku.Metrics.Types (MetricsSnapshot)
import Kiroku.Store (
    CategoryName (..),
    GlobalPosition (..),
    KirokuStore (..),
    RecordedEvent (..),
    readAllForward,
    readCategory,
    runStoreIO,
 )
import Kiroku.Store.Subscription.EventPublisher (
    SubscriberStatus (..),
    publisherPosition,
    subscribePublisher,
 )
import Kiroku.Store.Subscription.Types (OverflowPolicy (..))
import Kiroku.Store.Types (
    EventId (..),
    EventType (..),
    StreamId (..),
    StreamVersion (..),
 )

--------------------------------------------------------------------------------
-- Protocol (IP-4)
--------------------------------------------------------------------------------

{- | Messages from a WebSocket client to the server (tagged on a @"type"@ field).

The constructors are field-less (positional) on purpose: 'SubscribeEvents' and
'ServerMessage'\'s 'EventStreamStarted' would otherwise both define a
@fromPosition@ record selector, which collides when @Kiroku.Metrics@ re-exports
both @(..)@ lists.
-}
data ClientMessage
    = -- | Keepalive request; answered with 'Pong'.
      Ping
    | -- | (Metrics channel) request a fresh snapshot now.
      SubscribeMetrics
    | {- | (Event channel) start streaming. The first field is @from_position@
      ('Nothing' = "from now"); the second is @category@ ('Nothing' = all streams).
      -}
      SubscribeEvents !(Maybe Int64) !(Maybe Text)
    | -- | (Event channel) stop the current tail.
      UnsubscribeEvents
    deriving stock (Eq, Show)

-- | Messages from the server to a WebSocket client (tagged on a @"type"@ field).
data ServerMessage
    = -- | Answer to 'Ping'.
      Pong
    | -- | (Metrics channel) a metrics snapshot, embedded under @"metrics"@.
      Snapshot !MetricsSnapshot
    | -- | (Event channel) one appended event, embedded under @"event"@.
      Event !Value
    | {- | (Event channel) acknowledgement that streaming has begun from a
      given global position (the @from_position@ field on the wire).
      -}
      EventStreamStarted !Int64
    | -- | The connection is being torn down.
      Goodbye
    | -- | A non-fatal error message for the client.
      ErrorMsg !Text
    deriving stock (Eq, Show)

instance FromJSON ClientMessage where
    parseJSON = withObject "ClientMessage" $ \v -> do
        msgType <- v .: "type"
        case msgType :: Text of
            "ping" -> pure Ping
            "subscribe_metrics" -> pure SubscribeMetrics
            "subscribe_events" ->
                SubscribeEvents <$> v .:? "from_position" <*> v .:? "category"
            "unsubscribe_events" -> pure UnsubscribeEvents
            other -> fail ("Unknown client message type: " <> T.unpack other)

instance ToJSON ServerMessage where
    toJSON Pong = object ["type" .= ("pong" :: Text)]
    toJSON (Snapshot snap) = object ["type" .= ("snapshot" :: Text), "metrics" .= snap]
    toJSON (Event ev) = object ["type" .= ("event" :: Text), "event" .= ev]
    toJSON (EventStreamStarted p) =
        object ["type" .= ("event_stream_started" :: Text), "from_position" .= p]
    toJSON Goodbye = object ["type" .= ("goodbye" :: Text)]
    toJSON (ErrorMsg msg) = object ["type" .= ("error" :: Text), "message" .= msg]

{- | Encode a 'RecordedEvent' to a JSON 'Value' (IP-4). An explicit function
rather than a @ToJSON@ instance: 'RecordedEvent' has no instance today and a
library-level orphan is undesirable. EP-4's user guide documents this shape.
-}
recordedEventToJSON :: RecordedEvent -> Value
recordedEventToJSON e =
    object
        [ "eventId" .= unEventId e.eventId
        , "eventType" .= unEventType e.eventType
        , "streamVersion" .= unStreamVersion e.streamVersion
        , "globalPosition" .= unGlobalPosition e.globalPosition
        , "originalStreamId" .= unStreamId e.originalStreamId
        , "originalVersion" .= unStreamVersion e.originalVersion
        , "payload" .= e.payload
        , "metadata" .= e.metadata
        , "causationId" .= e.causationId
        , "correlationId" .= e.correlationId
        , "createdAt" .= e.createdAt
        ]
  where
    unEventId (EventId u) = u
    unEventType (EventType t) = t
    unStreamVersion (StreamVersion n) = n
    unGlobalPosition (GlobalPosition n) = n
    unStreamId (StreamId n) = n

--------------------------------------------------------------------------------
-- Connection limiting (mirrors shibuya-metrics)
--------------------------------------------------------------------------------

{- | Shared state bounding the number of concurrent WebSocket connections.
Allocated once per server in 'Kiroku.Metrics.Server.startMetricsServerWithStore'
and captured by 'websocketApp', so the bound is shared across connections.
-}
data WebSocketState = WebSocketState
    { connectionCount :: !(TVar Int)
    , maxConnections :: !Int
    }

-- | Create a 'WebSocketState' bounding connections at @maxConns@.
newWebSocketState :: Int -> IO WebSocketState
newWebSocketState maxConns = do
    countVar <- newTVarIO 0
    pure WebSocketState{connectionCount = countVar, maxConnections = maxConns}

-- | Try to claim a connection slot; 'True' on success.
acquireConnection :: WebSocketState -> STM Bool
acquireConnection st = do
    count <- readTVar st.connectionCount
    if count < st.maxConnections
        then writeTVar st.connectionCount (count + 1) >> pure True
        else pure False

-- | Release a connection slot.
releaseConnection :: WebSocketState -> STM ()
releaseConnection st = modifyTVar' st.connectionCount (\c -> max 0 (c - 1))

--------------------------------------------------------------------------------
-- Path dispatch
--------------------------------------------------------------------------------

data WsPath = MetricsPath | EventsPath | UnknownPath

-- | Dispatch on the request path, ignoring any query string.
dispatchPath :: BS.ByteString -> WsPath
dispatchPath raw =
    case BS.takeWhile (/= 0x3f) raw of -- 0x3f = '?'
        p
            | p == "/ws/metrics" -> MetricsPath
            | p == "/ws/events" -> EventsPath
            | otherwise -> UnknownPath

--------------------------------------------------------------------------------
-- The WebSocket application
--------------------------------------------------------------------------------

{- | The real WebSocket app filling the IP-3 seam. Closes over the config, the
collector, the store (for event streaming — EP-2 deliberately kept the store out
of the /server/ signature, so it enters here), and the shared connection-limiting
state. Each upgrade is dispatched by path; an over-capacity upgrade is rejected.
-}
websocketApp ::
    MetricsServerConfig ->
    KirokuMetrics ->
    KirokuStore ->
    WebSocketState ->
    WS.ServerApp
websocketApp cfg m store st pending =
    case dispatchPath (WS.requestPath (WS.pendingRequest pending)) of
        MetricsPath -> guarded (handleMetrics cfg m)
        EventsPath -> guarded (handleEvents cfg store)
        UnknownPath ->
            WS.rejectRequest pending "Unknown WebSocket path; use /ws/metrics or /ws/events"
  where
    guarded run = do
        acquired <- atomically (acquireConnection st)
        if not acquired
            then WS.rejectRequest pending "Too many connections"
            else
                (run pending `catch` ignoreClosed)
                    `finally` atomically (releaseConnection st)
    -- A normal client disconnect surfaces as a 'WS.ConnectionException' from the
    -- receive loop; treat it as a clean end-of-connection rather than letting it
    -- escape to the server's exception reporter.
    ignoreClosed (_ :: WS.ConnectionException) = pure ()

--------------------------------------------------------------------------------
-- Metrics channel
--------------------------------------------------------------------------------

-- | Handle a @/ws/metrics@ connection: snapshot on connect, periodic push, ping/pong.
handleMetrics :: MetricsServerConfig -> KirokuMetrics -> WS.PendingConnection -> IO ()
handleMetrics cfg m pending = do
    conn <- WS.acceptRequest pending
    WS.withPingThread conn 30 (pure ()) $ do
        sendMsg conn . Snapshot =<< snapshotMetrics m
        pushThread <- async (metricsPushLoop cfg m conn)
        link pushThread
        finally
            (metricsReceiveLoop m conn)
            (cancel pushThread >> sendMsg conn Goodbye)

-- | Periodically push a fresh snapshot every @wsPushIntervalUs@.
metricsPushLoop :: MetricsServerConfig -> KirokuMetrics -> WS.Connection -> IO ()
metricsPushLoop cfg m conn = forever $ do
    threadDelay cfg.wsPushIntervalUs
    sendMsg conn . Snapshot =<< snapshotMetrics m

-- | Answer @ping@ with @pong@ and @subscribe_metrics@ with a fresh snapshot.
metricsReceiveLoop :: KirokuMetrics -> WS.Connection -> IO ()
metricsReceiveLoop m conn = forever $ do
    cmd <- recvMsg conn
    case cmd of
        Just Ping -> sendMsg conn Pong
        Just SubscribeMetrics -> sendMsg conn . Snapshot =<< snapshotMetrics m
        _ -> pure ()

--------------------------------------------------------------------------------
-- Event channel
--------------------------------------------------------------------------------

{- | Handle a @/ws/events@ connection. The connection starts idle; a
@subscribe_events@ message starts (or restarts) a tail, @unsubscribe_events@
stops it, and @ping@ → @pong@. The tail runs in a child thread tracked in a
'TVar' so the receive loop can cancel and replace it; disconnect tears it down.
-}
handleEvents :: MetricsServerConfig -> KirokuStore -> WS.PendingConnection -> IO ()
handleEvents cfg store pending = do
    conn <- WS.acceptRequest pending
    WS.withPingThread conn 30 (pure ()) $ do
        tailVar <- newTVarIO Nothing
        let stopTail = do
                mt <- atomically (readTVar tailVar)
                for_ mt cancel
                atomically (writeTVar tailVar Nothing)
            startTail from cat = do
                stopTail
                t <- async (eventTail cfg store conn from cat)
                atomically (writeTVar tailVar (Just t))
        finally
            ( forever $ do
                cmd <- recvMsg conn
                case cmd of
                    Just Ping -> sendMsg conn Pong
                    Just (SubscribeEvents from cat) -> startTail from cat
                    Just UnsubscribeEvents -> stopTail
                    _ -> pure ()
            )
            (stopTail >> sendMsg conn Goodbye)

-- | A reasonable replay/category page size.
eventReadLimit :: Int
eventReadLimit = 500

{- | Stream events to the client. Dispatches on the request shape:

  * no @from@, no @category@: live "from-now" tail via the broadcast.
  * @from@, no @category@: replay history @(from, attach]@ then live, dropping
    broadcast events already covered by the replay.
  * any @category@: a DB-driven loop over 'readCategory' gated on the publisher
    position (the broadcast carries no stream names, so it cannot be filtered by
    category in-process — see the plan).
-}
eventTail ::
    MetricsServerConfig ->
    KirokuStore ->
    WS.Connection ->
    Maybe Int64 ->
    Maybe Text ->
    IO ()
eventTail cfg store conn mFrom mCategory =
    case mCategory of
        Just cat -> do
            start <- case mFrom of
                Just p -> pure p
                Nothing -> unGP <$> atomically (publisherPosition store.publisher)
            sendMsg conn (EventStreamStarted start)
            categoryLoop store conn (CategoryName cat) start
        Nothing -> do
            (queue, statusVar, unsubscribe) <-
                atomically (subscribePublisher store.publisher cfg.wsEventQueueCap DropOldest)
            attachPos <- unGP <$> atomically (publisherPosition store.publisher)
            flip finally unsubscribe $ do
                case mFrom of
                    Nothing -> sendMsg conn (EventStreamStarted attachPos)
                    Just p -> do
                        sendMsg conn (EventStreamStarted p)
                        replayHistory store conn p attachPos
                -- Drain the broadcast; under @from@ replay, drop events already
                -- delivered by the catch-up (globalPosition <= attachPos).
                let keep = case mFrom of
                        Nothing -> const True
                        Just _ -> \e -> unGP e.globalPosition > attachPos
                broadcastLoop conn queue statusVar keep

-- | Page history from @cursor@ up to @attachPos@ with 'readAllForward'.
replayHistory :: KirokuStore -> WS.Connection -> Int64 -> Int64 -> IO ()
replayHistory store conn = go
  where
    go cursor attachPos
        | cursor >= attachPos = pure ()
        | otherwise = do
            res <- runStoreIO store (readAllForward (GlobalPosition cursor) (fromIntegral eventReadLimit))
            case res of
                Left err -> sendMsg conn (ErrorMsg (T.pack ("replay error: " <> show err)))
                Right evs
                    | V.null evs -> pure ()
                    | otherwise -> do
                        sendEvents conn evs
                        go (unGP (V.last evs).globalPosition) attachPos

{- | Drain the broadcast queue forever, sending each kept event. Defensively
surfaces an @Overflowed@ status (not set under 'DropOldest', but handled).
-}
broadcastLoop ::
    WS.Connection ->
    -- | broadcast queue
    TBQueue (Vector RecordedEvent) ->
    TVar SubscriberStatus ->
    (RecordedEvent -> Bool) ->
    IO ()
broadcastLoop conn queue statusVar keep = forever $ do
    batch <- atomically (readTBQueue queue)
    sendEvents conn (V.filter keep batch)
    status <- atomically (readTVar statusVar)
    case status of
        Overflowed -> sendMsg conn (ErrorMsg "event stream overflowed; some events dropped")
        _ -> pure ()

{- | DB-driven category live loop. Mirrors the subscription worker's
@liveLoopDbDriven@: gate on the publisher advancing past the /last observed/
position (not the cursor) so an unmatched category does not busy-spin, then drain
the category to empty before waiting again.
-}
categoryLoop :: KirokuStore -> WS.Connection -> CategoryName -> Int64 -> IO ()
categoryLoop store conn cat startPos = go startPos 0
  where
    go cursor waitFrom = do
        pubPos <- atomically $ do
            GlobalPosition p <- publisherPosition store.publisher
            check (p > waitFrom)
            pure p
        drained <- drainTo cursor
        case drained of
            Nothing -> pure () -- a DB error already surfaced; stop the tail
            Just cursor' -> go cursor' pubPos
    drainTo cursor = do
        res <- runStoreIO store (readCategory cat (GlobalPosition cursor) (fromIntegral eventReadLimit))
        case res of
            Left err -> do
                sendMsg conn (ErrorMsg (T.pack ("category read error: " <> show err)))
                pure Nothing
            Right evs
                | V.null evs -> pure (Just cursor)
                | otherwise -> do
                    sendEvents conn evs
                    drainTo (unGP (V.last evs).globalPosition)

--------------------------------------------------------------------------------
-- Send / receive helpers
--------------------------------------------------------------------------------

-- | Send each event in a batch as an 'Event' message.
sendEvents :: WS.Connection -> Vector RecordedEvent -> IO ()
sendEvents conn = V.mapM_ (sendMsg conn . Event . recordedEventToJSON)

{- | Send a 'ServerMessage', swallowing a closed-connection exception so cleanup
in a @finally@ never re-throws on an already-dead socket.
-}
sendMsg :: WS.Connection -> ServerMessage -> IO ()
sendMsg conn msg =
    WS.sendTextData conn (encode msg)
        `catch` \(_ :: WS.ConnectionException) -> pure ()

{- | Receive and decode one 'ClientMessage'. 'Nothing' on an undecodable frame
(ignored by the caller).
-}
recvMsg :: WS.Connection -> IO (Maybe ClientMessage)
recvMsg conn = do
    raw <- WS.receiveData conn :: IO LBS.ByteString
    pure (either (const Nothing) Just (eitherDecode' raw))

-- | Unwrap a 'GlobalPosition' to its underlying 'Int64'.
unGP :: GlobalPosition -> Int64
unGP (GlobalPosition n) = n
