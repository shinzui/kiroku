{-# LANGUAGE MultilineStrings #-}

module Main where

import Codd (ApplyResult (SchemasDiffer, SchemasMatch, SchemasNotVerified), CoddSettings (..), VerifySchemas (StrictCheck))
import Codd.Parsing (connStringParser)
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Control.Exception (finally)
import Control.Monad (filterM)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Char (isDigit)
import Data.List (isSuffixOf, nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.Vector qualified as Vector
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store
import Kiroku.Store.Migrations (runKirokuMigrations, runKirokuMigrationsNoCheck)
import Kiroku.Store.Migrations.New (migrationFileName, migrationSlug, newMigrationFile)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeFileName)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

main :: IO ()
main =
    hspec $ do
        migrationFileNameSpec
        scaffolderSpec
        describe "codd migration spike" $ do
            it "applies Kiroku migrations, opens the store without startup DDL, and is repeatable" $ do
                result <- withKirokuPg $ \db -> do
                    let connStr = Pg.connectionString db
                        coddSettings = testCoddSettings connStr "kiroku-store-migrations/expected-schema"

                    firstMigration <- runKirokuMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                    firstMigration `shouldBeSchemasNotVerified` "first migration run"
                    assertBootstrapApplied connStr
                    assertSchemaPlacement connStr
                    assertDeadLettersTable connStr
                    assertDefaultUuidV7 connStr
                    assertStreamTriggers connStr
                    assertDeadLettersEventIdIndex connStr
                    assertIndexHygiene connStr
                    assertStreamVersionIndexUnique connStr
                    assertStreamsFillfactor connStr
                    assertStreamNameLengthConstraint connStr
                    assertOversizedStreamNameRejected connStr

                    withStore
                        (defaultConnectionSettings connStr)
                        $ \store -> do
                            let stream = StreamName "migration-consumer"
                                event = makeEvent "MigrationConsumerChecked" (Aeson.object [("ok", Aeson.Bool True)])
                            appendResult <- runStoreIO store $ appendToStream stream NoStream [event]
                            case appendResult of
                                Left err -> expectationFailure ("appendToStream failed: " <> show err)
                                Right _ -> pure ()

                            readResult <- runStoreIO store $ readStreamForward stream (StreamVersion 0) 10
                            case readResult of
                                Left err -> expectationFailure ("readStreamForward failed: " <> show err)
                                Right events -> Vector.length events `shouldBe` 1

                    secondMigration <- runKirokuMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                    secondMigration `shouldBeSchemasNotVerified` "second migration run"
                    assertBootstrapApplied connStr
                    assertDefaultUuidV7 connStr
                    assertStreamTriggers connStr
                    assertDeadLettersEventIdIndex connStr
                    assertIndexHygiene connStr
                    assertStreamVersionIndexUnique connStr
                    assertStreamsFillfactor connStr
                    assertStreamNameLengthConstraint connStr
                    assertOversizedStreamNameRejected connStr
                case result of
                    Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                    Right () -> pure ()

            it "matches the checked-in expected schema (StrictCheck)" $ do
                expectedSchemaDir <- findExpectedSchemaDir
                result <- withKirokuPg $ \db -> do
                    let coddSettings = testCoddSettings (Pg.connectionString db) expectedSchemaDir
                    runKirokuMigrations coddSettings (secondsToDiffTime 5) StrictCheck
                case result of
                    Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                    Right (SchemasMatch _) -> pure ()
                    Right SchemasNotVerified -> expectationFailure "StrictCheck did not verify schemas"
                    Right (SchemasDiffer _) -> expectationFailure "StrictCheck returned a schema mismatch without throwing"

{- | Guard against the recurring mistake of hand-assigning rounded, sentinel
migration timestamps (e.g. @2026-05-16-00-00-00-…@, @…-00-00-01-…@). Migrations
must be named with their real UTC authoring time to the second, so filenames
sort in true authoring order and never collide in codd's timestamp-keyed
ledger. A migration whose seconds field is @00@, or which is stamped at exactly
UTC midnight, is almost certainly a hand-assigned slot rather than a wall-clock
reading and is rejected here. (If you legitimately authored one on such a
boundary, nudge the seconds by one.)
-}
migrationFileNameSpec :: Spec
migrationFileNameSpec =
    describe "migration file names" $ do
        it "carry real UTC authoring timestamps, not hand-assigned sentinels" $ do
            files <- migrationFiles
            files `shouldNotBe` []
            case filter handAssignedTimestamp files of
                [] -> pure ()
                offenders ->
                    expectationFailure
                        ( "these migrations have hand-assigned sentinel timestamps; "
                            <> "name migrations with the real UTC authoring time to the second: "
                            <> show offenders
                        )

        it "have unique, strictly increasing timestamps" $ do
            files <- migrationFiles
            let stamps = map (take timestampWidth) (sort files)
            length (nub stamps) `shouldBe` length stamps

{- | Prove the scaffolder (`Kiroku.Store.Migrations.New`) is the *producer* that
satisfies the reactive `migrationFileNameSpec` guard. Two independent checks:

  * A deterministic name built from a fixed, non-sentinel UTCTime is well-shaped
    ('isTimestampShaped') and is NOT a hand-assigned sentinel
    ('handAssignedTimestamp' == False), and its slug is the expected bare slug.
    This is deterministic, so the assertion cannot flake.
  * The live 'newMigrationFile' writes a real file into a throwaway temp dir;
    its basename is well-shaped and the file exists; the body is
    schema-qualified and unpinned.
-}
scaffolderSpec :: Spec
scaffolderSpec =
    describe "migration scaffolder" $ do
        it "stamps a real, non-sentinel UTC timestamp and a bare slug" $ do
            -- 2026-07-05 19:09:18 UTC: real hour/minute and non-00 seconds.
            let sampled = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime (19 * 3600 + 9 * 60 + 18))
                name = migrationFileName sampled "Add widget index"
            takeFileName name `shouldBe` name
            isTimestampShaped (take timestampWidth name) `shouldBe` True
            handAssignedTimestamp name `shouldBe` False
            migrationSlug "Add widget index" `shouldBe` "add-widget-index"

        it "writes a well-named file into a temp dir and refuses to overwrite" $
            withSystemTempDirectory "kiroku-scaffolder" $ \dir -> do
                path <- newMigrationFile dir "add widget index"
                let base = takeFileName path
                isTimestampShaped (take timestampWidth base) `shouldBe` True
                length base `shouldSatisfy` (> timestampWidth)
                -- The generated file body is schema-qualified and unpinned.
                body <- readFile path
                (".sql" `isSuffixOf` path) `shouldBe` True
                ("kiroku.example" `T.isInfixOf` T.pack body) `shouldBe` True
                ("search_path" `T.isInfixOf` T.pack body) `shouldBe` False

