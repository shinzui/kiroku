module Kiroku.Test.Postgres (
    ephemeralConfig,
    withSharedMigratedPostgres,
    withMigratedTestDatabase,
    migrateTestDatabase,
) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, stateTVar)
import Control.Exception (bracket, bracket_, onException)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Monoid (Last (..))
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Migrate (defaultRunOptions, runMigrationPlan)
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Conn
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session qualified as Session
import Kiroku.Store.Migrations (kirokuMigrationPlan)
import System.Directory (createDirectoryIfMissing)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.User (getEffectiveUserID)

data SharedPostgres = SharedPostgres
    { database :: Pg.Database
    , templateName :: Text
    , nextDatabaseId :: TVar Int
    }

{- | 'Pg.defaultConfig' with @temporaryRoot@ pinned to @\/tmp\/ephpg-kiroku-\<uid\>@,
created if missing.

ephemeral-pg reaps clusters abandoned by killed runs on the next startup, but only
within the temporary root. An unset root resolves to @$TMPDIR@, which @nix develop@,
@nix-shell@, and many CI runners allocate per session, so the sweep would never see
earlier sessions' orphans. Keying the root by effective uid keeps it stable across a
user's sessions while keeping build sandboxes running as another uid out of a
developer-owned @0700@ directory. Every Kiroku suite shares this root so a run of one
suite cleans up after a killed run of another.
-}
ephemeralConfig :: IO Pg.Config
ephemeralConfig = do
    uid <- getEffectiveUserID
    let root = "/tmp/ephpg-kiroku-" <> show uid
    createDirectoryIfMissing True root
    pure Pg.defaultConfig{Pg.temporaryRoot = Last (Just root)}

{-# NOINLINE sharedPostgres #-}
sharedPostgres :: IORef (Maybe SharedPostgres)
sharedPostgres = unsafePerformIO (newIORef Nothing)

withSharedMigratedPostgres :: IO a -> IO a
withSharedMigratedPostgres action =
    bracket startSharedPostgres stopSharedPostgres $ \server ->
        bracket_
            (writeIORef sharedPostgres (Just server))
            (writeIORef sharedPostgres Nothing)
            action

withMigratedTestDatabase :: (Text -> IO a) -> IO a
withMigratedTestDatabase action = do
    mShared <- readIORef sharedPostgres
    case mShared of
        Just server -> withTemplateDatabase server action
        Nothing -> do
            config <- ephemeralConfig
            result <- Pg.withCachedConfig config Pg.defaultCacheConfig $ \db -> do
                migrateTestDatabase (Pg.connectionString db)
                action (Pg.connectionString db)
            case result of
                Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right value -> pure value

startSharedPostgres :: IO SharedPostgres
startSharedPostgres = do
    config <- ephemeralConfig
    result <- Pg.startCached config Pg.defaultCacheConfig
    db <- case result of
        Left err -> error ("Failed to start shared ephemeral PostgreSQL: " <> show err)
        Right db -> pure db
    let template = "kiroku_template"
    counter <- newTVarIO 0
    let server = SharedPostgres db template counter
    ( do
            createDatabase server template Nothing
            migrateTestDatabase (connectionStringFor db template)
            pure server
        )
        `onException` Pg.stop db

stopSharedPostgres :: SharedPostgres -> IO ()
stopSharedPostgres server = Pg.stop server.database

withTemplateDatabase :: SharedPostgres -> (Text -> IO a) -> IO a
withTemplateDatabase server action =
    bracket (createFreshDatabase server) (dropDatabase server) $ \dbName ->
        action (connectionStringFor server.database dbName)

createFreshDatabase :: SharedPostgres -> IO Text
createFreshDatabase server = do
    n <- atomically $ stateTVar server.nextDatabaseId $ \current -> (current + 1, current + 1)
    let dbName = "kiroku_test_" <> T.pack (show n)
    createDatabase server dbName (Just server.templateName)
    pure dbName

createDatabase :: SharedPostgres -> Text -> Maybe Text -> IO ()
createDatabase server dbName mTemplate =
    runAdminScript server.database $
        "CREATE DATABASE "
            <> quoteIdentifier dbName
            <> maybe "" ((" TEMPLATE " <>) . quoteIdentifier) mTemplate

dropDatabase :: SharedPostgres -> Text -> IO ()
dropDatabase server dbName =
    runAdminScript server.database $
        "DROP DATABASE IF EXISTS " <> quoteIdentifier dbName <> " WITH (FORCE)"

runAdminScript :: Pg.Database -> Text -> IO ()
runAdminScript db script = do
    pool <- Pool.acquire (poolConfig (Pg.connectionString db))
    result <- Pool.use pool (Session.script script)
    Pool.release pool
    case result of
        Left err -> error ("PostgreSQL admin script failed: " <> show err <> "\nSQL: " <> T.unpack script)
        Right () -> pure ()

connectionStringFor :: Pg.Database -> Text -> Text
connectionStringFor db dbName =
    T.unwords
        [ "host=" <> T.pack db.socketDirectory
        , "port=" <> T.pack (show db.port)
        , "dbname=" <> dbName
        , "user=" <> db.user
        ]

quoteIdentifier :: Text -> Text
quoteIdentifier ident = "\"" <> T.replace "\"" "\"\"" ident <> "\""

-- | Apply Kiroku's native component and record it in the pg-migrate ledger.
migrateTestDatabase :: Text -> IO ()
migrateTestDatabase connStr = do
    plan <- either (error . ("Invalid embedded Kiroku migration plan: " <>) . show) pure kirokuMigrationPlan
    result <- runMigrationPlan defaultRunOptions (Conn.connectionString connStr) plan
    case result of
        Left err -> error ("Failed to apply Kiroku migration plan for test database: " <> show err)
        Right _ -> pure ()

poolConfig :: Text -> Pool.Config.Config
poolConfig connStr =
    Pool.Config.settings
        [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
        , Pool.Config.size 1
        ]
