{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module Test.ConsumerGroupResize (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM
import Control.Exception (SomeException, fromException)
import Control.Lens ((^.))
import Control.Monad (forM_, void)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef
import Data.Int (Int32, Int64)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import System.Timeout (timeout)
import Test.Helpers (makeEvent, validConsumerGroup, waitWithTimeout, withTestStore, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = describe "consumer-group resize" $ do
    it "rejects invalid sizes and member indices at construction" $ do
        mkConsumerGroupSize 0 `shouldBe` Left (InvalidConsumerGroup 0 0)
        mkConsumerGroupSize (-1) `shouldBe` Left (InvalidConsumerGroup 0 (-1))
        let size2 = groupSize 2
        mkConsumerGroup (-1) size2 `shouldBe` Left (InvalidConsumerGroup (-1) 2)
        mkConsumerGroup 2 size2 `shouldBe` Left (InvalidConsumerGroup 2 2)
        mkConsumerGroup 1 size2 `shouldBe` Right (validConsumerGroup 1 2)

    it "refuses a configured size that disagrees with stored topology before creating a member" $ do
        refusals <- newIORef []
        let observe = \case
                KirokuEventSubscriptionGroupSizeMismatch refusal group -> modifyIORef' refusals ((refusal, group) :)
                _ -> pure ()
        withTestStoreSettings (\settings -> settings{eventHandler = Just observe}) $ \store -> do
            seedCheckpoint store "mismatch" 0 2 5
            called <- newIORef False
            handle <- subscribe store $ config "mismatch" 2 3 $ \_ -> writeIORef called True >> pure Continue
            expectMismatch handle "mismatch" 3 [2]
            readIORef called `shouldReturn` False
            rows store "mismatch" `shouldReturn` [(0, 2, 5)]
            readIORef refusals `shouldReturn` [(ConsumerGroupSizeMismatch (SubscriptionName "mismatch") 3 (Vector.singleton 2), GroupMember 2 3)]

    it "also refuses an ordinary subscription over an existing larger group" $
        withTestStore $ \store -> do
            seedCheckpoint store "ordinary-mismatch" 0 2 0
            handle <- subscribe store (defaultSubscriptionConfig (SubscriptionName "ordinary-mismatch") AllStreams (\_ -> pure Continue))
            expectMismatch handle "ordinary-mismatch" 1 [2]

    it "refuses an underestimated derived topology until resized" $
        withTestStore $ \store -> do
            -- The upgrade test proves a lone legacy member derives size 1.
            seedCheckpoint store "underestimated" 0 1 8
            refused <- subscribe store (config "underestimated" 0 2 (\_ -> pure Continue))
            expectMismatch refused "underestimated" 2 [1]
            void $ resize store "underestimated" 2
            accepted <- subscribe store (config "underestimated" 0 2 (\_ -> pure Continue))
            awaitLive accepted
            cancel accepted
            rows store "underestimated" `shouldReturn` [(0, 2, 8), (1, 2, 8)]

    it "refuses mixed stored sizes even when its own row agrees" $
        withTestStore $ \store -> do
            seedCheckpoint store "mixed" 0 2 0
            seedCheckpoint store "mixed" 1 3 0
            handle <- subscribe store (config "mixed" 0 2 (\_ -> pure Continue))
            expectMismatch handle "mixed" 2 [2, 3]

    it "serializes concurrent initializers with competing group sizes" $
        withTestStore $ \store -> do
            [firstHandle, secondHandle] <- Async.mapConcurrently (\n -> subscribe store (config "concurrent" 0 n (\_ -> pure Continue))) [2, 3]
            -- The winner reaches Live; the loser exits with a typed refusal.
            result <- timeout 5_000_000 $ Async.race (wait firstHandle) (wait secondHandle)
            case result of
                Just (Left outcome) -> assertMismatch outcome
                Just (Right outcome) -> assertMismatch outcome
                Nothing -> expectationFailure "competing topology startup timed out"
            mapM_ cancel [firstHandle, secondHandle]
            stored <- rows store "concurrent"
            length stored `shouldBe` 1
            stored `shouldSatisfy` \case [(0, n, 0)] -> n == 2 || n == 3; _ -> False

    it "persists configured topology on initialization, ordinary saves and dead-letter saves" $
        withTestStore $ \store -> do
            void $ runStoreIO store $ appendToStream (StreamName "persist-1") NoStream [makeEvent "E" (Aeson.object [])]
            -- A size-1 group exercises all rows deterministically. Size >1 is
            -- checked below via explicit ordinary and dead-letter SQL paths.
            handle <- subscribe store (config "saved" 0 1 (\_ -> pure Stop))
            expectClean handle
            rows store "saved" `shouldReturn` [(0, 1, 1)]
            live <- subscribe store ((config "initialized" 2 3 (\_ -> pure Continue)){missingCheckpointPolicy = FromCurrentHead})
            awaitLive live
            cancel live
            rows store "initialized" `shouldReturn` [(2, 3, 1)]
            seedCheckpoint store "saved-size" 1 4 20
            seedCheckpoint store "saved-size" 1 4 10
            rows store "saved-size" `shouldReturn` [(1, 4, 20)]
            Right events <- runStoreIO store (readAllForward (GlobalPosition 0) 10)
            let event = Vector.head events
                EventId eid = event ^. #eventId
                params = SQL.DeadLetterParams "dead-letter-size" 1 "unbound" Nothing 4 1 eid (Aeson.object []) "test" 1
            runSession store (Session.statement params SQL.insertDeadLetterAndCheckpointStmt)
            rows store "dead-letter-size" `shouldReturn` [(1, 4, 1)]
            let StreamId sid = event ^. #originalStreamId
                ownerStmt =
                    preparable
                        "SELECT (((hashtextextended($1::bigint::text, 0) % 4) + 4) % 4)::int4"
                        (E.param (E.nonNullable E.int8))
                        (D.singleRow (D.column (D.nonNullable D.int4)))
            owner <- runSession store (Session.statement sid ownerStmt)
            saved <- subscribe store (config "worker-save-size" owner 4 (\_ -> pure Stop))
            expectClean saved
            rows store "worker-save-size" `shouldReturn` [(owner, 4, 1)]
            deadLettered <- subscribe store (config "worker-dead-letter-size" owner 4 (\_ -> pure (DeadLetter (DeadLetterPoison "explicit consumer decision"))))
            awaitLive deadLettered
            cancel deadLettered
            rows store "worker-dead-letter-size" `shouldReturn` [(owner, 4, 1)]

    it "delivers every seeded event after equalizing size 2 to size 3" $
        withTestStore $ \store -> do
            forM_ [1 .. 40 :: Int] $ \i -> do
                result <- runStoreIO store $ appendToStream (StreamName ("resize-" <> Text.pack (show i))) NoStream [makeEvent "E" (Aeson.object [])]
                result `shouldSatisfy` either (const False) (const True)
            Right events <- runStoreIO store (readAllForward (GlobalPosition 0) 100)
            let expected = Set.fromList [event ^. #eventId | event <- Vector.toList events]
            -- Member 0 has seen nothing, member 1 has crossed the full log.
            -- Remember its actual delivered set; a naive size change loses
            -- streams that move from old member 0 to new member 1.
            oldFast <- runSession store (Session.statement (0, 1, 2, 100) SQL.readAllForwardConsumerGroupStmt)
            naive <- mapM (\(m, p) -> runSession store (Session.statement (p, m, 3, 100) SQL.readAllForwardConsumerGroupStmt)) [(0, 0), (1, 40), (2, 0)]
            let alreadySeen = Set.fromList [e ^. #eventId | e <- Vector.toList oldFast]
                naiveSeen = Set.fromList [e ^. #eventId | batch <- naive, e <- Vector.toList batch]
            Set.union alreadySeen naiveSeen `shouldNotBe` expected
            seedCheckpoint store "skewed" 0 2 0
            seedCheckpoint store "skewed" 1 2 40
            refused <- subscribe store (config "skewed" 1 3 (\_ -> pure Continue))
            expectMismatch refused "skewed" 3 [2]
            report <- resize store "skewed" 3
            report `shouldBe` ConsumerGroupResizeReport (Vector.singleton 2) 2 (groupSize 3) (GlobalPosition 0)
            delivered <- newTVarIO alreadySeen
            handles <- mapM (\m -> subscribe store (config "skewed" m 3 (\e -> atomically (modifyTVar' delivered (Set.insert (e ^. #eventId))) >> pure Continue))) [0, 1, 2]
            complete <- timeout 15_000_000 (atomically (readTVar delivered >>= check . (== expected)))
            mapM_ cancel handles
            complete `shouldBe` Just ()
            readTVarIO delivered `shouldReturn` expected

    it "is idempotent when repeated at the same size and retains surviving member identities" $
        withTestStore $ \store -> do
            seedCheckpoint store "repeat" 0 2 5
            seedCheckpoint store "repeat" 1 2 20
            oldIds <- memberIds store "repeat"
            void $ resize store "repeat" 3
            originalRows <- rows store "repeat"
            resizedIds <- memberIds store "repeat"
            take 2 resizedIds `shouldBe` oldIds
            second <- resize store "repeat" 3
            rows store "repeat" `shouldReturn` originalRows
            memberIds store "repeat" `shouldReturn` resizedIds
            originalRows `shouldBe` [(0, 3, 5), (1, 3, 5), (2, 3, 5)]
            resumePosition second `shouldBe` GlobalPosition 5
            previousMemberCount second `shouldBe` 3

    it "starts a missing group at zero and removes obsolete members on shrink" $
        withTestStore $ \store -> do
            report <- resize store "missing" 3
            previousMemberCount report `shouldBe` 0
            resumePosition report `shouldBe` GlobalPosition 0
            rows store "missing" `shouldReturn` [(0, 3, 0), (1, 3, 0), (2, 3, 0)]
            void $ resize store "missing" 1
            rows store "missing" `shouldReturn` [(0, 1, 0)]

    it "rolls back the complete resize with the caller transaction" $
        withTestStore $ \store -> do
            seedCheckpoint store "rollback" 0 2 5
            seedCheckpoint store "rollback" 1 2 20
            void $ runSession store $ TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write $ do
                report <- resizeConsumerGroupTx (SubscriptionName "rollback") (groupSize 3)
                Tx.condemn
                pure report
            rows store "rollback" `shouldReturn` [(0, 2, 5), (1, 2, 20)]

groupSize :: Int32 -> ConsumerGroupSize
groupSize = either (error . show) Prelude.id . mkConsumerGroupSize

config :: Text -> Int32 -> Int32 -> EventHandler -> SubscriptionConfig
config name m n handler =
    (defaultSubscriptionConfig (SubscriptionName name) AllStreams handler)
        { consumerGroup = Just (validConsumerGroup m n)
        }

seedCheckpoint :: KirokuStore -> Text -> Int32 -> Int32 -> Int64 -> IO ()
seedCheckpoint store name m n p = runSession store (Session.statement (name, m, p, n, "unbound", Nothing) SQL.saveCheckpointMemberStmt)

resize :: KirokuStore -> Text -> Int32 -> IO ConsumerGroupResizeReport
resize store name n = runSession store $ TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write (resizeConsumerGroupTx (SubscriptionName name) (groupSize n))

rows :: KirokuStore -> Text -> IO [(Int32, Int32, Int64)]
rows store name = Vector.toList <$> runSession store (Session.statement name stmt)
  where
    stmt =
        preparable
            "SELECT consumer_group_member, consumer_group_size, last_seen FROM subscriptions WHERE subscription_name = $1 ORDER BY consumer_group_member"
            (E.param (E.nonNullable E.text))
            (D.rowVector ((,,) <$> D.column (D.nonNullable D.int4) <*> D.column (D.nonNullable D.int4) <*> D.column (D.nonNullable D.int8)))

runSession :: KirokuStore -> Session.Session a -> IO a
runSession store session = Pool.use (store ^. #pool) session >>= either (error . show) pure

expectMismatch :: SubscriptionHandle -> Text -> Int32 -> [Int32] -> IO ()
expectMismatch handle name n observed = do
    result <- waitWithTimeout 5_000_000 handle
    case result of
        Right (Left exception) -> fromException exception `shouldBe` Just (ConsumerGroupSizeMismatch (SubscriptionName name) n (Vector.fromList observed))
        other -> expectationFailure ("expected topology mismatch, got " <> show other)

assertMismatch :: Either SomeException () -> IO ()
assertMismatch = \case
    Left exception -> (fromException exception :: Maybe ConsumerGroupSizeMismatch) `shouldSatisfy` maybe False (const True)
    Right () -> expectationFailure "expected competing-size startup refusal"

expectClean :: SubscriptionHandle -> IO ()
expectClean handle =
    waitWithTimeout 5_000_000 handle >>= \case
        Right (Right ()) -> pure ()
        other -> expectationFailure (show other)

awaitLive :: SubscriptionHandle -> IO ()
awaitLive handle = do
    result <- timeout 5_000_000 loop
    result `shouldBe` Just ()
  where
    loop =
        currentState handle >>= \case
            Just state | stateName state == "live" -> pure ()
            _ -> threadDelay 1_000 >> loop

memberIds :: KirokuStore -> Text -> IO [Int64]
memberIds store name =
    runSession store $
        Session.statement name $
            preparable
                "SELECT subscription_id FROM subscriptions WHERE subscription_name = $1 ORDER BY consumer_group_member"
                (E.param (E.nonNullable E.text))
                (D.rowList (D.column (D.nonNullable D.int8)))
