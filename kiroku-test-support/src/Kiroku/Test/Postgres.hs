module Kiroku.Test.Postgres (
    withSharedMigratedPostgres,
    withMigratedTestDatabase,
    migrateTestDatabase,
    findMigrationDir,
) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, stateTVar)
import Control.Exception (bracket, bracket_, onException)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Conn
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session qualified as Session
import System.Directory (doesDirectoryExist, listDirectory)
import System.IO.Unsafe (unsafePerformIO)

data SharedPostgres = SharedPostgres
    { database :: Pg.Database
    , templateName :: Text
    , nextDatabaseId :: TVar Int
    }

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
            result <- Pg.withCached $ \db -> do
                migrateTestDatabase (Pg.connectionString db)
                action (Pg.connectionString db)
            case result of
                Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right value -> pure value

startSharedPostgres :: IO SharedPostgres
startSharedPostgres = do
    result <- Pg.startCached Pg.defaultConfig Pg.defaultCacheConfig
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

{- | Apply every Kiroku migration SQL file (the bootstrap plus each forward
migration) in timestamped filename order. The files are concatenated into a
single script so the @SET search_path@ the bootstrap establishes carries into
the later migrations, then run once. Forward migrations added under
@kiroku-store-migrations/sql-migrations@ are picked up automatically.
-}
migrateTestDatabase :: Text -> IO ()
migrateTestDatabase connStr = do
    migrationDir <- findMigrationDir
    files <- sort . filter (".sql" `isSuffixOf`) <$> listDirectory migrationDir
    sqls <- mapM (\f -> TIO.readFile (migrationDir <> "/" <> f)) files
    let migrationSql = T.intercalate "\n" sqls
    pool <- Pool.acquire (poolConfig connStr)
    result <- Pool.use pool (Session.script migrationSql)
    Pool.release pool
    case result of
        Left err -> error ("Failed to apply Kiroku migration SQL for test database: " <> show err)
        Right () -> pure ()

poolConfig connStr =
    Pool.Config.settings
        [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
        , Pool.Config.size 1
        ]

{- | Locate the @kiroku-store-migrations/sql-migrations@ directory relative to a
test's working directory (which is the package dir or the repo root depending
on how the suite is invoked).
-}
findMigrationDir :: IO FilePath
findMigrationDir = go candidates
  where
    candidates =
        [ "kiroku-store-migrations/sql-migrations"
        , "../kiroku-store-migrations/sql-migrations"
        ]

    go [] = error "Could not locate kiroku-store-migrations/sql-migrations from test working directory"
    go (path : rest) = do
        exists <- doesDirectoryExist path
        if exists then pure path else go rest
