module Kiroku.Store.Notification (
    Notifier (..),
    NotifierStartError (..),
    startNotifier,
    stopNotifier,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TChan, TVar, atomically, modifyTVar', newBroadcastTChanIO, newTVarIO, readTVarIO, writeTChan, writeTVar)
import Control.Exception (Exception, SomeException, asyncExceptionFromException, bracketOnError, catch, throwIO, toException)
import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Word (Word64)
import Hasql.Connection (Connection)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Errors (ConnectionError)
import Hasql.Notifications (PgIdentifier, toPgIdentifier, waitForNotifications)
import Hasql.Notifications qualified as Notifications
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, unpreparable)
import Kiroku.Store.Observability (KirokuEvent (..))

{- | A Notifier manages a dedicated PostgreSQL connection for LISTEN/NOTIFY.
It writes a @()@ tick to a broadcast 'TChan' on every notification,
allowing subscribers to wake without polling.

The current connection is held in a 'TVar' so that
'Kiroku.Store.Notification.stopNotifier' releases whichever connection
the listener loop most recently acquired (rather than the original one,
which may have been replaced by reconnection).
-}
data Notifier = Notifier
    { tickChan :: !(TChan ())
    -- ^ Broadcast channel; consumers must use 'dupTChan' to get a personal copy
    , listenerThread :: !(Async ())
    -- ^ The async thread running the LISTEN loop
    , listenerConnRef :: !(TVar Connection)
    {- ^ The /current/ dedicated listener connection. Updated by the loop on
    each successful reconnection so 'stopNotifier' always releases the
    live socket.
    -}
    , categoryGenerations :: !(TVar (Map Text Word64))
    {- ^ Per-category wake counter. The listener callback increments a
    category's entry on every NOTIFY for a stream in that category. A
    'Kiroku.Store.Subscription.Types.Category' subscription worker blocks until
    its category's counter advances, so an idle category does zero database work
    while other categories receive traffic. Notifications lost across a listener
    reconnect are reconciled by the worker's safety-poll timeout.
    -}
    }

{- | Raised by 'startNotifier' when the initial dedicated @LISTEN@
connection cannot be acquired. Carries @hasql@'s underlying
'Connection.ConnectionError' (often a TCP-level failure or an
authentication error) for diagnostics.

Replaces the prior @IOException@-via-@fail@ shape so callers can pattern
match on a typed startup exception.
-}
newtype NotifierStartError = NotifierStartError ConnectionError
    deriving stock (Show)
    deriving anyclass (Exception)

-- Cap reconnect backoff at 30 seconds; the EventPublisher's safety poll
-- runs at the same cadence, so the worst-case latency between a
-- recovered database and a re-armed subscription is bounded by the safety
-- poll regardless of the backoff. Capping here avoids unnecessary
-- additional latency under sustained outage.
maxReconnectDelayMicros :: Int
maxReconnectDelayMicros = 30_000_000

-- Compute the backoff delay (microseconds) for the @n@-th consecutive
-- failure, @n >= 1@. Schedule: 1s, 2s, 4s, 8s, 16s, 30s, 30s, ...
reconnectDelayMicros :: Int -> Int
reconnectDelayMicros n
    | n <= 0 = 1_000_000
    | otherwise = min maxReconnectDelayMicros (1_000_000 * 2 ^ (min (n - 1) 30))

{- | Start a Notifier. Acquires a dedicated connection, sets
@application_name@ to @kiroku-listener@ for operator visibility, issues
LISTEN on the @\<schema\>.events@ channel, and spawns a thread that
writes @()@ to the broadcast TChan on every notification.

On connection failure during the loop, releases the dead connection,
waits a backoff interval (capped exponential: 1s, 2s, 4s, 8s, 16s, 30s
thereafter), acquires a replacement, re-LISTENs, and resumes. The
replacement is published into 'listenerConnRef' so 'stopNotifier'
releases it on shutdown.

If an 'eventHandler' callback is supplied, the notifier emits
'Kiroku.Store.Observability.KirokuEventNotifierReconnecting' on each
attempted reconnect (with the consecutive failure count and the
underlying exception) and 'KirokuEventNotifierReconnected' on each
successful reconnect. The failure counter resets after a successful
reconnect.

On 'Async.AsyncCancelled' (from cancellation), exits cleanly.

Initial-acquire failure raises 'NotifierStartError'.
-}
startNotifier ::
    (MonadIO m) =>
    -- | libpq connection string
    Text ->
    -- | schema name (used to construct the LISTEN channel)
    Text ->
    -- | optional event handler for reconnect observability
    Maybe (KirokuEvent -> IO ()) ->
    m Notifier
startNotifier connString schema mHandler = liftIO $ do
    chan <- newBroadcastTChanIO
    catGenVar <- newTVarIO Map.empty
    conn <- acquireOrThrow connString
    let channel = toPgIdentifier (schema <> ".events")
    Notifications.listen conn channel
    connRef <- newTVarIO conn
    thread <- Async.async (listenerLoop chan catGenVar connRef channel connString mHandler)
    pure
        Notifier
            { tickChan = chan
            , listenerThread = thread
            , listenerConnRef = connRef
            , categoryGenerations = catGenVar
            }

{- | Stop the Notifier. Cancels the listener thread, waits for it to
finish, and releases whichever connection the loop is currently holding.
-}
stopNotifier :: (MonadIO m) => Notifier -> m ()
stopNotifier notifier = liftIO $ do
    Async.cancel (listenerThread notifier)
    void $ Async.waitCatch (listenerThread notifier)
    conn <- readTVarIO (listenerConnRef notifier)
    Connection.release conn

