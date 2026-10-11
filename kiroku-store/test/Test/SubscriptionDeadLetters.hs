{-# LANGUAGE OverloadedLabels #-}

module Test.SubscriptionDeadLetters (spec) where

import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_, void)
import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store hiding (HistoryRetentionInventoryQuery (..), member)
import Kiroku.Store.SQL qualified as SQL
import Test.Helpers
import Test.Hspec

spec :: Spec
spec = describe "SubscriptionDeadLetters" $ do
    it "validates page sizes including both boundaries" $ do
        forM_ [0, -1, 1001] $ \n -> mkSubscriptionDeadLetterLimit n `shouldBe` Left (SubscriptionDeadLetterLimitOutOfRange n)
        forM_ [1, 1000] $ \n -> fmap subscriptionDeadLetterLimitValue (mkSubscriptionDeadLetterLimit n) `shouldBe` Right n
        subscriptionDeadLetterLimitValue defaultSubscriptionDeadLetterLimit `shouldBe` 100
    around withTestStore $ do
        it "returns empty pages through both Store interpreters" $ \store -> do
            let query = defaultSubscriptionDeadLetterQuery (SubscriptionName "absent")
            runStoreIO store (subscriptionDeadLetters query) `shouldReturn` Right (SubscriptionDeadLetterPage V.empty Nothing)
            (runEff . runErrorNoCallStack @StoreError . runKirokuStoreWith store . runStoreResource $ subscriptionDeadLetters query)
                `shouldReturn` Right (SubscriptionDeadLetterPage V.empty Nothing)
        it "pages without omissions, isolates names and matches the internal member read" $ \store -> do
            events <- seedEvents store 7
            mapM_ (insertDeadLetterForEvent store "page") (take 5 events)
            mapM_ (insertDeadLetterForEvent store "other") (drop 5 events)
            let query = (defaultSubscriptionDeadLetterQuery (SubscriptionName "page")){limit = validLimit 2}
            first <- page store query
            second <- page store query{after = first ^. #nextCursor}
            third <- page store query{after = second ^. #nextCursor}
            map positions [first, second, third] `shouldBe` [[5, 4], [3, 2], [1]]
            third ^. #nextCursor `shouldBe` Nothing
            Right internal <- Pool.use (store ^. #pool) (Session.statement ("page", 0) SQL.readDeadLettersStmt)
            map SQL.deadLetterGlobalPosition (V.toList internal) `shouldBe` [5, 4, 3, 2, 1]
            forM_ [5, 1000] $ \n -> do
                final <- page store query{limit = validLimit n}
                positions final `shouldBe` [5, 4, 3, 2, 1]
                final ^. #nextCursor `shouldBe` Nothing
        it "merges historical members and resolves same-position ties with an exclusive cursor" $ \store -> do
            [event] <- seedEvents store 1
            forM_ [0, 1, 9] $ \member -> insertDeadLetterWith store "ties" member (object []) "tie" 2 event
            let query = (defaultSubscriptionDeadLetterQuery (SubscriptionName "ties")){limit = validLimit 1}
            first <- page store query
            second <- page store query{after = first ^. #nextCursor}
            third <- page store query{after = second ^. #nextCursor}
            map (\p -> map (\row -> row ^. #consumerGroupMember) (V.toList (p ^. #deadLetters))) [first, second, third] `shouldBe` [[9], [1], [0]]
            third ^. #nextCursor `shouldBe` Nothing
            forM_ [0, 1, 9, 7] $ \member -> do
                selected <- page store (query & #consumerGroupMember .~ Just member)
                positions selected `shouldBe` if member == 7 then [] else [1]
        it "preserves arbitrary and decode-failure JSON unchanged" $ \store -> do
            events <- seedEvents store 2
            let reasons = [object ["kind" .= ("other" :: T.Text), "detail" .= object ["code" .= (42 :: Int)]], object ["kind" .= ("decode_failure" :: T.Text), "detail" .= ("bad version" :: T.Text)]]
            forM_ (zip events reasons) $ \(event, reason) -> insertDeadLetterWith store "json" 0 reason "summary" 3 event
            result <- page store (defaultSubscriptionDeadLetterQuery (SubscriptionName "json"))
            map (\row -> row ^. #reason) (V.toList (result ^. #deadLetters)) `shouldBe` reverse reasons
            now <- getCurrentTime
            forM_ (V.toList (result ^. #deadLetters)) $ \row -> do
                row ^. #attemptCount `shouldBe` 3
                row ^. #createdAt `shouldSatisfy` (<= now)
        it "never invokes a configured event decode hook for dead-letter reads" $ \_ ->
            withTestStoreSettings (\settings -> (settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just (\_ -> fail "dead-letter read invoked decode hook")})) $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "hook-1") NoStream [makeEvent "E" (object [])]
                Right () <- Pool.use (store ^. #pool) (Session.script "INSERT INTO dead_letters(subscription_name,global_position,event_id,reason,reason_summary,attempt_count) SELECT 'hook',1,event_id,'{}','fixture',1 FROM events")
                result <- page store (defaultSubscriptionDeadLetterQuery (SubscriptionName "hook"))
                positions result `shouldBe` [1]

        it "keeps a cursor valid after its event and row are hard-deleted" $ \store -> do
            events <- seedEvents store 3
            mapM_ (insertDeadLetterForEvent store "delete") events
            let query = (defaultSubscriptionDeadLetterQuery (SubscriptionName "delete")){limit = validLimit 1}
            first <- page store query
            Right _ <- runStoreIO store $ hardDeleteStream (StreamName "dead-3")
            older <- page store query{after = first ^. #nextCursor, limit = validLimit 10}
            positions older `shouldBe` [2, 1]
        it "includes legal maxBound pairs on first pages" $ \store -> do
            [event] <- seedEvents store 1
            insertDeadLetterForEvent store "boundary" event
            Right () <- Pool.use (store ^. #pool) (Session.script "UPDATE dead_letters SET global_position=9223372036854775807, dead_letter_id=9223372036854775807 WHERE subscription_name='boundary'")
            let query = defaultSubscriptionDeadLetterQuery (SubscriptionName "boundary")
            forM_ [Nothing, Just 0] $ \member -> do
                result <- page store (query & #consumerGroupMember .~ member)
                positions result `shouldBe` [maxBound]
                older <- page store (query & #consumerGroupMember .~ member & #after .~ Just (SubscriptionDeadLetterCursor (GlobalPosition maxBound) maxBound))
                positions older `shouldBe` []
        it "reads a real worker-produced poison reason without changing its checkpoint" $ \store -> do
            events <- seedEvents store 3
            waitForPublisher store (GlobalPosition 3)
            handle <- subscribe store $ defaultSubscriptionConfig (SubscriptionName "worker") AllStreams $ \event -> pure $ case event ^. #globalPosition of
                GlobalPosition 2 -> DeadLetter (DeadLetterPoison "boom")
                GlobalPosition 3 -> Stop
                _ -> Continue
            waitWithTimeout 10_000_000 handle >>= \case
                Right (Right ()) -> pure ()
                other -> expectationFailure (show other)
            result <- page store (defaultSubscriptionDeadLetterQuery (SubscriptionName "worker"))
            case V.toList (result ^. #deadLetters) of
                [row] -> do
                    row ^. #eventId `shouldBe` (events !! 1) ^. #eventId
                    row ^. #reason `shouldBe` object ["kind" .= ("poison" :: T.Text), "detail" .= ("boom" :: T.Text)]
                    row ^. #reasonSummary `shouldBe` "poison: boom"
                _ -> expectationFailure (show result)
            Pool.use (store ^. #pool) (Session.statement ("worker", 0) SQL.getCheckpointMemberStmt) `shouldReturn` Right (Just 3)

validLimit :: Int32 -> SubscriptionDeadLetterLimit
validLimit = either (error . show) (\value -> value) . mkSubscriptionDeadLetterLimit
page :: KirokuStore -> SubscriptionDeadLetterQuery -> IO SubscriptionDeadLetterPage
page store query = runStoreIO store (subscriptionDeadLetters query) >>= either (fail . show) pure
positions :: SubscriptionDeadLetterPage -> [Int64]
positions result = map (\row -> let GlobalPosition p = row ^. #globalPosition in p) (V.toList (result ^. #deadLetters))
seedEvents :: KirokuStore -> Int -> IO [RecordedEvent]
seedEvents store count = do
    forM_ [1 .. count] $ \n -> void $ runStoreIO store $ appendToStream (StreamName ("dead-" <> T.pack (show n))) NoStream [makeEvent "E" (object [])]
    Right events <- runStoreIO store $ readAllForward (GlobalPosition 0) (fromIntegral count)
    pure (V.toList events)
