{-# LANGUAGE MultilineStrings #-}

module Test.SubscriptionTarget (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (Exception, SomeException, fromException, throwIO, toException, try)
import Control.Lens ((^.))
import Control.Monad (void)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Vector qualified as V
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store
import Kiroku.Store.Subscription.Stream qualified as Buffer
import System.Timeout (timeout)
import Test.Helpers (makeEvent, validConsumerGroup, waitWithTimeout, withTestStore, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = do
    describe "subscription configuration" $ do
        it "validates batch and bridge buffer boundaries as values" $ do
            mkBatchSize 0 `shouldBe` Left (InvalidBatchSize 0)
            mkBatchSize (-1) `shouldBe` Left (InvalidBatchSize (-1))
            fmap batchSizeValue (mkBatchSize 1) `shouldBe` Right 1
            batchSizeValue defaultBatchSize `shouldBe` 100
            Buffer.mkStreamBufferSize 0 `shouldBe` Left (Buffer.InvalidStreamBufferSize 0)
            fmap Buffer.streamBufferSizeValue (Buffer.mkStreamBufferSize 1) `shouldBe` Right 1
        it "exposes every runtime startup refusal through the parent and concrete catches" $ do
            let name = SubscriptionName "hierarchy"
                key = SubscriptionCheckpointKey name 0
            assertHierarchy (SubscriptionCheckpointMissing key)
            assertHierarchy (ConsumerGroupGuardConflict name 0)
            assertHierarchy (ConsumerGroupSizeMismatch name 2 (V.singleton 1))
            assertHierarchy (SubscriptionTargetMismatch name AllStreams (V.singleton Nothing))
    describe "checkpoint target" $ do
        it "refuses accidental target reuse before delivery, then resumes after explicit rebind" $
            withTestStore $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "target-1") NoStream [makeEvent "E" (Aeson.object [])]
                first <- subscribe store (cfg "retarget" AllStreams (\_ -> pure Stop))
                clean first
                called <- newIORef False
                let newTarget = Category (CategoryName "target")
                refused <- subscribe store (cfg "retarget" newTarget (\_ -> writeIORef called True >> pure Stop))
                mismatch refused
                readIORef called `shouldReturn` False
                report <- rebind store "retarget" newTarget 0
                reboundMemberCount report `shouldBe` 1
                previousBindings report `shouldBe` V.singleton (Just AllStreams)
                accepted <- subscribe store (cfg "retarget" newTarget (\_ -> writeIORef called True >> pure Stop))
                clean accepted
                readIORef called `shouldReturn` True
                rows store "retarget" `shouldReturn` [(0, "category", Just "target", 1)]
        it "adopts every legacy member once and emits one bound event for the name" $ do
            events <- newIORef []
            let observe e = modifyIORef' events (e :)
            withTestStoreSettings (\s -> s{eventHandler = Just observe}) $ \store -> do
                void $ resize store "adopt" 2
                startLive store ((cfg "adopt" AllStreams (\_ -> pure Continue)){consumerGroup = Just (validConsumerGroup 0 2)})
                startLive store ((cfg "adopt" AllStreams (\_ -> pure Continue)){consumerGroup = Just (validConsumerGroup 1 2), targetBindingPolicy = RequireBound})
                rows store "adopt" `shouldReturn` [(0, "all", Nothing, 0), (1, "all", Nothing, 0)]
                seen <- readIORef events
                length [() | KirokuEventSubscriptionTargetBound (SubscriptionName "adopt") AllStreams _ <- seen] `shouldBe` 1
        it "refuses unbound rows under RequireBound without changing rows or invoking the handler" $
            withTestStore $ \store -> do
                void $ resize store "strict" 1
                called <- newIORef False
                handle <- subscribe store ((cfg "strict" AllStreams (\_ -> writeIORef called True >> pure Continue)){targetBindingPolicy = RequireBound})
                mismatch handle
                readIORef called `shouldReturn` False
                rows store "strict" `shouldReturn` [(0, "unbound", Nothing, 0)]
        it "refuses mixed bound/unbound siblings before inserting a missing member" $
            withTestStore $ \store -> do
                void $ resize store "mixed-target" 3
                runSession store (Session.script "UPDATE subscriptions SET target_kind = 'all' WHERE subscription_name = 'mixed-target' AND consumer_group_member = 0; DELETE FROM subscriptions WHERE subscription_name = 'mixed-target' AND consumer_group_member = 2")
                handle <- subscribe store ((cfg "mixed-target" AllStreams (\_ -> expectationFailure "handler ran" >> pure Stop)){consumerGroup = Just (validConsumerGroup 2 3)})
                mismatch handle
                rows store "mixed-target" `shouldReturn` [(0, "all", Nothing, 0), (1, "unbound", Nothing, 0)]
        it "does not adopt siblings when FailIfMissing refuses an absent member" $
            withTestStore $ \store -> do
                void $ resize store "missing-member" 2
                runSession store (Session.script "DELETE FROM subscriptions WHERE subscription_name = 'missing-member' AND consumer_group_member = 1")
                handle <- subscribe store ((cfg "missing-member" AllStreams (\_ -> pure Stop)){consumerGroup = Just (validConsumerGroup 1 2), missingCheckpointPolicy = FailIfMissing})
                waitWithTimeout 5_000_000 handle >>= \case
                    Right (Left e) -> (fromException e :: Maybe SubscriptionCheckpointMissing) `shouldSatisfy` maybe False (const True)
                    other -> expectationFailure (show other)
                rows store "missing-member" `shouldReturn` [(0, "unbound", Nothing, 0)]
        it "serializes conflicting targets on an initially absent name" $
            withTestStore $ \store -> do
                [a, b] <- Async.mapConcurrently (\target -> subscribe store (cfg "competing-targets" target (\_ -> pure Continue))) [AllStreams, Category (CategoryName "other")]
                outcome <- timeout 5_000_000 (Async.race (wait a) (wait b))
                case outcome of
                    Just (Left (Left e)) -> assertMismatch e
                    Just (Right (Left e)) -> assertMismatch e
                    other -> expectationFailure (show other)
                mapM_ cancel [a, b]
                length <$> rows store "competing-targets" `shouldReturn` 1
        it "preserves category binding on resize and initializes fresh names under RequireBound" $
            withTestStore $ \store -> do
                let target = Category (CategoryName "preserved")
                startLive store ((cfg "bound-resize" target (\_ -> pure Continue)){targetBindingPolicy = RequireBound})
                void $ resize store "bound-resize" 3
                rows store "bound-resize" `shouldReturn` [(m, "category", Just "preserved", 0) | m <- [0 .. 2]]
                startLive store ((cfg "bound-resize" target (\_ -> pure Continue)){consumerGroup = Just (validConsumerGroup 2 3), targetBindingPolicy = RequireBound})
        it "rebinds all members atomically, repeats idempotently, and rolls back with the caller" $
            withTestStore $ \store -> do
                void $ resize store "rebind-group" 3
                report <- rebind store "rebind-group" AllStreams 7
                reboundMemberCount report `shouldBe` 3
                previousBindings report `shouldBe` V.singleton Nothing
                rows store "rebind-group" `shouldReturn` [(m, "all", Nothing, 7) | m <- [0 .. 2]]
                again <- rebind store "rebind-group" AllStreams 7
                previousBindings again `shouldBe` V.singleton (Just AllStreams)
                void $ runSession store $ TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write $ do
                    result <- rebindSubscriptionTargetTx (SubscriptionName "rebind-group") (Category (CategoryName "rollback")) (GlobalPosition 0)
                    Tx.condemn
                    pure result
                rows store "rebind-group" `shouldReturn` [(m, "all", Nothing, 7) | m <- [0 .. 2]]
                absent <- Pool.use (store ^. #pool) $ TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write (rebindSubscriptionTargetTx (SubscriptionName "absent") AllStreams (GlobalPosition 0))
                absent `shouldSatisfy` either (const True) (const False)
        it "persists target binding through an atomic dead-letter save" $
            withTestStore $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "poison-target-1") NoStream [makeEvent "E" (Aeson.object [])]
                withSubscription store (cfg "target-dead-letter" (Category (CategoryName "poison")) (\_ -> pure (DeadLetter (DeadLetterPoison "chosen by consumer")))) $ \_ -> do
                    let awaitDurable = do
                            persisted <- rows store "target-dead-letter"
                            if persisted == [(0, "category", Just "poison", 1)]
                                then pure ()
                                else threadDelay 1_000 >> awaitDurable
                    timeout 5_000_000 awaitDurable `shouldReturn` Just ()
                rows store "target-dead-letter" `shouldReturn` [(0, "category", Just "poison", 1)]

assertHierarchy :: (Exception e, Eq e) => e -> IO ()
assertHierarchy refusal = do
    parent <- try (throwIO refusal) :: IO (Either SomeSubscriptionStartupFailure ())
    case parent of
        Left caught -> fromException (toException caught) `shouldBe` Just refusal
        Right () -> expectationFailure "parent catch did not match"

cfg :: Text -> SubscriptionTarget -> EventHandler -> SubscriptionConfig
cfg name = defaultSubscriptionConfig (SubscriptionName name)

clean :: SubscriptionHandle -> IO ()
clean handle =
    waitWithTimeout 5_000_000 handle >>= \case
        Right (Right ()) -> pure ()
        other -> expectationFailure (show other)

assertMismatch :: SomeException -> IO ()
assertMismatch e = do
    (fromException e :: Maybe SubscriptionTargetMismatch) `shouldSatisfy` maybe False (const True)
    (fromException e :: Maybe SomeSubscriptionStartupFailure) `shouldSatisfy` maybe False (const True)

mismatch :: SubscriptionHandle -> IO ()
mismatch handle =
    waitWithTimeout 5_000_000 handle >>= \case
        Right (Left e) -> assertMismatch e
        other -> expectationFailure (show other)

startLive :: KirokuStore -> SubscriptionConfig -> IO ()
startLive store config = withSubscription store config $ \handle -> do
    result <- timeout 5_000_000 (awaitLive handle)
    result `shouldBe` Just ()
  where
    awaitLive handle =
        currentState handle >>= \case
            Just state | stateName state == "live" -> pure ()
            _ -> threadDelay 1_000 >> awaitLive handle

runSession :: KirokuStore -> Session.Session a -> IO a
runSession store session = Pool.use (store ^. #pool) session >>= either (fail . show) pure

resize :: KirokuStore -> Text -> Int32 -> IO ConsumerGroupResizeReport
resize store name n = let Right size = mkConsumerGroupSize n in runSession store $ TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write (resizeConsumerGroupTx (SubscriptionName name) size)
rebind :: KirokuStore -> Text -> SubscriptionTarget -> Int64 -> IO SubscriptionTargetRebindReport
rebind store name target position = runSession store $ TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write (rebindSubscriptionTargetTx (SubscriptionName name) target (GlobalPosition position))

rows :: KirokuStore -> Text -> IO [(Int32, Text, Maybe Text, Int64)]
rows store name = V.toList <$> runSession store (Session.statement name stmt)
  where
    stmt =
        preparable
            "SELECT consumer_group_member, target_kind, target_category, last_seen FROM subscriptions WHERE subscription_name = $1 ORDER BY consumer_group_member"
            (E.param (E.nonNullable E.text))
            (D.rowVector ((,,,) <$> D.column (D.nonNullable D.int4) <*> D.column (D.nonNullable D.text) <*> D.column (D.nullable D.text) <*> D.column (D.nonNullable D.int8)))