-- Internal: the listener loop. Calls 'waitForNotifications' on the current
-- connection; that call blocks indefinitely under normal operation. If it
-- returns (because the underlying 'Hasql.Connection.use' swallowed a session
-- error and produced a 'Left') or throws (because the panic propagated),
-- the loop releases the dead connection and reconnects. On async exceptions
-- it exits without releasing — 'stopNotifier' owns the final release via
-- 'listenerConnRef'.
--
-- The reconnect path takes the underlying 'SomeException' so it can carry it
-- on the 'KirokuEventNotifierReconnecting' event; the wait-returned-without-
-- exception path uses a synthetic message.
listenerLoop ::
    TChan () ->
    TVar (Map Text Word64) ->
    TVar Connection ->
    PgIdentifier ->
    Text ->
    Maybe (KirokuEvent -> IO ()) ->
    IO ()
listenerLoop chan catGenVar connRef channel connStr mHandler = go
  where
    go =
        ( do
            currentConn <- readTVarIO connRef
            waitForNotifications (handleNotification chan catGenVar) currentConn
            -- waitForNotifications returns only if the underlying connection
            -- went bad and Hasql converted the error into a Left result; in
            -- that case we must reconnect rather than spin re-invoking the
            -- same dead conn.
            reconnect 1 (toException ListenerWaitReturned)
        )
            `catch` \(e :: SomeException) ->
                case asyncExceptionFromException e of
                    Just (_ :: Async.AsyncCancelled) -> pure ()
                    Nothing -> reconnect 1 e

    reconnect attempt cause = do
        emit (KirokuEventNotifierReconnecting attempt cause)
        oldConn <- readTVarIO connRef
        Connection.release oldConn
        threadDelay (reconnectDelayMicros attempt)
        -- bracketOnError releases the freshly acquired connection if an
        -- async exception lands between acquire and the TVar write — without
        -- it the new connection would be unreachable from stopNotifier and
        -- would leak.
        result <-
            ( Right
                <$> bracketOnError
                    (acquireOrThrow connStr)
                    Connection.release
                    ( \newConn -> do
                        Notifications.listen newConn channel
                        atomically (writeTVar connRef newConn)
                    )
            )
                `catch` (\(e :: SomeException) -> pure (Left e))
        case result of
            Left e ->
                case asyncExceptionFromException e of
                    Just (_ :: Async.AsyncCancelled) -> throwIO e
                    Nothing -> reconnect (attempt + 1) e
            Right () -> do
                emit KirokuEventNotifierReconnected
                go

    emit evt = for_ mHandler ($ evt)

-- The 'waitForNotifications' callback. Wakes the publisher (the bare @()@ tick,
-- preserving the existing AllStreams broadcast path) AND bumps the originating
-- stream's category generation so a 'Kiroku.Store.Subscription.Types.Category'
-- worker blocked on that category unblocks. Both updates happen in one STM
-- transaction. The two callback arguments are the channel and the payload; we
-- ignore the channel (we only LISTEN on one) and parse the payload.
handleNotification :: TChan () -> TVar (Map Text Word64) -> ByteString -> ByteString -> IO ()
handleNotification chan catGenVar _channel payload =
    atomically $ do
        writeTChan chan ()
        modifyTVar' catGenVar (Map.insertWith (+) (categoryFromPayload payload) 1)

-- Recover the originating stream's category from a @notify_events@ payload. The
-- payload is @stream_name,stream_id,stream_version@; @stream_id@ and
-- @stream_version@ are comma-free integers, so the @stream_name@ is everything
-- except the last two comma-separated fields (rejoined, since a stream name may
-- itself contain commas). The category is then the prefix before the first @-@,
-- matching the @streams.category GENERATED ALWAYS AS split_part(stream_name,'-',1)@
-- column. A category never contains @-@, so @takeWhile (/= '-')@ is exact.
categoryFromPayload :: ByteString -> Text
categoryFromPayload payload =
    let fields = BC.split ',' payload
        streamName = BC.intercalate "," (take (max 0 (length fields - 2)) fields)
     in decodeUtf8Lenient (BC.takeWhile (/= '-') streamName)

-- A synthetic exception used when 'waitForNotifications' returns without
-- raising (hasql-notifications turned a connection error into a Left
-- result and dropped the diagnostic). The reconnect-event payload still
-- needs an exception value — this is it.
data ListenerWaitReturned = ListenerWaitReturned
    deriving stock (Show)
    deriving anyclass (Exception)

-- Internal: acquire a connection, set its application_name, or throw on failure.
-- Throws 'NotifierStartError' (which derives 'Exception') instead of the
-- prior @fail@-based 'IOException', so callers can match on a typed startup
-- exception.
acquireOrThrow :: Text -> IO Connection
acquireOrThrow connStr = do
    result <- Connection.acquire (Conn.connectionString connStr)
    case result of
        Left err -> throwIO (NotifierStartError err)
        Right conn -> do
            -- Tag the connection so operators can identify the listener in
            -- pg_stat_activity. Failures here are non-fatal — fall back to the
            -- default application_name silently rather than aborting startup.
            _ <- Connection.use conn (Session.statement () setAppNameStmt)
            pure conn

setAppNameStmt :: Statement () ()
setAppNameStmt =
    unpreparable "SET application_name = 'kiroku-listener'" E.noParams D.noResult