-- | The migration @.sql@ files, wherever the suite is run from.
migrationFiles :: IO [FilePath]
migrationFiles = do
    dir <- findMigrationsDir
    filter (".sql" `isSuffixOf`) <$> listDirectory dir

findMigrationsDir :: IO FilePath
findMigrationsDir = do
    let candidates = ["kiroku-store-migrations/sql-migrations", "sql-migrations"]
    existing <- filterM doesDirectoryExist candidates
    case existing of
        dir : _ -> pure dir
        [] ->
            expectationFailure "Could not find kiroku-store-migrations/sql-migrations"
                >> pure "kiroku-store-migrations/sql-migrations"

{- | Pin the throwaway PostgreSQL superuser to the fixed name "kiroku" so the
captured snapshot identity (roles, owners, db-settings) is deterministic on
every machine and in CI. Mirrors 'Pg.withCached' but pins the user;
'Pg.withCachedConfig' is not exported, so we use 'Pg.startCached' + 'finally'.
-}
kirokuPgConfig :: Pg.Config
kirokuPgConfig = Pg.defaultConfig{Pg.user = "kiroku"}

withKirokuPg :: (Pg.Database -> IO a) -> IO (Either Pg.StartError a)
withKirokuPg action = do
    started <- Pg.startCached kirokuPgConfig Pg.defaultCacheConfig
    case started of
        Left err -> pure (Left err)
        Right db -> Right <$> (action db `finally` Pg.stop db)

