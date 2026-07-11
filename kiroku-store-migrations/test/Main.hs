{-# LANGUAGE MultilineStrings #-}

module Main (main) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (finally)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.Codd
import Database.PostgreSQL.Migrate.Internal (migrationChecksumBytes)
import Database.PostgreSQL.Migrate.Test (withMigratedDatabase)
import EphemeralPg qualified as Pg
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
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
        it "tracks the eight native files in manifest order" $ do
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

        it "builds component kiroku and an eight-migration plan" $ do
            component <- requireRight kirokuMigrations
            component `seq` pure ()
            plan <- requirePlan
            let targetIds =
                    [ requireRight (migrationId "kiroku" (Text.pack (dropSqlSuffix file)))
                    | file <- nativeMigrationFiles
                    ]
            validateHistoryMappingTargets plan kirokuCoddHistoryMappings
                `shouldBe` Right ()
            length targetIds `shouldBe` 8

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
        it "applies all eight, verifies strictly, and reports AlreadyApplied on rerun" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                assertSchema connection
                let provider = providerFor connection
                rerun <- runMigrationPlanWith defaultRunOptions provider plan >>= requireMigration
                reportOutcomes rerun `shouldBe` replicate 8 AlreadyApplied
                verified <- verifyMigrationPlanWith defaultRunOptions provider plan >>= requireMigration
                case verified of
                    VerificationReport verificationIssues applied _ _ -> do
                        verificationIssues `shouldBe` []
                        length applied `shouldBe` 8
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
                    `shouldBe` sort [replicate 8 AppliedNow, replicate 8 AlreadyApplied]

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
        canaryId <- requireRight (migrationId "kiroku" "0008-schema-management-comment")
        verifiedBeforeCanary <- verifyMigrationPlan defaultRunOptions settings plan >>= requireMigration
        case verifiedBeforeCanary of
            VerificationReport verificationIssues _ _ _ ->
                verificationIssues
                    `shouldBe` [PendingMigration canaryId]
        up <- runMigrationPlan defaultRunOptions settings plan >>= requireMigration
        reportOutcomes up `shouldBe` replicate 7 AlreadyApplied <> [AppliedNow]
        verifiedAfterCanary <- verifyMigrationPlan defaultRunOptions settings plan >>= requireMigration
        case verifiedAfterCanary of
            VerificationReport verificationIssues _ _ _ ->
                verificationIssues `shouldBe` []
        rerun <- runMigrationPlan defaultRunOptions settings plan >>= requireMigration
        reportOutcomes rerun `shouldBe` replicate 8 AlreadyApplied
        second <-
            importCoddHistory defaultImportOptions config provider plan kirokuCoddHistoryMappings
                >>= requireRight
        importOutcomes second `shouldBe` replicate 7 AlreadyImported
        withConnection settings $ \connection -> do
            assertSchema connection
            sourceRows <- useSession connection (Session.statement () (sourceRowCountStatement sourceSchema))
            sourceRows `shouldBe` 7
            facts <- useSession connection (Session.statement () importFactsStatement)
            facts `shouldBe` (8, 7, True)

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
          (obj_description(to_regnamespace('kiroku'), 'pg_namespace') = 'Managed by pg-migrate component kiroku through 0008-schema-management-comment')
        ) AS checks(ok)
        """
        Encoders.noParams
        (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

oversizedStreamStatement :: Statement Text ()
oversizedStreamStatement =
    Statement.preparable
        "INSERT INTO kiroku.streams (stream_name, stream_version) VALUES ($1, 0)"
        (Encoders.param (Encoders.nonNullable Encoders.text))
        Decoders.noResult

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
