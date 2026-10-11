module Test.SubscriptionDeadLettersMock (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store
import Test.Hspec

spec :: Spec
spec = describe "SubscriptionDeadLetters mock interpreter" $ it "dispatches the public wrapper once with the entire query and returns the interpreter page" $ do
    calls <- newIORef (0 :: Int)
    let query = (defaultSubscriptionDeadLetterQuery (SubscriptionName "mock")){consumerGroupMember = Just 9, after = Just (SubscriptionDeadLetterCursor (GlobalPosition 21) 7)}
        expected = SubscriptionDeadLetterPage V.empty (Just (SubscriptionDeadLetterCursor (GlobalPosition 10) 3))
        runner = interpret_ $ \case
            ListSubscriptionDeadLetters actual -> do
                liftIO $ actual `shouldBe` query
                liftIO $ modifyIORef' calls (+ 1)
                pure expected
            _ -> error "unexpected Store operation"
    runEff (runner (subscriptionDeadLetters query)) `shouldReturn` expected
    readIORef calls `shouldReturn` 1