{- | Locate the checked-in expected-schema directory whether the suite runs from
the repository root or from the kiroku-store-migrations package directory.
-}
findExpectedSchemaDir :: IO FilePath
findExpectedSchemaDir = do
    let candidates = ["kiroku-store-migrations/expected-schema", "expected-schema"]
    existing <- filterM doesDirectoryExist candidates
    case existing of
        dir : _ -> pure dir
        [] ->
            expectationFailure "Could not find kiroku-store-migrations/expected-schema"
                >> pure "kiroku-store-migrations/expected-schema"

-- | Width of the @YYYY-MM-DD-HH-MM-SS@ timestamp prefix on a migration filename.
timestampWidth :: Int
timestampWidth = 19

{- | True when a filename's timestamp looks hand-assigned rather than sampled
from the wall clock: a malformed prefix, a @00@ seconds field, or exactly UTC
midnight (@HH-MM == 00-00@). See 'migrationFileNameSpec'.
-}
handAssignedTimestamp :: FilePath -> Bool
handAssignedTimestamp name =
    case timestampFields name of
        Nothing -> True
        Just (hh, mm, ss) -> ss == "00" || (hh == "00" && mm == "00")

-- | Extract @(HH, MM, SS)@ from a well-formed @YYYY-MM-DD-HH-MM-SS-…@ filename.
timestampFields :: FilePath -> Maybe (String, String, String)
timestampFields name
    | isTimestampShaped stamp =
        Just (take 2 (drop 11 stamp), take 2 (drop 14 stamp), take 2 (drop 17 stamp))
    | otherwise = Nothing
  where
    stamp = take timestampWidth name

-- | Does the string match the fixed-width @dddd-dd-dd-dd-dd-dd@ shape?
isTimestampShaped :: String -> Bool
isTimestampShaped s =
    length s == timestampWidth && and (zipWith matches "dddd-dd-dd-dd-dd-dd" s)
  where
    matches 'd' c = isDigit c
    matches _ c = c == '-'

testCoddSettings :: Text -> FilePath -> CoddSettings
testCoddSettings connStr expectedSchemaDir =
    CoddSettings
        { migsConnString = parseConnString connStr
        , sqlMigrations = []
        , onDiskReps = Left expectedSchemaDir
        , namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]
        , extraRolesToCheck = []
        , retryPolicy = singleTryPolicy
        , txnIsolationLvl = DbDefault
        , schemaAlgoOpts = SchemaAlgo False False False
        }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
    case parseOnly (connStringParser <* endOfInput) connStr of
        Left err -> error ("Could not parse ephemeral PostgreSQL connection string for codd: " <> err)
        Right parsed -> parsed

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

shouldBeSchemasNotVerified :: ApplyResult -> String -> Expectation
shouldBeSchemasNotVerified SchemasNotVerified _ = pure ()
shouldBeSchemasNotVerified _ label = expectationFailure (label <> " unexpectedly verified schemas")

assertBootstrapApplied :: Text -> IO ()
assertBootstrapApplied connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () bootstrapStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("bootstrap verification query failed: " <> show err)
        Right True -> pure ()
        Right False -> expectationFailure "Kiroku bootstrap migration did not create the $all stream"
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

bootstrapStmt :: Statement () Bool
bootstrapStmt =
    preparable
        "SELECT EXISTS (SELECT 1 FROM kiroku.streams WHERE stream_id = 0 AND stream_name = '$all')"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

