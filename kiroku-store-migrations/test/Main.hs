module Main where

import Codd (CoddSettings (..), VerifySchemas (LaxCheck))
import Codd.Parsing (connStringParser)
import Codd.Representations.Types (DbRep (..))
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Control.Lens ((&), (.~))
import Data.Aeson (Value (Null))
import Data.Aeson qualified as Aeson
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Generics.Labels ()
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
import Kiroku.Store.Migrations (runKirokuMigrations)
import Test.Hspec

main :: IO ()
main =
    hspec $
        describe "codd migration spike" $
            it "applies Kiroku migrations, opens the store without startup DDL, and is repeatable" $ do
                result <- Pg.withCached $ \db -> do
                    let connStr = Pg.connectionString db
                        coddSettings = testCoddSettings connStr

                    _ <- runKirokuMigrations coddSettings (secondsToDiffTime 5) LaxCheck
                    assertBootstrapApplied connStr
                    assertDefaultUuidV7 connStr

                    withStore
                        ( defaultConnectionSettings connStr
                            & #schemaInitialization .~ SkipSchemaInitialization
                        )
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

                    _ <- runKirokuMigrations coddSettings (secondsToDiffTime 5) LaxCheck
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
        , namespacesToCheck = IncludeSchemas [SqlSchema "public"]
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
        "SELECT EXISTS (SELECT 1 FROM streams WHERE stream_id = 0 AND stream_name = '$all')"
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
        "INSERT INTO events (event_type, data) VALUES ('DefaultUuidGenerated', '{}'::jsonb) RETURNING event_id::text"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.text)))

serverVersionStmt :: Statement () Text
serverVersionStmt =
    preparable
        "SELECT current_setting('server_version_num')"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.text)))
