{- | EP-5 tests for the @GET /subscriptions@ endpoint and the CLI remote client.

  * Cross-package shape: rows produced by the server-side mapping
    ('subscriptionStatusRows') encode and decode back through the shared
    @kiroku-cli@ codec — guarding against either side re-encoding locally.
  * End-to-end: boot a real store with a live subscription, serve
    @\/subscriptions@ from 'storeSubscriptionStatus', and assert the real CLI
    client ('fetchRemoteSubscriptionStatusRows') reports the live subscription
    with a sane phase and the expected cursor. A raw GET checks the by-name route
    (known → one row, unknown → @[]@), and a server with no provider yields the
    configured-404.
-}
module Test.SubscriptionsSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Aeson qualified as Aeson
import Data.Int (Int32, Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (
    defaultManagerSettings,
    httpLbs,
    newManager,
    parseRequest,
    responseBody,
 )
import Test.Hspec

import Kiroku.Cli.Command (RemoteEndpoint (..))
import Kiroku.Cli.Subscription.Status (
    SubscriptionStatusRow (..),
    fetchRemoteSubscriptionStatusRows,
    subscriptionStatusRows,
 )
import Kiroku.Metrics (
    MetricsServer (..),
    defaultConfig,
    newKirokuMetrics,
    startMetricsServer,
    stopMetricsServer,
    storeSubscriptionStatus,
    withMetricsServerSubscriptions,
 )
import Kiroku.Metrics.Config (MetricsServerConfig (..))
import Kiroku.Store (
    EventData (..),
    EventType (..),
    ExpectedVersion (..),
    KirokuStore,
    StreamName (..),
    SubscriptionResult (..),
    SubscriptionTarget (..),
    appendToStream,
    cancel,
    defaultConnectionSettings,
    defaultSubscriptionConfig,
    runStoreIO,
    subscribe,
    withStore,
 )
import Kiroku.Store.Subscription (SubscriptionStateView (..), subscriptionStates)
import Kiroku.Store.Subscription.Fsm (SubscriptionState (..))
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (GlobalPosition (..))
import Kiroku.Test.Postgres (withMigratedTestDatabase)

spec :: Spec
spec = describe "Kiroku.Metrics.Subscriptions (/subscriptions)" $ do
    it "encodes server-side rows that decode back through the shared CLI codec" $ do
        let views =
                Map.fromList
                    [ ((SubscriptionName "beta", 1), mkView "beta" 1 "live" 42)
                    , ((SubscriptionName "alpha", 0), mkView "alpha" 0 "catching_up" 7)
                    ]
            rows = subscriptionStatusRows views
        Aeson.eitherDecode (Aeson.encode rows) `shouldBe` Right rows

    it "reports a live subscription to the CLI remote client end to end" $
        withMigratedTestDatabase $ \connStr ->
            withStore (defaultConnectionSettings connStr) $ \store -> do
                m <- newKirokuMetrics store
                let name = SubscriptionName "subs-endpoint-it"
                Right _ <-
                    runStoreIO store $
                        appendToStream (StreamName "subs-endpoint-1") NoStream [ev "A", ev "B", ev "C"]
                handle <- subscribe store (defaultSubscriptionConfig name AllStreams (\_ -> pure Continue))
                live <- waitUntilPhase 10_000_000 store (name, 0) "live"
                live `shouldBe` True

                withMetricsServerSubscriptions (defaultConfig{port = 0}) m [] (storeSubscriptionStatus store) $ \srv -> do
                    threadDelay 200_000
                    let base = "http://127.0.0.1:" <> show srv.serverPort

                    -- The real CLI client hits GET /subscriptions and decodes the rows.
                    rowsResult <- fetchRemoteSubscriptionStatusRows (RemoteEndpoint (T.pack base))
                    case rowsResult of
                        Left err -> expectationFailure ("expected rows, got error: " <> T.unpack err)
                        Right rows ->
                            case filter (\r -> r.subscription == "subs-endpoint-it") rows of
                                [row] -> do
                                    row.phase `shouldBe` "live"
                                    row.globalPosition `shouldBe` 3
                                other -> expectationFailure ("expected exactly one matching row, got " <> show other)

                    -- By-name route: known name → one row, unknown name → [].
                    known <- getRows (base <> "/subscriptions/subs-endpoint-it")
                    map (.subscription) known `shouldBe` ["subs-endpoint-it"]
                    unknown <- getRows (base <> "/subscriptions/does-not-exist")
                    unknown `shouldBe` []

                cancel handle

    it "returns a configured-404 when no provider is wired" $
        withMigratedTestDatabase $ \connStr ->
            withStore (defaultConnectionSettings connStr) $ \store -> do
                m <- newKirokuMetrics store
                srv <- startMetricsServer (defaultConfig{port = 0}) m []
                threadDelay 200_000
                result <-
                    fetchRemoteSubscriptionStatusRows
                        (RemoteEndpoint (T.pack ("http://127.0.0.1:" <> show srv.serverPort)))
                stopMetricsServer srv
                case result of
                    Left err -> err `shouldSatisfy` T.isInfixOf "404"
                    Right rows -> expectationFailure ("expected a 404 error, got rows: " <> show rows)

-- | GET a URL and decode the body as @[SubscriptionStatusRow]@ (via the shared codec).
getRows :: String -> IO [SubscriptionStatusRow]
getRows url = do
    mgr <- newManager defaultManagerSettings
    req <- parseRequest url
    resp <- httpLbs req mgr
    case Aeson.eitherDecode (responseBody resp) of
        Right rows -> pure rows
        Left err -> expectationFailure ("could not decode " <> url <> ": " <> err) >> pure []

mkView :: Text -> Int32 -> Text -> Int64 -> SubscriptionStateView
mkView name member phase position =
    SubscriptionStateView
        { subscriptionName = SubscriptionName name
        , member = member
        , state = Live (GlobalPosition position)
        , statePhase = phase
        , cursor = GlobalPosition position
        }

ev :: Text -> EventData
ev typ =
    EventData
        { eventId = Nothing
        , eventType = EventType typ
        , payload = Aeson.Null
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        }

waitUntilPhase :: Int -> KirokuStore -> (SubscriptionName, Int32) -> Text -> IO Bool
waitUntilPhase budget store key phase
    | budget <= 0 = pure False
    | otherwise = do
        snapshot <- subscriptionStates store
        case Map.lookup key snapshot of
            Just status | statePhase status == phase -> pure True
            _ -> do
                threadDelay 20_000
                waitUntilPhase (budget - 20_000) store key phase
