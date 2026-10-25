{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeApplications #-}

module Test.SubscriptionCheckpointInitialization (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (bracket, finally)
import Control.Lens ((^.))
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import System.Timeout (timeout)
import Test.Helpers (makeEvent, validConsumerGroup, withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "subscription checkpoint initialization" $ do
  it "materializes position zero for FromBeginning" $
    withTestStore $ \store -> do
      let name = SubscriptionName "initialize-from-beginning"
          key = SubscriptionCheckpointKey name 0
      result <- initialize store name 0 FromBeginning
      result `shouldBe` Right (InitializedCheckpoint FromBeginning key (GlobalPosition 0))
      inventoryKeys <$> inventory store `shouldReturn` [(name, 0, GlobalPosition 0)]
      topology store `shouldReturn` [(0, 1, "unbound", Nothing)]

  it "atomically materializes the current store head for FromCurrentHead" $
    withTestStore $ \store -> do
      appendEvents store "initialize-current-head-events" 3
      let name = SubscriptionName "initialize-current-head"
          key = SubscriptionCheckpointKey name 0
      result <- initialize store name 0 FromCurrentHead
      result `shouldBe` Right (InitializedCheckpoint FromCurrentHead key (GlobalPosition 3))
      inventoryKeys <$> inventory store `shouldReturn` [(name, 0, GlobalPosition 3)]

  it "returns a typed missing result without creating a row for FailIfMissing" $
    withTestStore $ \store -> do
      let name = SubscriptionName "initialize-fail-if-missing"
          key = SubscriptionCheckpointKey name 0
      result <- initialize store name 0 FailIfMissing
      result `shouldBe` Left (SubscriptionCheckpointMissing key)
      inventoryKeys <$> inventory store `shouldReturn` []

  it "preserves an existing row for every configured policy" $
    withTestStore $ \store -> do
      appendEvents store "initialize-existing-events" 5
      let name = SubscriptionName "initialize-existing"
          key = SubscriptionCheckpointKey name 0
      initialize store name 0 FromCurrentHead
        `shouldReturn` Right (InitializedCheckpoint FromCurrentHead key (GlobalPosition 5))
      mapM_ (assertExisting store key) [FromBeginning, FromCurrentHead, FailIfMissing]
      inventoryKeys <$> inventory store `shouldReturn` [(name, 0, GlobalPosition 5)]

  it "isolates checkpoint initialization by consumer-group member" $
    withTestStore $ \store -> do
      appendEvents store "initialize-member-events" 4
      let name = SubscriptionName "initialize-members"
      initialize store name 0 FromBeginning
        `shouldReturn` Right (InitializedCheckpoint FromBeginning (SubscriptionCheckpointKey name 0) (GlobalPosition 0))
      initialize store name 1 FromCurrentHead
        `shouldReturn` Right (InitializedCheckpoint FromCurrentHead (SubscriptionCheckpointKey name 1) (GlobalPosition 4))
      inventoryKeys <$> inventory store
        `shouldReturn` [ (name, 0, GlobalPosition 0),
                         (name, 1, GlobalPosition 4)
                       ]

  it "converges concurrent initializers on one durable winner" $
    withTestStore $ \store -> do
      appendEvents store "initialize-race-events" 7
      let name = SubscriptionName "initialize-race"
          policies = take 20 (cycle [FromBeginning, FromCurrentHead])
      results <- Async.mapConcurrently (initialize store name 3) policies
      let successes = [initialization | Right initialization <- results]
          positions = fmap checkpointInitializationPosition successes
          initializedCount = length [() | InitializedCheckpoint {} <- successes]
      length successes `shouldBe` length policies
      initializedCount `shouldBe` 1
      positions `shouldSatisfy` \case
        [] -> False
        first : rest -> all (== first) rest
      case positions of
        [] -> expectationFailure "expected concurrent initialization results"
        winner : _ ->
          inventoryKeys <$> inventory store
            `shouldReturn` [(name, 3, winner)]

  it "initializes an absent member with sibling size and category binding, then starts under RequireBound" $
    withTestStore $ \store -> do
      let name = SubscriptionName "initialize-bound"
          target = Category (CategoryName "orders")
          config memberIndex =
            (defaultSubscriptionConfig name target (\_ -> pure Continue))
              { consumerGroup = Just (validConsumerGroup memberIndex 2),
                targetBindingPolicy = RequireBound
              }
      withSubscription store (config 0) $ \handle -> awaitLive handle
      topology store `shouldReturn` [(0, 2, "category", Just "orders")]
      initialize store name 1 FromBeginning
        `shouldReturn` Right (InitializedCheckpoint FromBeginning (SubscriptionCheckpointKey name 1) (GlobalPosition 0))
      topology store `shouldReturn` [(0, 2, "category", Just "orders"), (1, 2, "category", Just "orders")]
      withSubscription store (config 1) $ \handle -> awaitLive handle

  forM_ (["uniform-unbound", "mixed-size", "mixed-binding"] :: [Text]) $ \variant ->
    it ("initializes with uniform topology or legacy defaults for " <> show variant) $
      withTestStore $ \store -> do
        let secondSize = if variant == "mixed-size" then "3" else "2"
            secondBinding = if variant == "mixed-binding" then "all" else "unbound"
        runSession
          store
          ( Session.script
              ("INSERT INTO subscriptions (subscription_name, consumer_group_member, consumer_group_size, last_seen, target_kind) VALUES ('initialize-fallback', 0, 2, 7, 'unbound'), ('initialize-fallback', 1, " <> secondSize <> ", 9, '" <> secondBinding <> "')")
          )
        originalRows <- topology store
        initialize store (SubscriptionName "initialize-fallback") 2 FromBeginning
          `shouldReturn` Right (InitializedCheckpoint FromBeginning (SubscriptionCheckpointKey (SubscriptionName "initialize-fallback") 2) (GlobalPosition 0))
        initializedRows <- topology store
        take 2 initializedRows `shouldBe` originalRows
        drop 2 initializedRows `shouldBe` [(2, if variant == "uniform-unbound" then 2 else 1, "unbound", Nothing)]

  it "initializes after a concurrent rebind commits, waiting on the name lock before reading topology" $
    withMigratedTestDatabase $ \connStr -> withStore (defaultConnectionSettings connStr) $ \store ->
      bracket
        (Connection.acquire (Conn.connectionString connStr) >>= either (fail . show) pure)
        Connection.release
        $ \gate -> do
          let name = SubscriptionName "initialize-rebind"
              newTarget = Category (CategoryName "new-orders")
              useGate session = Connection.use gate session >>= either (fail . show) pure
          initialize store name 0 FromBeginning
            `shouldReturn` Right (InitializedCheckpoint FromBeginning (SubscriptionCheckpointKey name 0) (GlobalPosition 0))
          -- The session lock is a test gate. Rebind blocks at the gate after
          -- changing its rows, while still owning the transaction's name lock.
          useGate (Session.script "SELECT pg_advisory_lock(103)")
          ( Async.withAsync
              ( runSession store $ TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write $ do
                  Tx.sql "SET LOCAL statement_timeout = '5s'"
                  report <- rebindSubscriptionTargetTx name newTarget (GlobalPosition 0)
                  Tx.sql "SELECT pg_advisory_xact_lock(103)"
                  pure report
              )
              $ \rebinder -> do
                within $ awaitQuery store gateWaitStmt
                Async.withAsync (initialize store name 1 FromBeginning) $ \initializer -> do
                  ( do
                      within $ awaitQuery store topologyWaitStmt
                      useGate (Session.script "SELECT pg_advisory_unlock(103)")
                      _ <- within (Async.wait rebinder)
                      within (Async.wait initializer)
                        `shouldReturn` Right (InitializedCheckpoint FromBeginning (SubscriptionCheckpointKey name 1) (GlobalPosition 0))
                      topology store `shouldReturn` [(0, 1, "category", Just "new-orders"), (1, 1, "category", Just "new-orders")]
                    )
                    `finally` useGate (Session.script "SELECT pg_advisory_unlock_all()")
            )
            `finally` useGate (Session.script "SELECT pg_advisory_unlock_all()")

  it "runs through the resource-backed Store interpreter" $
    withTestStore $ \store -> do
      let name = SubscriptionName "initialize-resource"
          key = SubscriptionCheckpointKey name 2
      result <-
        runEff
          . runErrorNoCallStack @StoreError
          . runKirokuStoreWith store
          . runStoreResource
          $ initializeSubscriptionCheckpoint name 2 FromBeginning
      result `shouldBe` Right (Right (InitializedCheckpoint FromBeginning key (GlobalPosition 0)))

assertExisting :: KirokuStore -> SubscriptionCheckpointKey -> MissingCheckpointPolicy -> IO ()
assertExisting store key@(SubscriptionCheckpointKey name member) policy =
  initialize store name member policy
    `shouldReturn` Right (ExistingCheckpoint key (GlobalPosition 5))

initialize ::
  KirokuStore ->
  SubscriptionName ->
  Int32 ->
  MissingCheckpointPolicy ->
  IO (Either SubscriptionCheckpointMissing CheckpointInitialization)
initialize store name member policy = do
  result <- runStoreIO store (initializeSubscriptionCheckpoint name member policy)
  case result of
    Left err -> expectationFailure ("checkpoint initialization failed: " <> show err) >> error "unreachable"
    Right initialized -> pure initialized

inventory :: KirokuStore -> IO SubscriptionCheckpointInventory
inventory store = do
  result <- runStoreIO store subscriptionCheckpointInventory
  case result of
    Left err -> expectationFailure ("checkpoint inventory failed: " <> show err) >> error "unreachable"
    Right rows -> pure rows

inventoryKeys :: SubscriptionCheckpointInventory -> [(SubscriptionName, Int32, GlobalPosition)]
inventoryKeys (SubscriptionCheckpointInventory _ rows) =
  [ (name, member, position)
  | SubscriptionCheckpoint name member position _ <- V.toList rows
  ]

appendEvents :: KirokuStore -> Text -> Int -> IO ()
appendEvents store stream count = do
  let events = [makeEvent ("Initialize" <> T.pack (show i)) (Aeson.object []) | i <- [1 .. count]]
  result <- runStoreIO store $ appendToStream (StreamName stream) NoStream events
  case result of
    Left err -> expectationFailure ("append failed: " <> show err)
    Right _ -> pure ()

within :: IO a -> IO a
within action = timeout 5_000_000 action >>= maybe (fail "checkpoint initialization test timed out") pure

awaitLive :: SubscriptionHandle -> IO ()
awaitLive handle = within loop
  where
    loop =
      currentState handle >>= \case
        Just state | stateName state == "live" -> pure ()
        _ -> threadDelay 1_000 >> loop

runSession :: KirokuStore -> Session.Session a -> IO a
runSession store session = Pool.use (store ^. #pool) session >>= either (fail . show) pure

topology :: KirokuStore -> IO [(Int32, Int32, Text, Maybe Text)]
topology store = V.toList <$> runSession store (Session.statement () stmt)
  where
    stmt =
      preparable
        "SELECT consumer_group_member, consumer_group_size, target_kind, target_category FROM subscriptions ORDER BY consumer_group_member"
        E.noParams
        (D.rowVector ((,,,) <$> D.column (D.nonNullable D.int4) <*> D.column (D.nonNullable D.int4) <*> D.column (D.nonNullable D.text) <*> D.column (D.nullable D.text)))

awaitQuery :: KirokuStore -> Statement () Bool -> IO ()
awaitQuery store stmt = do
  ready <- runSession store (Session.statement () stmt)
  if ready then pure () else threadDelay 1_000 >> awaitQuery store stmt

-- Only this test database participates; unrelated advisory locks cannot satisfy
-- either barrier. The second query observes the initializer blocked on a lock
-- held by the rebind transaction, which is itself waiting at the test gate.
gateWaitStmt :: Statement () Bool
gateWaitStmt =
  preparable
    "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND classid = 0 AND objid = 103 AND objsubid = 1 AND database = (SELECT oid FROM pg_database WHERE datname = current_database()))"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

topologyWaitStmt :: Statement () Bool
topologyWaitStmt =
  preparable
    "SELECT EXISTS (SELECT 1 FROM pg_locks waiting JOIN pg_locks held USING (locktype, database, classid, objid, objsubid) JOIN pg_locks gate ON gate.pid = held.pid WHERE waiting.locktype = 'advisory' AND NOT waiting.granted AND held.granted AND gate.locktype = 'advisory' AND NOT gate.granted AND gate.classid = 0 AND gate.objid = 103 AND gate.objsubid = 1 AND waiting.database = (SELECT oid FROM pg_database WHERE datname = current_database()))"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))
