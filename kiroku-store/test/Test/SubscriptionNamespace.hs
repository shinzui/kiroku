module Test.SubscriptionNamespace (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO)
import Control.Exception (bracket, fromException)
import Control.Lens ((^.))
import Control.Monad (forM_, replicateM_, when)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions qualified as Tx
import Kiroku.Store
import Kiroku.Store.Notification qualified as Notify
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Subscription.Fsm qualified as Fsm
import Kiroku.Store.Subscription.Worker (withNamespaceSafetyPollForTest, withNamespaceWindowHookForTest, withSaveCheckpointHookForTest)
import System.Timeout (timeout)
import Test.Helpers
import Test.Hspec

spec :: Spec
spec = describe "namespace subscriptions" $ do
  forM_ [1, 3] $ \width ->
    it ("catches up across empty windows, includes future categories, and restarts (W=" <> show width <> ")") $
      withTestStore $ \store -> do
        replicateM_ 9 (append store "noise-1")
        append store "pm-1"
        append store "pm:fulfillment-1"
        append store "pm:billing-1"
        append store "orders-1"
        seen <- newIORef []
        let config = (cfg "restart" "pm" (record seen)) {batchSize = batch width}
        withSubscription store config $ \handle -> do
          awaitLive handle
          positions seen `shouldReturn` [10, 11, 12]
          checkpoint store "restart" 0 `shouldReturn` Just 13
          append store "pm:new-1"
          await (positions seen) (== [10, 11, 12, 14])
          await (checkpoint store "restart" 0) (== Just 14)
        Map.null <$> readTVarIO (Notify.namespaceRegistry (store ^. #notifier)) `shouldReturn` True
        restarted <- subscribe store ((cfg "restart" "pm" (\event -> record seen event >> pure Stop)) {batchSize = batch width})
        append store "pm:newer-1"
        clean restarted
        positions seen `shouldReturn` [10, 11, 12, 14, 15]
        binding store "restart" `shouldReturn` ("category_namespace", Just "pm")

  forM_
    [ ("pm", ["pm", "pm:a", "pm:a:b"], ["pmm", "pmish", "orders"]),
      ("pm:a", ["pm:a", "pm:a:b"], ["pm", "pm:ab"]),
      ("%_\\,雪", ["%_\\,雪", "%_\\,雪:子"], ["xx雪", "%X\\,雪"]),
      ("", ["", ":", ":a"], ["pm", "orders"]),
      ("pm:", ["pm:", "pm::child"], ["pm", "pm:child"]),
      ("pm-x", [], ["pm", "pm:x", "pm-x"])
    ]
    $ \(namespace, included, excluded) ->
      it ("matches literal category boundaries for " <> show namespace) $
        withTestStore $ \store -> do
          forM_ (included <> excluded) $ \category -> append store (category <> "-1")
          seen <- newIORef []
          withSubscription store (cfg "literal" namespace (record seen)) $ \handle -> do
            awaitLive handle
            positions seen `shouldReturn` [1 .. fromIntegral (length included)]

  it "keeps Stop at the stopping event, then replays the rest of a prefetched window" $
    withTestStore $ \store -> do
      forM_ ["pm-1", "pm:a-1", "pm:b-1", "noise-1"] (append store)
      first <- subscribe store (cfg "stop" "pm" (\_ -> pure Stop))
      clean first
      checkpoint store "stop" 0 `shouldReturn` Just 1
      seen <- newIORef []
      withSubscription store (cfg "stop" "pm" (record seen)) $ \handle -> do
        awaitLive handle
        positions seen `shouldReturn` [2, 3]
        checkpoint store "stop" 0 `shouldReturn` Just 4

  it "does not publish speculative completion while a handler is blocked or cancelled" $
    withTestStore $ \store -> do
      append store "pm-1"
      append store "noise-1"
      entered <- newEmptyMVar
      blocked <- newEmptyMVar
      withSubscription store (cfg "cancel" "pm" (\_ -> putMVar entered () >> takeMVar blocked >> pure Continue)) $ \handle -> do
        bounded (takeMVar entered)
        checkpoint store "cancel" 0 `shouldReturn` Just 0
        currentState handle >>= \case
          Just (Fsm.CatchingUp (GlobalPosition 0) _) -> pure ()
          other -> expectationFailure (show other)
      seen <- newIORef []
      withSubscription store (cfg "cancel" "pm" (record seen)) $ \handle -> do
        awaitLive handle
        positions seen `shouldReturn` [1]
        checkpoint store "cancel" 0 `shouldReturn` Just 2

  it "resolves Retry, DeadLetter, filtering and completed trailing rows with one tail save" $
    withTestStore $ \store -> do
      append store "pm-1"
      append store "pm:a-1"
      append store "noise-1"
      attempts <- newIORef (0 :: Int)
      saves <- newIORef []
      let handler' event
            | event ^. #globalPosition == GlobalPosition 1 = do
                attempt <- atomicModifyIORef' attempts (\n -> (n + 1, n))
                pure (if attempt == 0 then Retry (RetryDelay 0) else Continue)
            | otherwise = pure (DeadLetter (DeadLetterPoison "test"))
      withSaveCheckpointHookForTest (\_ p -> atomicModifyIORef' saves (\ps -> (p : ps, ()))) $
        withSubscription store (cfg "dispositions" "pm" handler') awaitLive
      readIORef attempts `shouldReturn` 2
      readIORef saves `shouldReturn` [GlobalPosition 3]
      checkpoint store "dispositions" 0 `shouldReturn` Just 3
      binding store "dispositions" `shouldReturn` ("category_namespace", Just "pm")
      let filtered = (cfg "filter" "pm" (\_ -> expectationFailure "filtered handler ran" >> pure Continue)) {selector = Just (const False)}
      withSubscription store filtered awaitLive
      checkpoint store "filter" 0 `shouldReturn` Just 3

  it "coalesces empty-window saves at 32 windows and the head" $
    withTestStore $ \store -> do
      replicateM_ 70 (append store "noise-1")
      saves <- newIORef []
      withSaveCheckpointHookForTest (\_ p -> atomicModifyIORef' saves (\ps -> (ps <> [p], ()))) $
        withSubscription store ((cfg "coalesce" "pm" (\_ -> pure Continue)) {batchSize = batch 1}) awaitLive
      readIORef saves `shouldReturn` map GlobalPosition [32, 64, 70]

  it "does not mistake hard-deleted tail gaps or an empty window for pending delivery" $
    withTestStore $ \store -> do
      append store "pm-1"
      append store "gone-1"
      Right _ <- runStoreIO store (hardDeleteStream (StreamName "gone-1"))
      seen <- newIORef []
      withSubscription store ((cfg "gaps" "pm" (record seen)) {batchSize = batch 1}) awaitLive
      positions seen `shouldReturn` [1]
      checkpoint store "gaps" 0 `shouldReturn` Just 2

  it "partitions plain and grouped namespaces completely with per-member empty windows" $
    withTestStore $ \store -> do
      forM_ [1 .. 25 :: Int] $ \n -> do
        append store "noise-1"
        append store ("pm:" <> T.pack (show n) <> "-1")
      members <- mapM (const (newIORef [])) [0 .. 2 :: Int32]
      forM_ (zip [0 ..] members) $ \(index, seen) ->
        withSubscription store ((cfg "group" "pm" (record seen)) {consumerGroup = Just (validConsumerGroup index 3), batchSize = batch 1}) $ \handle -> do
          awaitLive handle
          checkpoint store "group" index `shouldReturn` Just 50
      delivered <- concat <$> mapM positions members
      sort delivered `shouldBe` [2, 4 .. 50]

  it "retries catch-up and live fetch failures without skipping matching rows" $
    withTestStore $ \store -> do
      append store "pm-1"
      remaining <- newIORef True
      seen <- newIORef []
      let inject _ _ _ = do
            failNow <- atomicModifyIORef' remaining (\b -> (False, b))
            pure (if failNow then Just (Left Pool.AcquisitionTimeoutUsageError) else Nothing)
      withNamespaceWindowHookForTest inject $
        withSubscription store (cfg "fetch-fault" "pm" (record seen)) $ \handle -> do
          awaitLive handle
          writeIORef remaining True
          append store "pm:new-1"
          await (positions seen) (== [1, 2])
          await (checkpoint store "fetch-fault" 0) (== Just 2)

  it "replays after ordinary save failure and never persists an unfinished atomic dead letter" $
    withTestStore $ \store -> do
      append store "pm-1"
      append store "noise-1"
      -- A database trigger injects actual ordinary/atomic SQL failures, rather
      -- than throwing from a seam before attempting a save.
      sql store "CREATE FUNCTION fail_namespace_save() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.last_seen > 0 THEN RAISE EXCEPTION 'injected save failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER fail_namespace_save BEFORE UPDATE ON subscriptions FOR EACH ROW EXECUTE FUNCTION fail_namespace_save()"
      withSubscription store (cfg "save-fault" "pm" (\_ -> pure Continue)) awaitLive
      checkpoint store "save-fault" 0 `shouldReturn` Just 0
      failed <- subscribe store (cfg "atomic-fault" "pm" (\_ -> pure (DeadLetter (DeadLetterPoison "fail"))))
      waitWithTimeout 5_000_000 failed >>= \case
        Right (Left _) -> pure ()
        other -> expectationFailure (show other)
      checkpoint store "atomic-fault" 0 `shouldReturn` Just 0
      sql store "DROP TRIGGER fail_namespace_save ON subscriptions"
      seen <- newIORef []
      withSubscription store (cfg "save-fault" "pm" (record seen)) awaitLive
      positions seen `shouldReturn` [1]
      checkpoint store "save-fault" 0 `shouldReturn` Just 2

  it "preserves namespace identity through rebind, resize, adoption and strict startup" $
    withTestStore $ \store -> do
      withSubscription store (cfg "binding" "pm" (\_ -> pure Continue)) awaitLive
      mismatch <- subscribe store (defaultSubscriptionConfig (SubscriptionName "binding") (Category (CategoryName "pm")) (\_ -> pure Stop))
      waitWithTimeout 5_000_000 mismatch >>= \case
        Right (Left e) -> (fromException e :: Maybe SubscriptionTargetMismatch) `shouldSatisfy` maybe False (const True)
        other -> expectationFailure (show other)
      let tx :: Transaction.Transaction a -> IO a
          tx action = Pool.use (store ^. #pool) (Tx.transaction Tx.ReadCommitted Tx.Write action) >>= either (fail . show) pure
      report <- tx (rebindSubscriptionTargetTx (SubscriptionName "binding") (CategoryNamespace "pm:a") (GlobalPosition 0))
      previousBindings report `shouldBe` V.singleton (Just (CategoryNamespace "pm"))
      _ <- tx (resizeConsumerGroupTx (SubscriptionName "binding") (either (error . show) Prelude.id (mkConsumerGroupSize 2)))
      withSubscription store ((cfg "binding" "pm:a" (\_ -> pure Continue)) {consumerGroup = Just (validConsumerGroup 1 2), targetBindingPolicy = RequireBound}) awaitLive
      _ <- tx (resizeConsumerGroupTx (SubscriptionName "adopt") (either (error . show) Prelude.id (mkConsumerGroupSize 2)))
      withSubscription store ((cfg "adopt" "pm" (\_ -> pure Continue)) {consumerGroup = Just (validConsumerGroup 0 2)}) awaitLive
      withSubscription store ((cfg "adopt" "pm" (\_ -> pure Continue)) {consumerGroup = Just (validConsumerGroup 1 2), targetBindingPolicy = RequireBound}) awaitLive

  it "routes only exact/ancestor namespace cells and releases shared registrations idempotently" $ do
    registry <- newTVarIO Map.empty
    (pm, release1) <- atomically (Notify.registerNamespace registry "pm")
    (same, release2) <- atomically (Notify.registerNamespace registry "pm")
    (nested, release3) <- atomically (Notify.registerNamespace registry "pm:a")
    (empty, release4) <- atomically (Notify.registerNamespace registry "")
    (colon, release5) <- atomically (Notify.registerNamespace registry "pm:")
    (pm == same) `shouldBe` True
    atomically (Notify.notifyNamespace registry "pm:a:b")
    mapM readTVarIO [pm, nested, empty, colon] `shouldReturn` [1, 1, 0, 0]
    atomically (Notify.notifyNamespace registry "pm::child" >> Notify.notifyNamespace registry ":child")
    mapM readTVarIO [pm, nested, empty, colon] `shouldReturn` [2, 1, 1, 1]
    atomically (release1 >> release1)
    Map.size <$> readTVarIO registry `shouldReturn` 4
    atomically (release2 >> release3 >> release4 >> release5)
    Map.null <$> readTVarIO registry `shouldReturn` True
    (replacement, release6) <- atomically (Notify.registerNamespace registry "pm")
    atomically (release2 >> Notify.notifyNamespace registry "pm")
    readTVarIO replacement `shouldReturn` 1
    atomically release6
    -- Empty registry path must not even evaluate a category.
    atomically (Notify.notifyNamespace registry (error "empty registry evaluated category"))

  it "suppresses unrelated live fetches and recovers a lost notification at the safety tick" $
    withNamespaceSafetyPollForTest 200_000 $
      withTestStore $ \store -> do
        fetches <- newIORef (0 :: Int)
        seen <- newIORef []
        withNamespaceWindowHookForTest (\_ _ _ -> atomicModifyIORef' fetches (\n -> (n + 1, Nothing))) $
          withSubscription store (cfg "idle" "pm" (record seen)) $ \handle -> do
            awaitLive handle
            append store "noise-1"
            -- Wait for the actual listener to process the unrelated notification.
            await (readTVarIO (Notify.categoryGenerations (store ^. #notifier))) (Map.member "noise")
            readIORef fetches `shouldReturn` 0
            await (readIORef fetches) (> 0)
            -- Temporarily remove the sole registry entry to simulate a lost wake.
            sql store "ALTER TABLE streams DISABLE TRIGGER stream_events_notify_insert; ALTER TABLE streams DISABLE TRIGGER stream_events_notify_update"
            append store "pm:new-1"
            sql store "ALTER TABLE streams ENABLE TRIGGER stream_events_notify_insert; ALTER TABLE streams ENABLE TRIGGER stream_events_notify_update"
            await (positions seen) (== [2])

  it "keeps a captured head finite and does not lose a notification during its drain" $
    withTestStore $ \store -> do
      append store "pm-1"
      captured <- newIORef False
      seen <- newIORef []
      let inject _ _ headPosition = do
            first <- atomicModifyIORef' captured (\done -> (True, not done))
            when first $ do
              headPosition `shouldBe` GlobalPosition 1
              append store "pm:new-1"
              await (readTVarIO (Notify.categoryGenerations (store ^. #notifier))) (Map.member "pm:new")
            pure Nothing
      withNamespaceWindowHookForTest inject $
        withSubscription store ((cfg "race" "pm" (record seen)) {batchSize = batch 1}) $ \handle -> do
          awaitLive handle
          await (positions seen) (== [1, 2])
          await (checkpoint store "race" 0) (== Just 2)

  it "never advances past an unhandled decode failure, and ignores unrelated decode failures" $ do
    let reject event = pure (Left (DecodeFailure (event ^. #eventId) "test refusal"))
        broken :: ConnectionSettings -> ConnectionSettings
        broken settings = settings {storeSettings = defaultStoreSettings {decodeHook = Just reject}}
    withTestStoreSettings broken $ \store -> do
      append store "noise-1"
      withSubscription store (cfg "unrelated-decode" "pm" (\_ -> expectationFailure "unrelated handler" >> pure Stop)) awaitLive
      checkpoint store "unrelated-decode" 0 `shouldReturn` Just 1
      append store "pm-1"
      append store "noise-1"
      handle <- subscribe store ((cfg "decode" "pm" (\_ -> expectationFailure "undecodable handler" >> pure Stop)) {retryPolicy = RetryPolicy 1})
      waitWithTimeout 5_000_000 handle >>= \case
        Right (Left err) -> (fromException err :: Maybe SubscriptionUndecodable) `shouldSatisfy` maybe False (const True)
        other -> expectationFailure (show other)
      checkpoint store "decode" 0 `shouldReturn` Just 0
      -- The alternate callback resolves only matching undecodable events.
      withSubscription store ((cfg "decode" "pm" (\_ -> pure Stop)) {undecodableHandler = Just (\_ _ -> pure Continue)}) awaitLive
      checkpoint store "decode" 0 `shouldReturn` Just 3

  it "shares live namespace wakes across grouped members and reconnects the listener" $
    withNamespaceSafetyPollForTest 100_000 $
      withTestStore $ \store -> do
        members <- mapM (const (newIORef [])) [0 .. 2 :: Int32]
        let configs = [(cfg "live-group" "pm" (record seen)) {consumerGroup = Just (validConsumerGroup index 3), batchSize = batch 1} | (index, seen) <- zip [0 ..] members]
        bracket (mapM (subscribe store) configs) (mapM_ cancel) $ \handles -> do
          mapM_ awaitLive handles
          forM_ [1 .. 6 :: Int] $ \n -> append store ("pm:new:" <> T.pack (show n) <> "-1")
          await (concat <$> mapM positions members) ((== [1 .. 6]) . sort)
          pid <- waitForListenerPid (store ^. #pool) 5_000_000
          terminateBackend (store ^. #pool) pid
          append store "pm:reconnect-1"
          await (concat <$> mapM positions members) ((== [1 .. 7]) . sort)
          _ <- waitForListenerPidNotEqual (store ^. #pool) pid 5_000_000
          pure ()
        Map.null <$> readTVarIO (Notify.namespaceRegistry (store ^. #notifier)) `shouldReturn` True

  it "retains a failed empty frontier and retries its flush without another append" $
    withNamespaceSafetyPollForTest 50_000 $
      withTestStore $ \store -> do
        append store "noise-1"
        sql store "CREATE FUNCTION fail_empty_save() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected flush failure'; END $$; CREATE TRIGGER fail_empty_save BEFORE UPDATE ON subscriptions FOR EACH ROW EXECUTE FUNCTION fail_empty_save()"
        withSubscription store (cfg "flush-fault" "pm" (\_ -> pure Continue)) $ \handle -> do
          awaitLive handle
          checkpoint store "flush-fault" 0 `shouldReturn` Just 0
          sql store "DROP TRIGGER fail_empty_save ON subscriptions"
          await (checkpoint store "flush-fault" 0) (== Just 1)

  it "releases namespace registrations when startup fails" $
    withTestStore $ \store -> do
      handle <- subscribe store ((cfg "missing" "pm" (\_ -> pure Continue)) {missingCheckpointPolicy = FailIfMissing})
      waitWithTimeout 5_000_000 handle >>= \case
        Right (Left _) -> pure ()
        other -> expectationFailure (show other)
      Map.null <$> readTVarIO (Notify.namespaceRegistry (store ^. #notifier)) `shouldReturn` True

cfg :: Text -> Text -> (RecordedEvent -> IO SubscriptionResult) -> SubscriptionConfig
cfg name namespace = defaultSubscriptionConfig (SubscriptionName name) (CategoryNamespace namespace)

batch :: Int32 -> BatchSize
batch = either (error . show) Prelude.id . mkBatchSize

record :: IORef [Int64] -> RecordedEvent -> IO SubscriptionResult
record ref event = do
  let GlobalPosition pos = event ^. #globalPosition
  atomicModifyIORef' ref (\xs -> (xs <> [pos], ()))
  pure Continue

positions :: IORef [Int64] -> IO [Int64]
positions = readIORef

append :: KirokuStore -> Text -> IO ()
append store stream = do
  Right _ <- runStoreIO store (appendToStream (StreamName stream) AnyVersion [makeEvent "E" (Aeson.object [])])
  pure ()

await :: IO a -> (a -> Bool) -> IO ()
await action predicate = bounded go
  where
    go = action >>= \value -> if predicate value then pure () else threadDelay 1000 >> go

bounded :: IO a -> IO a
bounded action = timeout 5_000_000 action >>= maybe (fail "namespace test timed out") pure

awaitLive :: SubscriptionHandle -> IO ()
awaitLive handle = await (currentState handle) (\case Just Fsm.Live {} -> True; _ -> False)

clean :: SubscriptionHandle -> IO ()
clean handle =
  waitWithTimeout 5_000_000 handle >>= \case
    Right (Right ()) -> pure ()
    other -> expectationFailure (show other)

checkpoint :: KirokuStore -> Text -> Int32 -> IO (Maybe Int64)
checkpoint store name index = session store (Session.statement (name, index) SQL.getCheckpointMemberStmt)

binding :: KirokuStore -> Text -> IO (Text, Maybe Text)
binding store name = session store (Session.statement name (preparable "SELECT target_kind,target_category FROM subscriptions WHERE subscription_name=$1 AND consumer_group_member=0" (E.param (E.nonNullable E.text)) (D.singleRow ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nullable D.text)))))

sql :: KirokuStore -> Text -> IO ()
sql store = session store . Session.script

session :: KirokuStore -> Session.Session a -> IO a
session store action = Pool.use (store ^. #pool) action >>= either (fail . show) pure