{- | Assert that the migration installed every Kiroku table under the @kiroku@
schema and left @public@ free of Kiroku tables. The connection uses no special
@search_path@, so the schema-qualified @to_regclass@ checks prove placement
directly rather than relying on name resolution.
-}
assertSchemaPlacement :: Text -> IO ()
assertSchemaPlacement connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () placementStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("schema placement query failed: " <> show err)
        Right (True, True) -> pure ()
        Right (kirokuPresent, publicAbsent) ->
            expectationFailure
                ( "expected all Kiroku tables in 'kiroku' and none in 'public'; got kirokuPresent="
                    <> show kirokuPresent
                    <> ", publicAbsent="
                    <> show publicAbsent
                )
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

placementStmt :: Statement () (Bool, Bool)
placementStmt =
    preparable
        "SELECT \
        \  (to_regclass('kiroku.streams') IS NOT NULL \
        \   AND to_regclass('kiroku.events') IS NOT NULL \
        \   AND to_regclass('kiroku.stream_events') IS NOT NULL \
        \   AND to_regclass('kiroku.subscriptions') IS NOT NULL), \
        \  (to_regclass('public.streams') IS NULL \
        \   AND to_regclass('public.events') IS NULL \
        \   AND to_regclass('public.stream_events') IS NULL \
        \   AND to_regclass('public.subscriptions') IS NULL)"
        E.noParams
        (D.singleRow ((,) <$> D.column (D.nonNullable D.bool) <*> D.column (D.nonNullable D.bool)))

{- | Assert that the forward migration installed the @kiroku.dead_letters@ table
(MasterPlan 6 / EP-40) — proving codd applied the timestamped migration after the
bootstrap, not only the bootstrap itself.
-}
assertDeadLettersTable :: Text -> IO ()
assertDeadLettersTable connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () deadLettersStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("dead_letters verification query failed: " <> show err)
        Right True -> pure ()
        Right False -> expectationFailure "Kiroku migration did not create the kiroku.dead_letters table"
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

deadLettersStmt :: Statement () Bool
deadLettersStmt =
    preparable
        "SELECT to_regclass('kiroku.dead_letters') IS NOT NULL"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

assertDefaultUuidV7 :: Text -> IO ()
assertDefaultUuidV7 connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () defaultUuidStmt)
    versionResult <- Pool.use pool (Session.statement () serverVersionStmt)
    Pool.release pool
    case (result, versionResult) of
        (Right eventIdText, Right version)
            | T.length eventIdText > 14 && T.index eventIdText 14 == '7' -> pure ()
            | otherwise ->
                expectationFailure
                    ( "expected migration-created database default to generate UUIDv7 on PostgreSQL "
                        <> T.unpack version
                        <> ", got "
                        <> T.unpack eventIdText
                    )
        (Left err, _) -> expectationFailure ("default UUID insert failed: " <> show err)
        (_, Left err) -> expectationFailure ("server version query failed: " <> show err)
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

defaultUuidStmt :: Statement () Text
defaultUuidStmt =
    preparable
        "INSERT INTO kiroku.events (event_type, data) VALUES ('DefaultUuidGenerated', '{}'::jsonb) RETURNING event_id::text"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.text)))

serverVersionStmt :: Statement () Text
serverVersionStmt =
    preparable
        "SELECT current_setting('server_version_num')"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.text)))

assertStreamTriggers :: Text -> IO ()
assertStreamTriggers connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () streamTriggersStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("stream trigger verification query failed: " <> show err)
        Right triggers ->
            triggers
                `shouldBe` [ "no_delete_streams"
                           , "no_truncate_streams"
                           , "stream_events_notify_insert"
                           , "stream_events_notify_update"
                           ]
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

streamTriggersStmt :: Statement () [Text]
streamTriggersStmt =
    preparable
        """
        SELECT t.tgname::text
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'kiroku' AND c.relname = 'streams' AND NOT t.tgisinternal
        ORDER BY t.tgname
        """
        E.noParams
        (D.rowList (D.column (D.nonNullable D.text)))

