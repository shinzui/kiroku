module Kiroku.Store.Connection (
    KirokuStore (..),
    SchemaInitialization (..),
    ConnectionSettingsM (..),
    ConnectionSettings,
    defaultConnectionSettings,
    withStore,
) where

import Control.Exception (bracket)
import Control.Lens ((^.))
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Hasql.Connection.Settings qualified as Conn
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Pool.Observation (Observation)
import Hasql.Session qualified as Session
import Kiroku.Store.Notification (Notifier)
import Kiroku.Store.Notification qualified as Notifier
import Kiroku.Store.Observability (KirokuEvent)
import Kiroku.Store.Schema (initializeSchema, quoteIdentifier)
import Kiroku.Store.Settings (StoreSettings, defaultStoreSettings)
import Kiroku.Store.Subscription.EventPublisher (EventPublisher)
import Kiroku.Store.Subscription.EventPublisher qualified as Publisher

-- | Controls whether 'withStore' runs schema DDL during acquisition.
data SchemaInitialization
    = InitializeSchemaOnAcquire
    | SkipSchemaInitialization
    deriving stock (Eq, Show)

-- | Connection settings for the store, parameterized by monad.
data ConnectionSettingsM m = ConnectionSettings
    { connString :: !Text
    {- ^ PostgreSQL connection string (libpq URI or key=value format).
    Reaches libpq verbatim; no application-level parsing or
    substitution. May contain a password.
    -}
    , poolSize :: !Int
    -- ^ Connection pool size (default: 10)
    , schema :: !Text
    {- ^ PostgreSQL schema that owns every Kiroku object
    (default: @"kiroku"@).

    This field is authoritative for three things, kept in lockstep:

    * __Object location.__ When 'schemaInitialization' is
      'InitializeSchemaOnAcquire', 'Kiroku.Store.Schema.initializeSchema'
      creates this schema and installs the @streams@, @events@,
      @stream_events@, and @subscriptions@ tables (plus their indexes,
      functions, and triggers) inside it.
    * __Table resolution.__ Every pooled connection runs
      @SET search_path TO \<schema\>, pg_catalog@ before any statement,
      so the unqualified names in "Kiroku.Store.SQL" resolve to this
      schema.
    * __Notification channel.__ The
      'Kiroku.Store.Notification.Notifier' issues
      @LISTEN \<schema\>.events@ on its dedicated connection, and the
      @notify_events()@ trigger in @sql\/schema.sql@ publishes to
      @TG_TABLE_SCHEMA || \'.events\'@ — i.e., the schema in which the
      @streams@ table actually lives. Because object location and the
      listen channel both derive from this one field, those two channel
      names coincide and notification-driven subscription wakeups work.

    To run more than one isolated 'KirokuStore' against the same database
    (for example schema-per-tenant), give each one a distinct 'schema';
    each gets its own set of Kiroku tables and its own notification
    channel.
    -}
    , idleInTransactionTimeout :: !Int
    -- ^ idle_in_transaction_session_timeout in seconds (default: 30)
    , statementTimeout :: !(Maybe Int)
    {- ^ When @Just s@, set @statement_timeout = 's'@ (in seconds) on
    every pooled connection via @initSession@. Bounds the wall-clock
    runtime of any single statement; protects against pathological
    queries holding pool slots indefinitely. Default 'Nothing'
    (PostgreSQL's session default applies — typically @0@,
    meaning no timeout).

    A reasonable starting value for typical workloads is @Just 30@
    (30 seconds) — long enough to absorb GC pauses and transient
    slow disks, short enough to free the pool slot under genuine
    pathology. See @docs\/PRODUCTION-TUNING.md@ for sizing
    guidance.
    -}
    , observationHandler :: !(Maybe (Observation -> m ()))
    -- ^ Optional callback for pool connection lifecycle events
    , eventHandler :: !(Maybe (KirokuEvent -> m ()))
    {- ^ Optional callback for store-emitted operational events. See
    "Kiroku.Store.Observability" for the event taxonomy. Covers
    notifier reconnection, publisher pool errors, subscription
    lifecycle and per-phase database errors, and hard-delete
    issuance — events that 'observationHandler' (which surfaces
    @hasql-pool@'s connection-lifecycle observations) does not
    cover.

    Invoked synchronously from the originating thread (notifier
    loop, publisher loop, worker loop, store interpreter); slow
    callbacks stall those loops. For callbacks that may block, fan
    out asynchronously (e.g., write to a 'TBQueue' and drain in a
    separate thread).
    -}
    , storeSettings :: !StoreSettings
    {- ^ Interpreter-level hooks applied to 'EventData' on the append
    path and to 'RecordedEvent' on the read and subscription paths.
    Defaults to 'defaultStoreSettings' (no-op).

    See "Kiroku.Store.Settings" for the hook semantics and the
    OpenTelemetry trace-context use case that motivates this seam.
    -}
    , schemaInitialization :: !SchemaInitialization
    {- ^ Startup schema behavior. The default is
    'InitializeSchemaOnAcquire' for compatibility with existing tests and
    local development. Production deployments can run
    @kiroku-store-migrate@ first under a migration role and then use
    'SkipSchemaInitialization' for lower-privilege runtime users.
    -}
    }
    deriving stock (Generic)

-- | Connection settings defaulting to 'IO'.
type ConnectionSettings = ConnectionSettingsM IO

-- | Default connection settings.
defaultConnectionSettings :: Text -> ConnectionSettings
defaultConnectionSettings cs =
    ConnectionSettings
        { connString = cs
        , poolSize = 10
        , schema = "kiroku"
        , idleInTransactionTimeout = 30
        , statementTimeout = Nothing
        , observationHandler = Nothing
        , eventHandler = Nothing
        , storeSettings = defaultStoreSettings
        , schemaInitialization = InitializeSchemaOnAcquire
        }

-- | The store handle. Holds a connection pool, schema name, and subscription infrastructure.
data KirokuStore = KirokuStore
    { pool :: !Pool
    , schema :: !Text
    , notifier :: !Notifier
    , publisher :: !EventPublisher
    , eventHandler :: !(Maybe (KirokuEvent -> IO ()))
    {- ^ Effective event handler captured from
    'ConnectionSettingsM.eventHandler' when 'withStore' acquires
    the store. Surfaces hard-delete events emitted by
    'Kiroku.Store.Effect.runStorePool' and is the channel
    'Kiroku.Store.Subscription.subscribe' threads through to
    'Kiroku.Store.Subscription.Worker.runWorker'.
    -}
    , storeSettings :: !StoreSettings
    {- ^ Interpreter-level hooks captured from
    'ConnectionSettingsM.storeSettings' when 'withStore' acquires
    the store. Reached by 'Kiroku.Store.Effect.runStorePool' and the
    subscription publisher\/worker for every event flowing through.
    -}
    }
    deriving stock (Generic)

{- | Bracket-style store lifecycle.

Acquire phase, in order:

1. Acquire the connection pool from @hasql-pool@ with the configured
   size and the @idle_in_transaction_session_timeout@ init session.
2. Run the embedded schema DDL (@kiroku-store/sql/schema.sql@) when
   'schemaInitialization' is 'InitializeSchemaOnAcquire'. Idempotent under
   repeat starts. Failures throw 'Kiroku.Store.Schema.SchemaInitError'
   (re-exported from 'Kiroku.Store'). When 'schemaInitialization' is
   'SkipSchemaInitialization', acquisition assumes migrations already ran.
3. Start the 'Kiroku.Store.Notification.Notifier' on a dedicated
   connection: @LISTEN \<schema\>.events@.
4. Start the 'Kiroku.Store.Subscription.EventPublisher' which consumes
   notifier ticks and broadcasts new events to subscribers.

Release phase, in reverse order:

1. Cancel the 'Kiroku.Store.Subscription.EventPublisher' worker.
2. Stop the 'Kiroku.Store.Notification.Notifier' (cancel listener,
   release connection).
3. Release the pool.

The @bracket@ semantics guarantee release runs on either normal exit
or an exception in the body. The 'MonadUnliftIO' constraint matches
'Control.Exception.bracket'; consumers in pure 'IO' get an exact match,
consumers in effectful monads with an unlift in scope (e.g., a
'ReaderT'-like stack) get the same guarantee transparently.
-}
withStore :: (MonadUnliftIO m) => ConnectionSettings -> (KirokuStore -> m a) -> m a
withStore settings action = withRunInIO $ \runInIO ->
    bracket acquire release (runInIO . action)
  where
    initScript :: Text
    initScript =
        T.intercalate "; " $
            -- Resolve unqualified Kiroku table names (see "Kiroku.Store.SQL")
            -- to the configured schema on every pooled connection. Setting a
            -- not-yet-created schema is harmless: PostgreSQL does not validate
            -- search_path entries, so this is safe even before
            -- 'initializeSchema' has run on a fresh database.
            ("SET search_path TO " <> quoteIdentifier (settings ^. #schema) <> ", pg_catalog")
                : ("SET idle_in_transaction_session_timeout = '" <> T.pack (show (settings ^. #idleInTransactionTimeout)) <> "s'")
                : maybe
                    []
                    (\t -> ["SET statement_timeout = '" <> T.pack (show t) <> "s'"])
                    (settings ^. #statementTimeout)

    poolConfig :: Pool.Config.Config
    poolConfig =
        Pool.Config.settings $
            [ Pool.Config.staticConnectionSettings (Conn.connectionString (settings ^. #connString))
            , Pool.Config.size (settings ^. #poolSize)
            , Pool.Config.initSession (Session.script initScript)
            ]
                ++ maybe [] (\h -> [Pool.Config.observationHandler h]) (settings ^. #observationHandler)

    acquire = do
        p <- Pool.acquire poolConfig
        let s = settings ^. #schema
            cs = settings ^. #connString
            evtHandler = settings ^. #eventHandler
            stSettings = settings ^. #storeSettings
        case settings ^. #schemaInitialization of
            InitializeSchemaOnAcquire -> initializeSchema p s
            SkipSchemaInitialization -> pure ()
        -- Start Notifier (dedicated LISTEN connection)
        n <- Notifier.startNotifier cs s evtHandler
        -- Start EventPublisher (depends on Notifier's TChan)
        pub <- Publisher.startPublisher p (Notifier.tickChan n) evtHandler stSettings
        pure
            KirokuStore
                { pool = p
                , schema = s
                , notifier = n
                , publisher = pub
                , eventHandler = evtHandler
                , storeSettings = stSettings
                }

    release store = do
        -- Stop in reverse order: Publisher first, then Notifier, then pool
        Publisher.stopPublisher (store ^. #publisher)
        Notifier.stopNotifier (store ^. #notifier)
        Pool.release (store ^. #pool)
