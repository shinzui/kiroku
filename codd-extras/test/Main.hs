module Main (main) where

import Codd (ApplyResult (SchemasNotVerified))
import Codd.Extras.Apply (applyEmbeddedMigrationsNoCheck)
import Codd.Extras.Ledger (MigrationStatus (..), migrationStatus)
import Codd.Extras.Settings (noCheckCoddSettings)
import Codd.Extras.Settings qualified as Codd.Extras.Settings
import Codd.Extras.TestSupport (withMigratedDatabase)
import Codd.Types (libpqConnString)
import Codd.Types qualified
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import Database.PostgreSQL.Simple qualified as DB
import Test.Hspec

main :: IO ()
main =
    hspec $ do
        it "applies multiple embedded migration groups once into one shared ledger" $
            withMigratedDatabase applyTestMigrations $ \connStr -> do
                assertRegclass connStr "alpha.widgets"
                assertRegclass connStr "beta.widgets"
                ledger <- ledgerNames connStr
                ledger `shouldBe` map fst (alphaMigrations <> betaMigrations)

                beforeCount <- ledgerRowCount connStr
                applyTestMigrations connStr
                afterCount <- ledgerRowCount connStr
                afterCount `shouldBe` beforeCount

                status <- migrationStatus (map fst (alphaMigrations <> betaMigrations)) (migsConnStringFor connStr) (secondsToDiffTime 5)
                map fst (statusApplied status) `shouldBe` map fst (alphaMigrations <> betaMigrations)
                statusPending status `shouldBe` []

        it "reports partially-applied no-txn ledger rows as pending" $
            withMigratedDatabase applyTestMigrations $ \connStr -> do
                let partialName = "2026-01-01-00-00-03-partial.sql"
                insertPartialLedgerRow connStr partialName
                status <- migrationStatus (map fst (alphaMigrations <> betaMigrations) <> [partialName]) (migsConnStringFor connStr) (secondsToDiffTime 5)
                map fst (statusApplied status) `shouldBe` map fst (alphaMigrations <> betaMigrations)
                statusPending status `shouldBe` [partialName]

applyTestMigrations :: Text -> IO ()
applyTestMigrations connStr = do
    result <-
        applyEmbeddedMigrationsNoCheck
            (noCheckCoddSettings ["alpha", "beta"] connStr)
            (secondsToDiffTime 5)
            [ ("Alpha", alphaMigrations)
            , ("Beta", betaMigrations)
            ]
    result `shouldBeSchemasNotVerified` "test migration run"

alphaMigrations :: [(FilePath, ByteString)]
alphaMigrations =
    [
        ( "2026-01-01-00-00-01-alpha.sql"
        , "CREATE SCHEMA IF NOT EXISTS alpha;\n\
          \CREATE TABLE alpha.widgets (widget_id int PRIMARY KEY);\n"
        )
    ]

betaMigrations :: [(FilePath, ByteString)]
betaMigrations =
    [
        ( "2026-01-01-00-00-02-beta.sql"
        , "CREATE SCHEMA IF NOT EXISTS beta;\n\
          \CREATE TABLE beta.widgets (widget_id int PRIMARY KEY);\n"
        )
    ]

migsConnStringFor :: Text -> Codd.Types.ConnectionString
migsConnStringFor = Codd.Extras.Settings.parseConnString

shouldBeSchemasNotVerified :: ApplyResult -> String -> Expectation
shouldBeSchemasNotVerified SchemasNotVerified _ = pure ()
shouldBeSchemasNotVerified _ label = expectationFailure (label <> " unexpectedly verified schemas")

withConn :: Text -> (DB.Connection -> IO a) -> IO a
withConn connStr =
    bracket (DB.connectPostgreSQL (libpqConnString (migsConnStringFor connStr))) DB.close

assertRegclass :: Text -> Text -> Expectation
assertRegclass connStr relationName =
    withConn connStr $ \conn -> do
        [DB.Only exists] <- DB.query conn "SELECT to_regclass(?) IS NOT NULL" (DB.Only relationName)
        exists `shouldBe` True

ledgerNames :: Text -> IO [FilePath]
ledgerNames connStr =
    withConn connStr $ \conn ->
        fmap DB.fromOnly <$> DB.query_ conn "SELECT name FROM codd.sql_migrations ORDER BY name"

ledgerRowCount :: Text -> IO Int
ledgerRowCount connStr =
    withConn connStr $ \conn -> do
        [DB.Only count] <- DB.query_ conn "SELECT count(*)::int FROM codd.sql_migrations"
        pure count

insertPartialLedgerRow :: Text -> FilePath -> IO ()
insertPartialLedgerRow connStr name =
    withConn connStr $ \conn -> do
        _ <-
            DB.execute
                conn
                "INSERT INTO codd.sql_migrations \
                \(migration_timestamp, name, application_duration, num_applied_statements, applied_at, no_txn_failed_at) \
                \VALUES ('2026-01-01 00:00:03+00', ?, '1 second', 1, NULL, now())"
                (DB.Only name)
        pure ()
