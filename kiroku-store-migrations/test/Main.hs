{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (finally)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.Unique (hashUnique, newUnique)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.Codd
import Database.PostgreSQL.Migrate.Internal (migrationChecksumBytes)
import Database.PostgreSQL.Migrate.Test (withMigratedDatabase)
import EphemeralPg qualified as Pg
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Errors qualified as Errors
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Kiroku.Store.Migrations
import Kiroku.Store.Migrations.History.Codd
import Kiroku.Store.Migrations.New
import Numeric qualified
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

main :: IO ()
main = hspec $ do
    describe "native Kiroku migration definition" $ do
        it "tracks the ten native files in manifest order" $ do
            directory <- findMigrationsDirectory
            manifest <- Text.lines <$> Text.IO.readFile (directory </> "manifest")
            manifest `shouldBe` Text.pack <$> nativeMigrationFiles

        it "preserves every legacy payload byte recorded by migrations.lock" $ do
            directory <- findMigrationsDirectory
            lockPath <- findLockfile
            lockEntries <- parseLockfile <$> Text.IO.readFile lockPath
            forM_ (zip (toList kirokuLegacyMigrationNames) nativeMigrationFiles) $ \(legacyName, nativeName) -> do
                bytes <- ByteString.readFile (directory </> nativeName)
                lookup legacyName lockEntries `shouldBe` Just (checksumText bytes)

        it "builds component kiroku and a ten-migration plan" $ do
            component <- requireRight kirokuMigrations
            component `seq` pure ()
            plan <- requirePlan
            let targetIds =
                    [ requireRight (migrationId "kiroku" (Text.pack (dropSqlSuffix file)))
                    | file <- nativeMigrationFiles
                    ]
            validateHistoryMappingTargets plan kirokuCoddHistoryMappings
                `shouldBe` Right ()
            length targetIds `shouldBe` length nativeMigrationFiles

    describe "native migration authoring" $ do
        it "creates the next numeric file and atomically appends the manifest" $
            withSystemTempDirectory "kiroku-native-authoring" $ \directory -> do
                ByteString.writeFile (directory </> "0007-existing.sql") "SELECT 7;\n"
                ByteString.writeFile (directory </> "manifest") "0007-existing.sql\n"
                created <- newMigrationFile directory "add widget index"
                path <- requireRight created
                path `shouldBe` directory </> "0008.sql"
                body <- ByteString.readFile path
                body `shouldSatisfy` ByteString.isInfixOf "forward-only"
                Text.lines <$> Text.IO.readFile (directory </> "manifest")
                    `shouldReturn` ["0007-existing.sql", "0008.sql"]

        it "refuses to overwrite a pre-existing inferred migration" $
            withSystemTempDirectory "kiroku-native-exclusive" $ \directory -> do
                ByteString.writeFile (directory </> "manifest") "0007-existing.sql\n"
                ByteString.writeFile (directory </> "0007-existing.sql") "SELECT 7;\n"
                ByteString.writeFile (directory </> "0008.sql") "SELECT 8;\n"
                created <- newMigrationFile directory "must not overwrite"
                created `shouldSatisfy` isLeft
                Text.IO.readFile (directory </> "manifest")
                    `shouldReturn` "0007-existing.sql\n"

    describe "fresh native databases" $ do
        it "applies all ten, verifies strictly, and reports AlreadyApplied on rerun" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                assertSchema connection
                let provider = providerFor connection
                rerun <- runMigrationPlanWith defaultRunOptions provider plan >>= requireMigration
                reportOutcomes rerun `shouldBe` replicate (length nativeMigrationFiles) AlreadyApplied
                verified <- verifyMigrationPlanWith defaultRunOptions provider plan >>= requireMigration
                case verified of
                    VerificationReport verificationIssues applied _ _ -> do
                        verificationIssues `shouldBe` []
                        length applied `shouldBe` length nativeMigrationFiles
            either (expectationFailure . show) pure result

        it "serializes concurrent applies through the pg-migrate advisory lock" $ do
            plan <- requirePlan
            withKirokuPg $ \database -> do
                let settings = Pg.connectionSettings database
                (first, second) <-
                    concurrently
                        (runMigrationPlan defaultRunOptions settings plan >>= requireMigration)
                        (runMigrationPlan defaultRunOptions settings plan >>= requireMigration)
                sort [reportOutcomes first, reportOutcomes second]
                    `shouldBe` sort
                        [ replicate (length nativeMigrationFiles) AppliedNow
                        , replicate (length nativeMigrationFiles) AlreadyApplied
                        ]

    describe "subscription checkpoint SQL relation" $ do
        it "publishes the frozen ordinary-view catalog contract" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                relation <- useSession connection (Session.statement () relationCatalogStatement)
                relation
                    `shouldBe` ( "v"
                               , "security_invoker=false"
                               , True
                               , "NO"
                               , "NO"
                               , "Stable read-only v1 relation of exact persisted subscription-member checkpoints; its columns and order are frozen, and its rows are unordered unless the caller supplies ORDER BY."
                               )
                columns <- useSession connection (Session.statement () relationColumnsStatement)
                columns
                    `shouldBe` [
                                   ( "subscription_name"
                                   , "text"
                                   , False
                                   , "Persisted subscription name; member zero does not distinguish a non-group subscription from member zero of a consumer group."
                                   )
                               ,
                                   ( "consumer_group_member"
                                   , "integer"
                                   , False
                                   , "Persisted consumer-group member key; member zero carries no topology classification."
                                   )
                               ,
                                   ( "checkpoint_position"
                                   , "bigint"
                                   , False
                                   , "Exact persisted global position for this subscription member; an explicit reset may move it backward or forward."
                                   )
                               ,
                                   ( "checkpoint_updated_at"
                                   , "timestamp with time zone"
                                   , False
                                   , "Time of the latest checkpoint-row upsert; it does not imply position advancement or worker liveness."
                                   )
                               ]
            either (expectationFailure . show) pure result

        it "returns zero rows for an empty checkpoint inventory" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                rows <- useSession connection (Session.statement () checkpointRowsStatement)
                rows `shouldBe` []
            either (expectationFailure . show) pure result

        it "returns exact non-null member rows and exposes reassignment only after commit" $ do
            plan <- requirePlan
            withKirokuPg $ \database -> do
                let settings = Pg.connectionSettings database
                _ <- runMigrationPlan defaultRunOptions settings plan >>= requireMigration
                withConnection settings $ \writer ->
                    withConnection settings $ \reader -> do
                        useSession writer (Session.script checkpointFixtureSql)
                        rows <- useSession reader (Session.statement () checkpointRowsStatement)
                        rows
                            `shouldBe` [ ("grouped", 0, 20, checkpointFixtureTimestamp)
                                       , ("grouped", 1, 21, checkpointFixtureTimestamp)
                                       , ("grouped", 2, 22, checkpointFixtureTimestamp)
                                       , ("ordinary", 0, 11, checkpointFixtureTimestamp)
                                       ]

                        useSession writer (Session.script "BEGIN")
                        useSession writer (Session.script checkpointAdvanceSql)
                        checkpointPosition writer `shouldReturn` 5
                        checkpointPosition reader `shouldReturn` 11
                        useSession writer (Session.script "COMMIT")
                        checkpointPosition reader `shouldReturn` 5

                        useSession writer (Session.script "BEGIN")
                        useSession writer (Session.script checkpointRegressionSql)
                        checkpointPosition writer `shouldReturn` 2
                        checkpointPosition reader `shouldReturn` 5
                        useSession writer (Session.script "ROLLBACK")
                        checkpointPosition reader `shouldReturn` 5

        it "allows view-only readers while structurally rejecting owner updates" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection ->
                withTemporaryReaderRole connection $ \role -> do
                    let identifier = quoteTestIdentifier role
                    useSession
                        connection
                        ( Session.script
                            ( "GRANT USAGE ON SCHEMA kiroku TO "
                                <> identifier
                                <> "; GRANT SELECT ON kiroku.subscription_checkpoints_v1 TO "
                                <> identifier
                                <> "; SET ROLE "
                                <> identifier
                            )
                        )
                    viewCount <- useSession connection (Session.statement () checkpointRowCountStatement)
                    viewCount `shouldBe` 0
                    privatePrivilege <- useSession connection (Session.statement () privateTablePrivilegeStatement)
                    privatePrivilege `shouldBe` False
                    directPrivateRead <- Connection.use connection (Session.statement () privateTableCountStatement)
                    directPrivateRead `shouldSatisfy` hasSqlState "42501"

                    useSession connection (Session.script "RESET ROLE")
                    ownerUpdate <- Connection.use connection (Session.statement () updatePublicViewStatement)
                    ownerUpdate `shouldSatisfy` hasSqlState "55000"
            either (expectationFailure . show) pure result

        it "preserves a downstream view while private checkpoint storage is replaced" $ do
            plan <- requirePlan
            withKirokuPg $ \database -> do
                let settings = Pg.connectionSettings database
                _ <- runMigrationPlan defaultRunOptions settings plan >>= requireMigration
                withConnection settings $ \connection -> do
                    useSession connection (Session.script downstreamReplacementFixtureSql)
                    floors <- useSession connection (Session.statement () downstreamFloorsStatement)
                    floors `shouldBe` [("dependency", 42)]

        it "pushes a subscription filter to the existing checkpoint index" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                useSession connection (Session.script checkpointPlanFixtureSql)
                version <- useSession connection (Session.statement () serverVersionStatement)
                planLines <- useSession connection (Session.statement () checkpointExplainStatement)
                let planText = Text.unlines planLines
                Text.IO.putStrLn ("PostgreSQL " <> version <> " checkpoint relation plan:\n" <> planText)
                planText `shouldSatisfy` Text.isInfixOf "ix_subscriptions_name_member"
                Text.isInfixOf "CTE Scan" planText `shouldBe` False
            either (expectationFailure . show) pure result

    describe "history retention schema" $ do
        it "publishes the exact coordinator and lease table columns" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                columns <- useSession connection (Session.statement () historyRetentionColumnsStatement)
                columns
                    `shouldBe` [ ("history_retention_coordinator", "singleton", "boolean", True)
                               , ("history_retention_leases", "lease_id", "uuid", True)
                               , ("history_retention_leases", "owner", "text", True)
                               , ("history_retention_leases", "reason", "text", True)
                               , ("history_retention_leases", "protected_through", "bigint", True)
                               , ("history_retention_leases", "created_at", "timestamp with time zone", True)
                               , ("history_retention_leases", "renewed_at", "timestamp with time zone", True)
                               , ("history_retention_leases", "expires_at", "timestamp with time zone", True)
                               , ("history_retention_leases", "released_at", "timestamp with time zone", False)
                               ]
            either (expectationFailure . show) pure result

        it "installs the singleton, checks, partial index, function, and six triggers" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                facts <- useSession connection (Session.statement () historyRetentionFactsStatement)
                facts `shouldBe` (1, 9, True, True, 6)
            either (expectationFailure . show) pure result

    describe "Codd history import" $ do
        it "imports a current codd V5 ledger, verifies, and never replays SQL" $
            importFixture "codd"

        it "imports the legacy codd_schema ledger shape" $
            importFixture "codd_schema"

        it "rejects a partial legacy row before creating the target ledger" $ do
            plan <- requirePlan
            withKirokuPg $ \database -> do
                let settings = Pg.connectionSettings database
                    provider = connectionProviderFromSettings settings
                withConnection settings $ \connection -> installCoddLedger connection "codd" True
                config <-
                    requireRight
                        (kirokuCoddSourceConfig provider True "partial fixture must fail" Confirmed)
                imported <-
                    importCoddHistory defaultImportOptions config provider plan kirokuCoddHistoryMappings
                imported `shouldSatisfy` \case
                    Left CoddPartialMigration{} -> True
                    _ -> False
                withConnection settings $ \connection -> do
                    targetExists <- useSession connection (Session.statement "pgmigrate" schemaExistsStatement)
                    targetExists `shouldBe` False

importFixture :: Text -> Expectation
importFixture sourceSchema = do
    plan <- requirePlan
    directory <- findMigrationsDirectory
    withKirokuPg $ \database -> do
        let settings = Pg.connectionSettings database
            provider = connectionProviderFromSettings settings
        withConnection settings $ \connection -> do
            applyNativeSqlFromDisk connection directory
            installCoddLedger connection sourceSchema False
        config <-
            requireRight
                (kirokuCoddSourceConfig provider True "verified Kiroku Codd cutover" Confirmed)
        first <-
            importCoddHistory defaultImportOptions config provider plan kirokuCoddHistoryMappings
                >>= requireRight
        importOutcomes first `shouldBe` replicate 7 Imported
        pendingIds <-
            traverse
                (requireRight . migrationId "kiroku")
                ["0008-schema-management-comment", "0009", "0010"]
        verifiedBeforeCanary <- verifyMigrationPlan defaultRunOptions settings plan >>= requireMigration
        case verifiedBeforeCanary of
            VerificationReport verificationIssues _ _ _ ->
                verificationIssues
                    `shouldBe` (PendingMigration <$> pendingIds)
        up <- runMigrationPlan defaultRunOptions settings plan >>= requireMigration
        reportOutcomes up `shouldBe` replicate 7 AlreadyApplied <> replicate 3 AppliedNow
        verifiedAfterCanary <- verifyMigrationPlan defaultRunOptions settings plan >>= requireMigration
        case verifiedAfterCanary of
            VerificationReport verificationIssues _ _ _ ->
                verificationIssues `shouldBe` []
        rerun <- runMigrationPlan defaultRunOptions settings plan >>= requireMigration
        reportOutcomes rerun `shouldBe` replicate (length nativeMigrationFiles) AlreadyApplied
        second <-
            importCoddHistory defaultImportOptions config provider plan kirokuCoddHistoryMappings
                >>= requireRight
        importOutcomes second `shouldBe` replicate 7 AlreadyImported
        withConnection settings $ \connection -> do
            assertSchema connection
            sourceRows <- useSession connection (Session.statement () (sourceRowCountStatement sourceSchema))
            sourceRows `shouldBe` 7
            facts <- useSession connection (Session.statement () importFactsStatement)
            facts `shouldBe` (fromIntegral (length nativeMigrationFiles), 7, True)

nativeMigrationFiles :: [FilePath]
nativeMigrationFiles =
    [ "0001-kiroku-bootstrap.sql"
    , "0002-add-subscription-dead-letters.sql"
    , "0003-notify-trigger-append-guard.sql"
    , "0004-dead-letters-event-id-index.sql"
    , "0005-index-hygiene-and-streams-fillfactor.sql"
    , "0006-stream-name-length-check.sql"
    , "0007-stream-truncate-before.sql"
    , "0008-schema-management-comment.sql"
    , "0009.sql"
    , "0010.sql"
    ]

findMigrationsDirectory :: IO FilePath
findMigrationsDirectory =
    findDirectory ["kiroku-store-migrations/migrations", "migrations"]

findLockfile :: IO FilePath
findLockfile =
    findFile ["kiroku-store-migrations/migrations.lock", "migrations.lock"]

findDirectory :: [FilePath] -> IO FilePath
findDirectory candidates = do
    existing <- filterM doesDirectoryExist candidates
    case existing of
        directory : _ -> pure directory
        [] -> expectationFailure ("could not find directory: " <> show candidates) >> pure "."

findFile :: [FilePath] -> IO FilePath
findFile candidates = do
    existing <- filterM doesFileExist candidates
    case existing of
        path : _ -> pure path
        [] -> expectationFailure ("could not find file: " <> show candidates) >> pure "."

filterM :: (value -> IO Bool) -> [value] -> IO [value]
filterM predicate = foldr step (pure [])
  where
    step value remaining = do
        matches <- predicate value
        values <- remaining
        pure (if matches then value : values else values)

parseLockfile :: Text -> [(FilePath, Text)]
parseLockfile contents =
    [ (Text.unpack filename, checksum)
    | line <- Text.lines contents
    , [checksum, filename] <- [Text.words line]
    ]

checksumText :: ByteString -> Text
checksumText =
    Text.pack
        . concatMap renderByte
        . ByteString.unpack
        . migrationChecksumBytes
        . migrationFingerprint
  where
    renderByte byte =
        case Numeric.showHex byte "" of
            [digit] -> ['0', digit]
            digits -> digits

dropSqlSuffix :: FilePath -> String
dropSqlSuffix = reverse . drop 4 . reverse

requirePlan :: IO MigrationPlan
requirePlan = requireRight kirokuMigrationPlan

requireRight :: (Show error) => Either error value -> IO value
requireRight = either (failure . show) pure

requireMigration :: (Show error) => Either error value -> IO value
requireMigration = requireRight

failure :: String -> IO value
failure message = expectationFailure message >> fail message

providerFor :: Connection.Connection -> ConnectionProvider
providerFor connection = connectionProvider (\action -> Right <$> action connection)

reportOutcomes :: MigrationReport -> [MigrationOutcome]
reportOutcomes MigrationReport{results} = outcome <$> toList results

importOutcomes :: HistoryImportReport -> [HistoryImportOutcome]
importOutcomes HistoryImportReport{importResults} = importOutcome <$> toList importResults

kirokuPgConfig :: Pg.Config
kirokuPgConfig = Pg.defaultConfig{Pg.user = "kiroku"}

withKirokuPg :: (Pg.Database -> IO ()) -> IO ()
withKirokuPg action = do
    started <- Pg.startCached kirokuPgConfig Pg.defaultCacheConfig
    case started of
        Left startError -> expectationFailure (show startError)
        Right database -> action database `finally` Pg.stop database

withConnection :: Settings.Settings -> (Connection.Connection -> IO value) -> IO value
withConnection settings action = do
    acquired <- Connection.acquire settings
    connection <- requireRight acquired
    action connection `finally` Connection.release connection

useSession :: Connection.Connection -> Session.Session value -> IO value
useSession connection session =
    Connection.use connection session >>= requireRight

assertSchema :: Connection.Connection -> Expectation
assertSchema connection = do
    healthy <- useSession connection (Session.statement () schemaFactsStatement)
    healthy `shouldBe` True
    oversized <- Connection.use connection (Session.statement (Text.replicate 513 "x") oversizedStreamStatement)
    oversized `shouldSatisfy` isLeft

schemaFactsStatement :: Statement () Bool
schemaFactsStatement =
    Statement.preparable
        """
        SELECT bool_and(ok)
        FROM (VALUES
          (to_regnamespace('kiroku') IS NOT NULL),
          (to_regclass('kiroku.events') IS NOT NULL),
          (to_regclass('kiroku.streams') IS NOT NULL),
          (to_regclass('kiroku.dead_letters') IS NOT NULL),
          (EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'stream_events_notify_insert' AND NOT tgisinternal)),
          (EXISTS (SELECT 1 FROM pg_catalog.pg_indexes WHERE schemaname = 'kiroku' AND indexname = 'ix_dead_letters_event_id')),
          (EXISTS (SELECT 1 FROM pg_catalog.pg_constraint WHERE conname = 'chk_streams_stream_name_length')),
          (EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON c.oid = a.attrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'kiroku' AND c.relname = 'streams' AND a.attname = 'truncate_before' AND NOT a.attisdropped)),
          (obj_description(to_regnamespace('kiroku'), 'pg_namespace') = 'Managed by pg-migrate component kiroku through 0010')
        ) AS checks(ok)
        """
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

historyRetentionColumnsStatement :: Statement () [(Text, Text, Text, Bool)]
historyRetentionColumnsStatement =
    Statement.preparable
        """
        SELECT relation.relname::text,
               attribute.attname::text,
               pg_catalog.format_type(attribute.atttypid, attribute.atttypmod),
               attribute.attnotnull
        FROM pg_catalog.pg_class AS relation
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        JOIN pg_catalog.pg_attribute AS attribute
          ON attribute.attrelid = relation.oid
        WHERE namespace.nspname = 'kiroku'
          AND relation.relname IN ('history_retention_coordinator', 'history_retention_leases')
          AND attribute.attnum > 0
          AND NOT attribute.attisdropped
        ORDER BY relation.relname, attribute.attnum
        """
        Encoders.noParams
        ( Decoders.rowList
            ( (,,,)
                <$> column Decoders.text
                <*> column Decoders.text
                <*> column Decoders.text
                <*> column Decoders.bool
            )
        )
  where
    column = Decoders.column . Decoders.nonNullable

historyRetentionFactsStatement :: Statement () (Int64, Int64, Bool, Bool, Int64)
historyRetentionFactsStatement =
    Statement.preparable
        """
        SELECT
          (SELECT count(*) FROM kiroku.history_retention_coordinator WHERE singleton),
          (SELECT count(*)
             FROM pg_catalog.pg_constraint AS con_record
             JOIN pg_catalog.pg_class AS relation ON relation.oid = con_record.conrelid
             JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname = 'kiroku'
              AND relation.relname IN ('history_retention_coordinator', 'history_retention_leases')
              AND con_record.conname IN (
                'history_retention_coordinator_pkey',
                'chk_history_retention_coordinator_singleton',
                'history_retention_leases_pkey',
                'chk_history_retention_lease_owner_bytes',
                'chk_history_retention_lease_reason_bytes',
                'chk_history_retention_lease_frontier',
                'chk_history_retention_lease_renewal_time',
                'chk_history_retention_lease_expiry',
                'chk_history_retention_lease_release_time'
              )),
          EXISTS (
            SELECT 1
            FROM pg_catalog.pg_indexes
            WHERE schemaname = 'kiroku'
              AND indexname = 'ix_history_retention_leases_unreleased_expiry'
              AND indexdef LIKE '%WHERE (released_at IS NULL)'
          ),
          to_regprocedure('kiroku.protect_replay_history_from_destruction()') IS NOT NULL,
          (SELECT count(*)
             FROM pg_catalog.pg_trigger AS trigger_record
             JOIN pg_catalog.pg_class AS relation ON relation.oid = trigger_record.tgrelid
             JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname = 'kiroku'
              AND relation.relname IN ('events', 'stream_events', 'streams')
              AND trigger_record.tgname IN ('protect_replay_history_delete', 'protect_replay_history_truncate')
              AND NOT trigger_record.tgisinternal)
        """
        Encoders.noParams
        ( Decoders.singleRow
            ( (,,,,)
                <$> column Decoders.int8
                <*> column Decoders.int8
                <*> column Decoders.bool
                <*> column Decoders.bool
                <*> column Decoders.int8
            )
        )
  where
    column = Decoders.column . Decoders.nonNullable

oversizedStreamStatement :: Statement Text ()
oversizedStreamStatement =
    Statement.preparable
        "INSERT INTO kiroku.streams (stream_name, stream_version) VALUES ($1, 0)"
        (Encoders.param (Encoders.nonNullable Encoders.text))
        Decoders.noResult

relationCatalogStatement :: Statement () (Text, Text, Bool, Text, Text, Text)
relationCatalogStatement =
    Statement.preparable
        """
        SELECT c.relkind::text,
               COALESCE(array_to_string(c.reloptions, ','), ''),
               c.relowner = source.relowner,
               view_contract.is_updatable::text,
               view_contract.is_insertable_into::text,
               pg_catalog.obj_description(c.oid, 'pg_class')
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_class AS source
          ON source.oid = to_regclass('kiroku.subscriptions')
        JOIN information_schema.views AS view_contract
          ON view_contract.table_schema = n.nspname
         AND view_contract.table_name = c.relname
        WHERE n.nspname = 'kiroku'
          AND c.relname = 'subscription_checkpoints_v1'
        """
        Encoders.noParams
        ( Decoders.singleRow
            ( (,,,,,)
                <$> column Decoders.text
                <*> column Decoders.text
                <*> column Decoders.bool
                <*> column Decoders.text
                <*> column Decoders.text
                <*> column Decoders.text
            )
        )
  where
    column = Decoders.column . Decoders.nonNullable

relationColumnsStatement :: Statement () [(Text, Text, Bool, Text)]
relationColumnsStatement =
    Statement.preparable
        """
        SELECT attribute.attname::text,
               pg_catalog.format_type(attribute.atttypid, attribute.atttypmod),
               attribute.attnotnull,
               pg_catalog.col_description(relation.oid, attribute.attnum)
        FROM pg_catalog.pg_class AS relation
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        JOIN pg_catalog.pg_attribute AS attribute
          ON attribute.attrelid = relation.oid
        WHERE namespace.nspname = 'kiroku'
          AND relation.relname = 'subscription_checkpoints_v1'
          AND attribute.attnum > 0
          AND NOT attribute.attisdropped
        ORDER BY attribute.attnum
        """
        Encoders.noParams
        ( Decoders.rowList
            ( (,,,)
                <$> column Decoders.text
                <*> column Decoders.text
                <*> column Decoders.bool
                <*> column Decoders.text
            )
        )
  where
    column = Decoders.column . Decoders.nonNullable

checkpointRowsStatement :: Statement () [(Text, Int32, Int64, UTCTime)]
checkpointRowsStatement =
    Statement.preparable
        """
        SELECT subscription_name,
               consumer_group_member,
               checkpoint_position,
               checkpoint_updated_at
        FROM kiroku.subscription_checkpoints_v1
        ORDER BY subscription_name, consumer_group_member
        """
        Encoders.noParams
        ( Decoders.rowList
            ( (,,,)
                <$> column Decoders.text
                <*> column Decoders.int4
                <*> column Decoders.int8
                <*> column Decoders.timestamptz
            )
        )
  where
    column = Decoders.column . Decoders.nonNullable

checkpointFixtureTimestamp :: UTCTime
checkpointFixtureTimestamp =
    UTCTime
        (fromGregorian 2026 8 13)
        (secondsToDiffTime (12 * 60 * 60 + 34 * 60 + 56))

checkpointFixtureSql :: Text
checkpointFixtureSql =
    """
    INSERT INTO kiroku.subscriptions
      (subscription_name, consumer_group_member, last_seen, updated_at)
    VALUES
      ('ordinary', 0, 11, '2026-08-13 12:34:56+00'),
      ('grouped', 0, 20, '2026-08-13 12:34:56+00'),
      ('grouped', 1, 21, '2026-08-13 12:34:56+00'),
      ('grouped', 2, 22, '2026-08-13 12:34:56+00')
    """

checkpointAdvanceSql :: Text
checkpointAdvanceSql =
    """
    UPDATE kiroku.subscriptions
    SET last_seen = 5
    WHERE subscription_name = 'ordinary'
      AND consumer_group_member = 0
    """

checkpointRegressionSql :: Text
checkpointRegressionSql =
    """
    UPDATE kiroku.subscriptions
    SET last_seen = 2
    WHERE subscription_name = 'ordinary'
      AND consumer_group_member = 0
    """

checkpointPosition :: Connection.Connection -> IO Int64
checkpointPosition connection =
    useSession connection (Session.statement "ordinary" checkpointPositionStatement)

checkpointPositionStatement :: Statement Text Int64
checkpointPositionStatement =
    Statement.preparable
        """
        SELECT checkpoint_position
        FROM kiroku.subscription_checkpoints_v1
        WHERE subscription_name = $1
          AND consumer_group_member = 0
        """
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

withTemporaryReaderRole :: Connection.Connection -> (Text -> IO value) -> IO value
withTemporaryReaderRole connection action = do
    unique <- newUnique
    let role =
            "kiroku_checkpoint_reader_"
                <> Text.replace "-" "n" (Text.pack (show (hashUnique unique)))
        identifier = quoteTestIdentifier role
    useSession connection (Session.script ("CREATE ROLE " <> identifier))
    action role
        `finally` useSession
            connection
            ( Session.script
                ( "RESET ROLE; DROP OWNED BY "
                    <> identifier
                    <> "; DROP ROLE "
                    <> identifier
                )
            )

quoteTestIdentifier :: Text -> Text
quoteTestIdentifier value =
    "\"" <> Text.replace "\"" "\"\"" value <> "\""

checkpointRowCountStatement :: Statement () Int64
checkpointRowCountStatement =
    Statement.preparable
        "SELECT count(*) FROM kiroku.subscription_checkpoints_v1"
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

privateTablePrivilegeStatement :: Statement () Bool
privateTablePrivilegeStatement =
    Statement.preparable
        "SELECT has_table_privilege(current_user, 'kiroku.subscriptions', 'SELECT')"
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

privateTableCountStatement :: Statement () Int64
privateTableCountStatement =
    Statement.preparable
        "SELECT count(*) FROM kiroku.subscriptions"
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

updatePublicViewStatement :: Statement () ()
updatePublicViewStatement =
    Statement.unpreparable
        """
        UPDATE kiroku.subscription_checkpoints_v1
        SET checkpoint_position = checkpoint_position
        """
        Encoders.noParams
        Decoders.noResult

hasSqlState :: Text -> Either Errors.SessionError value -> Bool
hasSqlState expected = \case
    Left
        ( Errors.StatementSessionError
                _
                _
                _
                _
                _
                (Errors.ServerStatementError (Errors.ServerError actual _ _ _ _))
            ) -> actual == expected
    _ -> False

downstreamReplacementFixtureSql :: Text
downstreamReplacementFixtureSql =
    """
    INSERT INTO kiroku.subscriptions
      (subscription_name, consumer_group_member, last_seen,
       updated_at)
    VALUES ('dependency', 0, 42, '2026-08-13 12:34:56+00');

    CREATE VIEW public.subscription_checkpoint_floors AS
    SELECT subscription_name,
           min(checkpoint_position) AS checkpoint_floor
    FROM kiroku.subscription_checkpoints_v1
    GROUP BY subscription_name;

    CREATE TABLE kiroku.subscription_checkpoint_storage_v2 (
      subscription_name text NOT NULL,
      consumer_group_member integer NOT NULL,
      checkpoint_position bigint NOT NULL,
      checkpoint_updated_at timestamptz NOT NULL,
      PRIMARY KEY (subscription_name, consumer_group_member)
    );

    INSERT INTO kiroku.subscription_checkpoint_storage_v2
    SELECT subscription_name,
           consumer_group_member,
           last_seen,
           updated_at
    FROM kiroku.subscriptions;

    CREATE OR REPLACE VIEW kiroku.subscription_checkpoints_v1
        (subscription_name,
         consumer_group_member,
         checkpoint_position,
         checkpoint_updated_at)
    WITH (security_invoker = false)
    AS
    WITH checkpoint_rows AS NOT MATERIALIZED (
        SELECT subscription_name,
               consumer_group_member,
               checkpoint_position,
               checkpoint_updated_at
        FROM kiroku.subscription_checkpoint_storage_v2
    )
    SELECT subscription_name,
           consumer_group_member,
           checkpoint_position,
           checkpoint_updated_at
    FROM checkpoint_rows;

    DROP TABLE kiroku.subscriptions;
    """

downstreamFloorsStatement :: Statement () [(Text, Int64)]
downstreamFloorsStatement =
    Statement.preparable
        """
        SELECT subscription_name, checkpoint_floor
        FROM public.subscription_checkpoint_floors
        ORDER BY subscription_name
        """
        Encoders.noParams
        ( Decoders.rowList
            ( (,)
                <$> Decoders.column (Decoders.nonNullable Decoders.text)
                <*> Decoders.column (Decoders.nonNullable Decoders.int8)
            )
        )

checkpointPlanFixtureSql :: Text
checkpointPlanFixtureSql =
    """
    INSERT INTO kiroku.subscriptions
      (subscription_name, consumer_group_member, last_seen)
    SELECT 'subscription-' || lpad((value % 100)::text, 3, '0'),
           value::integer,
           value::bigint
    FROM generate_series(1, 10000) AS generated(value);

    ANALYZE kiroku.subscriptions;
    """

serverVersionStatement :: Statement () Text
serverVersionStatement =
    Statement.preparable
        "SELECT current_setting('server_version')"
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

checkpointExplainStatement :: Statement () [Text]
checkpointExplainStatement =
    Statement.preparable
        """
        EXPLAIN (COSTS OFF)
        SELECT min(checkpoint_position)
        FROM kiroku.subscription_checkpoints_v1
        WHERE subscription_name = 'subscription-042'
        """
        Encoders.noParams
        (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

applyNativeSqlFromDisk :: Connection.Connection -> FilePath -> IO ()
applyNativeSqlFromDisk connection directory =
    forM_ (take 7 nativeMigrationFiles) $ \file -> do
        sql <- Text.IO.readFile (directory </> file)
        useSession connection (Session.script sql)

installCoddLedger :: Connection.Connection -> Text -> Bool -> IO ()
installCoddLedger connection sourceSchema partial =
    useSession connection (Session.script (coddFixtureSql sourceSchema partial))

coddFixtureSql :: Text -> Bool -> Text
coddFixtureSql sourceSchema partial =
    Text.unlines
        [ "CREATE SCHEMA " <> sourceSchema <> ";"
        , "CREATE TABLE " <> sourceSchema <> ".sql_migrations ("
        , "  id serial NOT NULL, migration_timestamp timestamptz NOT NULL,"
        , "  applied_at timestamptz, name text NOT NULL, application_duration interval,"
        , "  num_applied_statements int, no_txn_failed_at timestamptz, txnid bigint, connid int"
        , ");"
        , "INSERT INTO " <> sourceSchema <> ".sql_migrations"
        , "  (migration_timestamp, applied_at, name, application_duration, num_applied_statements, no_txn_failed_at, txnid, connid) VALUES"
        , Text.intercalate ",\n" (zipWith renderRow [1 :: Int ..] (toList kirokuLegacyMigrationNames)) <> ";"
        ]
  where
    renderRow index filename =
        "('2026-01-01 00:00:00+00'::timestamptz + interval '"
            <> Text.pack (show index)
            <> " seconds', "
            <> appliedAt index
            <> ", '"
            <> Text.pack filename
            <> "', interval '1 second', 1, "
            <> failureAt index
            <> ", 1, 1)"
    appliedAt index
        | partial && index == 4 = "NULL"
        | otherwise = "'2026-01-01 00:01:00+00'::timestamptz + interval '" <> Text.pack (show index) <> " seconds'"
    failureAt index
        | partial && index == 4 = "'2026-01-01 00:02:00+00'::timestamptz"
        | otherwise = "NULL"

schemaExistsStatement :: Statement Text Bool
schemaExistsStatement =
    Statement.preparable
        "SELECT to_regnamespace($1) IS NOT NULL"
        (Encoders.param (Encoders.nonNullable Encoders.text))
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

sourceRowCountStatement :: Text -> Statement () Int64
sourceRowCountStatement sourceSchema =
    Statement.unpreparable
        ("SELECT count(*) FROM " <> sourceSchema <> ".sql_migrations")
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

importFactsStatement :: Statement () (Int64, Int64, Bool)
importFactsStatement =
    Statement.preparable
        """
        SELECT
          (SELECT count(*) FROM pgmigrate.migrations),
          (SELECT count(*) FROM pgmigrate.history_imports),
          (SELECT bool_and(source_evidence #>> '{satisfying_evidence,0,details,adapter}' = 'codd') FROM pgmigrate.history_imports)
        """
        Encoders.noParams
        ( Decoders.singleRow
            ( (,,)
                <$> column Decoders.int8
                <*> column Decoders.int8
                <*> column Decoders.bool
            )
        )
  where
    column = Decoders.column . Decoders.nonNullable
