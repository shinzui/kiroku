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
    recordedEventToJSONResolved,
    errorCodeReplayFailed,
    errorCodeCategoryReadFailed,
    errorCodeEventStreamOverflowed,
    errorCodeLiveDecodeFailed,
    overflowNotice,

    -- * Tail delivery building blocks
    StreamNameCache,
    newStreamNameCache,
    streamNameCacheSize,
    resolveEventNames,
    broadcastEventsWith,
    withWorkerSlot,

    -- * Connection limiting
    WebSocketState (..),
    newWebSocketState,

    -- * The WebSocket application (the IP-3 seam)
    websocketApp,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (asyncWithUnmask, link, uninterruptibleCancel)
import Control.Concurrent.STM (
    STM,
    TVar,
    atomically,
    check,
    modifyTVar',
    newTVarIO,
    readTBQueue,
    readTVar,
    writeTVar,
 )
import Control.Exception (bracket, catch, finally, mask, mask_)
import Control.Monad (forever)
import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    Value (..),
    eitherDecode',
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (foldl', for_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq, ViewL (..), (|>))
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector (Vector)
import Data.Vector qualified as V
import Data.Word (Word64)
import Network.WebSockets qualified as WS

import Kiroku.Metrics.Collector (KirokuMetrics, snapshotMetrics)
import Kiroku.Metrics.Config (MetricsServerConfig (..))
import Kiroku.Metrics.Types (MetricsSnapshot)
import Kiroku.Store (
    CategoryName (..),
    GlobalPosition (..),
    KirokuStore (..),
    RecordedEvent (..),
    lookupStreamNames,
    readAllForward,
    readCategory,
    runStoreIO,
 )
import Kiroku.Store.Settings (DecodedBatch (..), DecodedEvent (..), decodedEventRecorded)
import Kiroku.Store.Subscription.EventPublisher (
    PublisherSubscription (..),
    SubscriberStatus (..),
    publisherPosition,
    subscribePublisherWith,
 )
import Kiroku.Store.Subscription.Types (OverflowPolicy (..))
import Kiroku.Store.Types (
    EventId (..),
    EventType (..),
    StreamId (..),
    StreamName (..),
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
    | -- | Stop periodic metrics snapshots; subscribe_metrics resumes them.
      UnsubscribeMetrics
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
    | -- | An error with a stable machine-readable code.
      CodedError !Text !Text
    deriving stock (Eq, Show)

instance FromJSON ClientMessage where
    parseJSON = withObject "ClientMessage" $ \v -> do
        msgType <- v .: "type"
        case msgType :: Text of
            "ping" -> pure Ping
            "subscribe_metrics" -> pure SubscribeMetrics
            "unsubscribe_metrics" -> pure UnsubscribeMetrics
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
    toJSON (CodedError code msg) = object ["type" .= ("error" :: Text), "code" .= code, "message" .= msg]

-- | Published error codes (human messages may change).
errorCodeReplayFailed, errorCodeCategoryReadFailed, errorCodeEventStreamOverflowed, errorCodeLiveDecodeFailed :: Text
errorCodeReplayFailed = "replay_failed"
errorCodeCategoryReadFailed = "category_read_failed"
errorCodeEventStreamOverflowed = "event_stream_overflowed"
errorCodeLiveDecodeFailed = "live_decode_failed"

-- | A notice on any counter change, including a Word64 wrap (modular subtraction).
overflowNotice :: Word64 -> Word64 -> Maybe ServerMessage
overflowNotice previous current
    | previous /= current =
        Just
            ( CodedError
                errorCodeEventStreamOverflowed
                ( "event stream overflowed; "
                    <> T.pack (show (current - previous))
                    <> " undelivered batch(es) dropped since the last notice; re-read from your last position"
                )
            )
    | otherwise = Nothing

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
    WS.withPingThread conn 30 (pure ()) $
        withWorkerSlot $ \start stop -> do
            sendMsg conn . Snapshot =<< snapshotMetrics m
            start (metricsPushLoop cfg m conn)
            metricsReceiveLoop m conn (start (metricsPushLoop cfg m conn)) stop
                `finally` (stop >> sendMsg conn Goodbye)

{- | Scope one linked worker. Creation and registration are masked, the worker
body is unmasked, and cleanup cancels and joins even during acquisition. Starting
an already occupied slot is a no-op. The receive loop is the sole slot owner.
-}
withWorkerSlot :: ((IO () -> IO ()) -> IO () -> IO a) -> IO a
withWorkerSlot body = mask $ \restore -> do
    workerVar <- newTVarIO Nothing
    let stop = mask_ $ do
            worker <- atomically (readTVar workerVar)
            for_ worker uninterruptibleCancel
            atomically (writeTVar workerVar Nothing)
        start action = mask_ $ do
            worker <- atomically (readTVar workerVar)
            case worker of
                Just _ -> pure ()
                Nothing -> do
                    child <- asyncWithUnmask (\unmask -> unmask action)
                    atomically (writeTVar workerVar (Just child))
                    link child
    restore (body start stop) `finally` stop

-- | Periodically push a fresh snapshot every @wsPushIntervalUs@.
metricsPushLoop :: MetricsServerConfig -> KirokuMetrics -> WS.Connection -> IO ()
metricsPushLoop cfg m conn = forever $ do
    threadDelay cfg.wsPushIntervalUs
    sendMsg conn . Snapshot =<< snapshotMetrics m

-- | Answer @ping@ with @pong@ and @subscribe_metrics@ with a fresh snapshot.
metricsReceiveLoop :: KirokuMetrics -> WS.Connection -> IO () -> IO () -> IO ()
metricsReceiveLoop m conn start stop = forever $ do
    cmd <- recvMsg conn
    case cmd of
        Just Ping -> sendMsg conn Pong
        Just SubscribeMetrics -> do
            sendMsg conn . Snapshot =<< snapshotMetrics m
            start
        Just UnsubscribeMetrics -> stop
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
    WS.withPingThread conn 30 (pure ()) $
        withWorkerSlot $ \start stop ->
            finally
                ( forever $ do
                    cmd <- recvMsg conn
                    case cmd of
                        Just Ping -> sendMsg conn Pong
                        Just (SubscribeEvents from cat) -> stop >> start (eventTail cfg store conn from cat)
                        Just UnsubscribeEvents -> stop
                        _ -> pure ()
                )
                (stop >> sendMsg conn Goodbye)

-- | A reasonable replay/category page size.
eventReadLimit :: Int
eventReadLimit = 500

{- | Stream events to the client. Dispatches on the request shape:

  * no @from@, no @category@: live "from-now" tail via the broadcast.
  * @from@, no @category@: replay history from @from@, tracking the highest
    delivered position, then live with the broadcast filtered to positions above
    that covered boundary. A replay read error sends an @error@ frame and ends
    the tail instead of entering live mode with a gap.
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
eventTail cfg store conn mFrom mCategory = do
    cache <- newStreamNameCache
    case mCategory of
        Just cat -> do
            start <- case mFrom of
                Just p -> pure p
                Nothing -> unGP <$> atomically (publisherPosition store.publisher)
            sendMsg conn (EventStreamStarted start)
            categoryLoop store cache conn (CategoryName cat) start
        Nothing ->
            bracket
                ( atomically $ do
                    sub <- subscribePublisherWith store.publisher cfg.wsEventQueueCap DropOldest
                    attachPos <- unGP <$> publisherPosition store.publisher
                    pure (sub, attachPos)
                )
                (unsubscribe . fst)
                $ \(sub, attachPos) ->
                    case mFrom of
                        Nothing -> do
                            sendMsg conn (EventStreamStarted attachPos)
                            broadcastEventsWith (sendMsg conn) cache (lookupNames store) sub (const True)
                        Just p -> do
                            sendMsg conn (EventStreamStarted p)
                            mCovered <- replayHistory store cache conn p attachPos
                            for_ mCovered $ \covered ->
                                broadcastEventsWith (sendMsg conn) cache (lookupNames store) sub (\e -> unGP e.globalPosition > covered)

{- | Page history from the requested position up to @attachPos@ with
'readAllForward'. Returns @Just covered@, the highest global position the
client is now guaranteed to have received (at least @attachPos@; more when the
final page read past it), or @Nothing@ after a read error, which has already
been surfaced to the client as an 'ErrorMsg'. The caller must terminate the
tail on @Nothing@ rather than continue live with a gap.
-}
replayHistory :: KirokuStore -> StreamNameCache -> WS.Connection -> Int64 -> Int64 -> IO (Maybe Int64)
replayHistory store cache conn from attachPos = go from attachPos
  where
    go cursor covered
        | cursor >= attachPos = pure (Just covered)
        | otherwise = do
            res <- runStoreIO store (readAllForward (GlobalPosition cursor) (fromIntegral eventReadLimit))
            case res of
                Left _ -> do
                    sendMsg conn (CodedError errorCodeReplayFailed "replay error: history unavailable")
                    pure Nothing
                Right evs
                    | V.null evs -> pure (Just covered)
                    | otherwise -> do
                        sendEvents store cache conn evs
                        let lastPos = unGP (V.last evs).globalPosition
                        go lastPos (max covered lastPos)

{- | Production live delivery with an injectable frame writer and name lookup.
Queue, status and counter are sampled atomically. Loss is signalled before any
surviving event, preserving the client's last contiguous recovery cursor.
-}
broadcastEventsWith ::
    (ServerMessage -> IO ()) ->
    StreamNameCache ->
    ([StreamId] -> IO (Map StreamId StreamName)) ->
    PublisherSubscription ->
    (RecordedEvent -> Bool) ->
    IO ()
broadcastEventsWith send cache lookupBatch sub keep = go 0 False
  where
    go previous warned = do
        (batch, status, dropped) <-
            atomically $
                (,,)
                    <$> readTBQueue sub.subscriptionQueue
                    <*> readTVar sub.subscriptionStatus
                    <*> readTVar sub.subscriptionDropped
        let notice = case overflowNotice previous dropped of
                Just msg -> Just msg
                Nothing | status == Overflowed && not warned -> Just (CodedError errorCodeEventStreamOverflowed "event stream overflowed; some events dropped")
                Nothing -> Nothing
        for_ notice send
        let decoded = case batch of
                UnchangedBatch events -> Right (V.filter keep events)
                TransformedBatch events -> V.mapM unwrap (V.filter (keep . decodedEventRecorded) events)
            unwrap (Decoded event) = Right event
            unwrap (Undecodable _ failure) = Left failure
        case decoded of
            Left _ -> send (CodedError errorCodeLiveDecodeFailed "live event decoding failed")
            Right events -> do
                names <- resolveEventNames cache lookupBatch events
                V.mapM_ (send . Event . recordedEventToJSONResolved names) events
                go dropped (status == Overflowed)

{- | DB-driven category live loop. Mirrors the subscription worker's
@liveLoopDbDriven@: gate on the publisher advancing past the /last observed/
position (not the cursor) so an unmatched category does not busy-spin, then drain
the category to empty before waiting again.
-}
categoryLoop :: KirokuStore -> StreamNameCache -> WS.Connection -> CategoryName -> Int64 -> IO ()
categoryLoop store cache conn cat startPos = go startPos 0
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
            Left _ -> do
                sendMsg conn (CodedError errorCodeCategoryReadFailed "category read error: events unavailable")
                pure Nothing
            Right evs
                | V.null evs -> pure (Just cursor)
                | otherwise -> do
                    sendEvents store cache conn evs
                    drainTo (unGP (V.last evs).globalPosition)

--------------------------------------------------------------------------------
-- Send / receive helpers
--------------------------------------------------------------------------------

-- | Send each event in a batch as an 'Event' message.
sendEvents :: KirokuStore -> StreamNameCache -> WS.Connection -> Vector RecordedEvent -> IO ()
sendEvents store cache conn events = do
    names <- resolveEventNames cache (lookupNames store) events
    V.mapM_ (sendMsg conn . Event . recordedEventToJSONResolved names) events

-- Typed lookup failures fall back to null names; thrown exceptions propagate.
lookupNames :: KirokuStore -> [StreamId] -> IO (Map StreamId StreamName)
lookupNames store ids = either (const Map.empty) id <$> runStoreIO store (lookupStreamNames ids)

data NameCache = NameCache !(Map StreamId StreamName) !(Seq StreamId)

-- | Per-tail FIFO name cache. Missing names are not retained. Capacity: 4096.
newtype StreamNameCache = StreamNameCache (IORef NameCache)

-- | Allocate once for a tail; dispose on unsubscribe/disconnect.
newStreamNameCache :: IO StreamNameCache
newStreamNameCache = StreamNameCache <$> newIORef (NameCache Map.empty Seq.empty)

-- | Retained map and FIFO sizes (both bounded by 4096).
streamNameCacheSize :: StreamNameCache -> IO (Int, Int)
streamNameCacheSize (StreamNameCache ref) = do
    NameCache names order <- readIORef ref
    pure (Map.size names, Seq.length order)

{- | Resolve distinct misses in at most one lookup. The temporary encoding map
contains all current-batch names even when that batch exceeds cache capacity.
The tail owns the cache; calls on one cache must be serialized.
-}
resolveEventNames :: StreamNameCache -> ([StreamId] -> IO (Map StreamId StreamName)) -> Vector RecordedEvent -> IO (Map StreamId StreamName)
resolveEventNames (StreamNameCache ref) lookupBatch events = do
    NameCache cached order <- readIORef ref
    let wanted = Set.fromList (V.toList (V.map (.originalStreamId) events))
        -- Inspect the requested ids rather than materializing all retained keys
        -- for each small batch after the cache has filled.
        missing = Set.filter (`Map.notMember` cached) wanted
    found <- if Set.null missing then pure Map.empty else Map.restrictKeys <$> lookupBatch (Set.toList missing) <*> pure missing
    let current = Map.union cached found
        inserted = foldl' (|>) order (Map.keys found)
        trimmed = evict current inserted
    trimmed `seq` writeIORef ref trimmed
    pure (Map.restrictKeys current wanted)
  where
    evict names order
        | Map.size names <= 4096 = NameCache names order
        | otherwise = case Seq.viewl order of
            oldest :< rest -> evict (Map.delete oldest names) rest
            EmptyL -> NameCache Map.empty Seq.empty

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

-- | The frozen event shape plus the resolved original name (or null).
recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value
recordedEventToJSONResolved names event = case recordedEventToJSON event of
    Object fields -> Object (KeyMap.insert "original_stream_name" (toJSON (fmap (\(StreamName name) -> name) (Map.lookup event.originalStreamId names))) fields)
    _ -> error "recordedEventToJSON must return an object"