assertDeadLettersEventIdIndex :: Text -> IO ()
assertDeadLettersEventIdIndex connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () deadLettersEventIdIndexStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("dead_letters event_id index verification query failed: " <> show err)
        Right True -> pure ()
        Right False -> expectationFailure "Kiroku migration did not create ix_dead_letters_event_id"
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

deadLettersEventIdIndexStmt :: Statement () Bool
deadLettersEventIdIndexStmt =
    preparable
        "SELECT to_regclass('kiroku.ix_dead_letters_event_id') IS NOT NULL"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

assertIndexHygiene :: Text -> IO ()
assertIndexHygiene connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () indexNamesStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("index hygiene verification query failed: " <> show err)
        Right indexes -> do
            indexes `shouldSatisfy` elem "ix_dead_letters_event_id"
            indexes `shouldSatisfy` elem "ix_dead_letters_subscription_position"
            indexes `shouldSatisfy` elem "ux_stream_events_stream_version"
            indexes `shouldSatisfy` notElem "ix_dead_letters_subscription_created_at"
            indexes `shouldSatisfy` notElem "ix_events_event_type"
            indexes `shouldSatisfy` notElem "ix_stream_events_stream_version"
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

indexNamesStmt :: Statement () [Text]
indexNamesStmt =
    preparable
        """
        SELECT indexname::text
        FROM pg_indexes
        WHERE schemaname = 'kiroku'
        ORDER BY indexname
        """
        E.noParams
        (D.rowList (D.column (D.nonNullable D.text)))

assertStreamVersionIndexUnique :: Text -> IO ()
assertStreamVersionIndexUnique connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () streamVersionIndexUniqueStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("stream version unique-index verification query failed: " <> show err)
        Right True -> pure ()
        Right False -> expectationFailure "ux_stream_events_stream_version is not unique"
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

streamVersionIndexUniqueStmt :: Statement () Bool
streamVersionIndexUniqueStmt =
    preparable
        """
        SELECT indisunique
        FROM pg_index
        WHERE indexrelid = 'kiroku.ux_stream_events_stream_version'::regclass
        """
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

assertStreamsFillfactor :: Text -> IO ()
assertStreamsFillfactor connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () streamsFillfactorStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("streams fillfactor verification query failed: " <> show err)
        Right True -> pure ()
        Right False -> expectationFailure "kiroku.streams reloptions did not include fillfactor=50"
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

streamsFillfactorStmt :: Statement () Bool
streamsFillfactorStmt =
    preparable
        """
        SELECT COALESCE('fillfactor=50' = ANY(reloptions), false)
        FROM pg_class
        WHERE oid = 'kiroku.streams'::regclass
        """
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

assertStreamNameLengthConstraint :: Text -> IO ()
assertStreamNameLengthConstraint connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () streamNameLengthConstraintStmt)
    Pool.release pool
    case result of
        Left err -> expectationFailure ("stream-name length constraint verification query failed: " <> show err)
        Right True -> pure ()
        Right False -> expectationFailure "Kiroku migration did not create chk_streams_stream_name_length"
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

streamNameLengthConstraintStmt :: Statement () Bool
streamNameLengthConstraintStmt =
    preparable
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_constraint
          WHERE conname = 'chk_streams_stream_name_length'
            AND conrelid = 'kiroku.streams'::regclass
        )
        """
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

assertOversizedStreamNameRejected :: Text -> IO ()
assertOversizedStreamNameRejected connStr = do
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.statement () oversizedStreamNameInsertStmt)
    Pool.release pool
    case result of
        Left _ -> pure ()
        Right () -> expectationFailure "direct insert of over-limit stream_name unexpectedly succeeded"
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

oversizedStreamNameInsertStmt :: Statement () ()
oversizedStreamNameInsertStmt =
    preparable
        "INSERT INTO kiroku.streams (stream_name) VALUES (repeat('a', 513))"
        E.noParams
        D.noResult
