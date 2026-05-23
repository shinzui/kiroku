{- | Shared fixtures and synchronization helpers for the kiroku-store
test suite.

Three groups of helpers live here:

  * Database fixture: 'withTestStore' brackets an ephemeral PostgreSQL
    instance and a 'KirokuStore'.
  * Event/wait helpers: 'makeEvent', 'waitWithTimeout', plus the
    listener-pid and TRUNCATE-rejection utilities used by the
    Notifier/Lifecycle regression tests.
  * Deterministic synchronization: 'waitForPublisher' and
    'waitForSubscriptionLive' replace 'threadDelay'-based sleeps in
    subscription tests with STM- and event-handler-driven barriers
    (per EP-6 F12/F14 and the threadDelay inventory in
    @docs\/plans\/6-test-and-benchmark-hardening-for-production-confidence.md@).
-}
module Test.Helpers (
    -- * Database fixture
    withSharedMigratedPostgres,
    withTestStore,
    withTestStoreSettings,

    -- * Event construction
    makeEvent,

    -- * Subscription wait
    waitWithTimeout,

    -- * Raw SQL helpers
    countEvents,
    insertEventUsingDefaultId,
    serverVersionNum,
    truncateRejected,
    tableExists,

    -- * Listener-pid helpers
    findListenerPid,
    waitForListenerPid,
    waitForListenerPidNotEqual,
    terminateBackend,
    listenerCount,

    -- * Deterministic synchronization
    waitForPublisher,
    waitForSubscriptionLive,
    caughtUpEventHandler,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (MVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, check)
import Control.Exception (SomeException)
import Control.Lens ((^.))
import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable, unpreparable)
import Kiroku.Store
import Kiroku.Store.Subscription.EventPublisher (publisherPosition)
import Kiroku.Test.Postgres (withMigratedTestDatabase, withSharedMigratedPostgres)

{- | Bracket that creates an ephemeral PostgreSQL database, applies the
Kiroku migrations, and provides a 'KirokuStore' handle.
-}
withTestStore :: (KirokuStore -> IO ()) -> IO ()
withTestStore = withTestStoreSettings Prelude.id

{- | Variant of 'withTestStore' that lets the caller transform the
'ConnectionSettings' before the store is opened. Used by tests that
install an 'eventHandler' or other observation hook.
-}
withTestStoreSettings :: (ConnectionSettings -> ConnectionSettings) -> (KirokuStore -> IO ()) -> IO ()
withTestStoreSettings tweak action =
    withMigratedTestDatabase $ \connStr ->
        withStore (tweak (defaultConnectionSettings connStr)) action

-- | Create a simple 'EventData' with an auto-generated id.
makeEvent :: Text -> Value -> EventData
makeEvent typ payload =
    EventData
        { eventId = Nothing
        , eventType = EventType typ
        , payload = payload
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        }

{- | Wait for a subscription with a timeout (in microseconds).
Returns 'Left' on timeout, or the subscription result.
-}
waitWithTimeout :: Int -> SubscriptionHandle -> IO (Either String (Either SomeException ()))
waitWithTimeout micros handle = do
    result <- Async.race (threadDelay micros) (wait handle)
    case result of
        Left () -> do
            cancel handle
            pure (Left "Subscription timed out")
        Right r -> pure (Right r)

