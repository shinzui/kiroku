module Main where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings (..))
import Codd.Parsing (connStringParser)
import Codd.Representations.Types (DbRep (..))
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Data.Aeson (Value (Null))
import Data.Aeson qualified as Aeson
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (secondsToDiffTime)
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
import Kiroku.Store.Migrations (runKirokuMigrationsNoCheck)
import Test.Hspec

main :: IO ()
main =
    hspec $
        describe "codd migration spike" $
            it "applies Kiroku migrations, opens the store without startup DDL, and is repeatable" $ do
                result <- Pg.withCached $ \db -> do
                    let connStr = Pg.connectionString db
                        coddSettings = testCoddSettings connStr

                    firstMigration <- runKirokuMigrationsNoCheck coddSettings (secondsToDiffTime 5)
                    firstMigration `shouldBeSchemasNotVerified` "first migration run"
                    assertBootstrapApplied connStr
                    assertSchemaPlacement connStr
                    assertDeadLettersTable connStr
                    assertDefaultUuidV7 connStr

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
                case result of
                    Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                    Right () -> pure ()

testCoddSettings :: Text -> CoddSettings
testCoddSettings connStr =
    CoddSettings
        { migsConnString = parseConnString connStr
        , sqlMigrations = []
        , onDiskReps = Right (DbRep Null Map.empty Map.empty)
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