{- | Count rows in the @events@ table via raw SQL. Used by hard-delete
regression tests that need to assert event payloads are actually removed
(not just unlinked).
-}
countEvents :: KirokuStore -> IO Int64
countEvents store = do
    let stmt :: Statement () Int64
        stmt =
            preparable
                "SELECT COUNT(*) FROM events"
                E.noParams
                (D.singleRow (D.column (D.nonNullable D.int8)))
    result <- Pool.use (store ^. #pool) (Session.statement () stmt)
    case result of
        Left err -> error ("countEvents failed: " <> show err)
        Right n -> pure n

{- | Insert directly into @events@ without an @event_id@ so the database
default is responsible for UUID generation. Returns the generated UUID
text; used to prove the schema-level @uuidv7()@ fallback works.
-}
insertEventUsingDefaultId :: KirokuStore -> IO Text
insertEventUsingDefaultId store = do
    let stmt :: Statement () Text
        stmt =
            preparable
                "INSERT INTO events (event_type, data) VALUES ('DefaultUuidGenerated', '{}'::jsonb) RETURNING event_id::text"
                E.noParams
                (D.singleRow (D.column (D.nonNullable D.text)))
    result <- Pool.use (store ^. #pool) (Session.statement () stmt)
    case result of
        Left err -> error ("insertEventUsingDefaultId failed: " <> show err)
        Right eventIdText -> pure eventIdText

{- | Report whether a schema-qualified relation exists, via
@to_regclass(name) IS NOT NULL@. The name is schema-qualified
(e.g. @"kiroku.streams"@ or @"public.streams"@), so the result does not
depend on the connection's @search_path@. Used by the schema-placement
tests that prove Kiroku objects install under @kiroku@ and not @public@.
-}
tableExists :: KirokuStore -> Text -> IO Bool
tableExists store qualifiedName = do
    let stmt :: Statement Text Bool
        stmt =
            preparable
                "SELECT to_regclass($1) IS NOT NULL"
                (E.param (E.nonNullable E.text))
                (D.singleRow (D.column (D.nonNullable D.bool)))
    result <- Pool.use (store ^. #pool) (Session.statement qualifiedName stmt)
    case result of
        Left err -> error ("tableExists failed: " <> show err)
        Right exists -> pure exists

-- | Return PostgreSQL's numeric server version for failure messages.
serverVersionNum :: KirokuStore -> IO Text
serverVersionNum store = do
    let stmt :: Statement () Text
        stmt =
            preparable
                "SELECT current_setting('server_version_num')"
                E.noParams
                (D.singleRow (D.column (D.nonNullable D.text)))
    result <- Pool.use (store ^. #pool) (Session.statement () stmt)
    case result of
        Left err -> error ("serverVersionNum failed: " <> show err)
        Right version -> pure version

{- | Try to TRUNCATE the named table without the GUC; returns 'True' if the
operation was rejected by the @protect_truncation@ trigger (the expected
behavior after EP-1 F6) and 'False' if it succeeded.
-}
truncateRejected :: KirokuStore -> Text -> IO Bool
truncateRejected store tableName = do
    let stmt :: Statement () ()
        stmt = unpreparable ("TRUNCATE " <> tableName) E.noParams D.noResult
    result <- Pool.use (store ^. #pool) (Session.statement () stmt)
    case result of
        Left _ -> pure True
        Right () -> pure False

-- | Look up the pid of the kiroku-listener backend in @pg_stat_activity@.
findListenerPid :: Pool.Pool -> IO (Maybe Int32)
findListenerPid pool = do
    let stmt :: Statement () (Maybe Int32)
        stmt =
            preparable
                "SELECT pid::int4 FROM pg_stat_activity WHERE application_name = 'kiroku-listener' LIMIT 1"
                E.noParams
                (D.rowMaybe (D.column (D.nonNullable D.int4)))
    result <- Pool.use pool (Session.statement () stmt)
    case result of
        Left err -> error ("findListenerPid failed: " <> show err)
        Right mPid -> pure mPid

-- | Wait until the listener appears in @pg_stat_activity@, or fail after the budget.
waitForListenerPid :: Pool.Pool -> Int -> IO Int32
waitForListenerPid pool budgetMicros
    | budgetMicros <= 0 = error "waitForListenerPid: timeout — kiroku-listener never appeared in pg_stat_activity"
    | otherwise = do
        m <- findListenerPid pool
        case m of
            Just pid -> pure pid
            Nothing -> do
                threadDelay 50_000
                waitForListenerPid pool (budgetMicros - 50_000)

-- | Wait until the listener pid in @pg_stat_activity@ differs from the supplied pid.
waitForListenerPidNotEqual :: Pool.Pool -> Int32 -> Int -> IO Int32
waitForListenerPidNotEqual pool oldPid budgetMicros
    | budgetMicros <= 0 = error "waitForListenerPidNotEqual: timeout — listener did not reconnect"
    | otherwise = do
        m <- findListenerPid pool
        case m of
            Just pid | pid /= oldPid -> pure pid
            _ -> do
                threadDelay 50_000
                waitForListenerPidNotEqual pool oldPid (budgetMicros - 50_000)

-- | Terminate the named backend pid via @pg_terminate_backend@.
terminateBackend :: Pool.Pool -> Int32 -> IO ()
terminateBackend pool pid = do
    let stmt :: Statement Int32 Bool
        stmt =
            preparable
                "SELECT pg_terminate_backend($1::int4)"
                (E.param (E.nonNullable E.int4))
                (D.singleRow (D.column (D.nonNullable D.bool)))
    result <- Pool.use pool (Session.statement pid stmt)
    case result of
        Left err -> error ("terminateBackend failed: " <> show err)
        Right _ -> pure ()

{- | Count kiroku-listener connections via a fresh connection (used after
the store has shut down, when the application pool is no longer
available).
-}
listenerCount :: Text -> IO Int64
listenerCount connStr = do
    eConn <- Connection.acquire (Conn.connectionString connStr)
    case eConn of
        Left err -> error ("listenerCount: failed to acquire verification conn: " <> show err)
        Right conn -> do
            let stmt :: Statement () Int64
                stmt =
                    preparable
                        "SELECT COUNT(*) FROM pg_stat_activity WHERE application_name = 'kiroku-listener'"
                        E.noParams
                        (D.singleRow (D.column (D.nonNullable D.int8)))
            r <- Connection.use conn (Session.statement () stmt)
            Connection.release conn
            case r of
                Left err -> error ("listenerCount: query failed: " <> show err)
                Right n -> pure n

{- | Block until the EventPublisher has ingested events at or beyond the
given 'GlobalPosition'. Replaces @threadDelay 200_000@ heuristics in
subscription catch-up tests with a deterministic STM barrier.
-}
waitForPublisher :: KirokuStore -> GlobalPosition -> IO ()
waitForPublisher store (GlobalPosition target) =
    atomically $ do
        GlobalPosition p <- publisherPosition (store ^. #publisher)
        check (p >= target)

{- | Block until the named subscription emits
'KirokuEventSubscriptionCaughtUp'. The caller passes an 'MVar' that is
wired into the test store's @eventHandler@ via 'caughtUpEventHandler'.
Replaces @threadDelay 100_000@ "wait for subscription to enter live
mode" in subscription tests.
-}
waitForSubscriptionLive :: MVar () -> IO ()
waitForSubscriptionLive = takeMVar

{- | Build an 'eventHandler' that opens the supplied 'MVar' the first
time 'KirokuEventSubscriptionCaughtUp' fires for the named subscription.
Subsequent emissions and other event types are ignored by the barrier
('tryPutMVar' guarantees idempotence). Composes with a passthrough
caller for tests that need to inspect the full event stream.
-}
caughtUpEventHandler ::
    SubscriptionName ->
    MVar () ->
    Maybe (KirokuEvent -> IO ()) ->
    KirokuEvent ->
    IO ()
caughtUpEventHandler name barrier passthrough evt = do
    case evt of
        KirokuEventSubscriptionCaughtUp n _ _
            | n == name -> () <$ tryPutMVar barrier ()
        _ -> pure ()
    case passthrough of
        Nothing -> pure ()
        Just f -> f evt
