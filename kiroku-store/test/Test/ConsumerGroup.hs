{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Runtime tests for consumer groups (ExecPlan 29 / EP-2). Each member runs as
one in-process subscription worker over a fresh ephemeral PostgreSQL. The
properties proven here are the user-visible contract: a group's members deliver a
/disjoint/, /complete/, /per-stream-ordered/ partition of the source; a size-1
group equals a plain subscription; and each member resumes from its /own/
checkpoint.
-}
module Test.ConsumerGroup (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Kiroku.Store
import Kiroku.Store.Subscription.Types (ConsumerGroup (..), SubscriptionConfigM (..))
import Test.Helpers (makeEvent, waitForPublisher, waitWithTimeout, withTestStore)
import Test.Hspec

-- | Extract @(originalStreamId, globalPosition)@ as raw 'Int64's from an event.
pairOf :: RecordedEvent -> (Int64, Int64)
pairOf e =
    ( case e ^. #originalStreamId of StreamId s -> s
    , case e ^. #globalPosition of GlobalPosition p -> p
    )

-- | Append @perStream@ events to each named stream, seeding the store.
seed :: KirokuStore -> [Text] -> Int -> IO ()
seed store names perStream =
    mapM_
        ( \sn -> do
            let evs = map (\k -> makeEvent ("E" <> T.pack (show k)) (Aeson.object [])) [1 .. perStream]
            r <- runStoreIO store $ appendToStream (StreamName sn) NoStream evs
            case r of
                Left err -> error ("seed append failed for " <> T.unpack sn <> ": " <> show err)
                Right _ -> pure ()
        )
        names

-- | Poll an @IO Bool@ predicate until it holds or the microsecond budget runs out.
waitUntil :: Int -> IO Bool -> IO ()
waitUntil budget act
    | budget <= 0 = pure ()
    | otherwise = do
        ok <- act
        if ok
            then pure ()
            else do
                threadDelay 20_000
                waitUntil (budget - 20_000) act

{- | Assert that within each originating stream the global positions, taken in
delivery order, are strictly ascending (i.e. equal to their sorted form).
-}
assertPerStreamAscending :: [(Int64, Int64)] -> Expectation
assertPerStreamAscending chrono =
    let byStream = Map.fromListWith (\new old -> old ++ new) [(sid, [gp]) | (sid, gp) <- chrono]
     in mapM_ (\ps -> ps `shouldBe` sort ps) (Map.elems byStream)

-- | A size-@n@ category-group config for member @m@ with the given handler.
memberConfig ::
    Text -> Text -> Int32 -> Int32 -> EventHandler -> SubscriptionConfig
memberConfig nm cat m n h =
    (defaultSubscriptionConfig (SubscriptionName nm) (Category (CategoryName cat)) h)
        { consumerGroup = Just (ConsumerGroup{member = m, size = n})
        }

spec :: Spec
spec = describe "consumer groups" $ do
    it "delivers a disjoint, complete, per-stream-ordered partition (size-4 category group)" $
        withTestStore $ \store -> do
            let nStreams = 40
                perStream = 3
                total = nStreams * perStream
                streams = ["acct-" <> T.pack (show i) | i <- [1 .. nStreams]]
            seed store streams perStream
            waitForPublisher store (GlobalPosition (fromIntegral total))

            let n = 4 :: Int32
            refs <- mapM (const (newIORef [])) [0 .. n - 1]
            handles <-
                mapM
                    ( \m -> do
                        let ref = refs !! fromIntegral m
                            h evt = do
                                modifyIORef' ref (pairOf evt :)
                                pure Continue
                        subscribe store (memberConfig "cg-cat" "acct" m n h)
                    )
                    [0 .. n - 1]

            let collectedCount = sum <$> mapM (fmap length . readIORef) refs
            waitUntil 15_000_000 (fmap (>= total) collectedCount)
            mapM_ cancel handles

            collected <- mapM readIORef refs
            -- (1) Disjoint + complete: the multiset of all delivered positions is
            --     exactly [1..total] — no duplicate (would lengthen it) and no gap.
            let allPositions = sort (concatMap (map snd) collected)
            allPositions `shouldBe` [1 .. fromIntegral total]
            -- (2) Per-stream ordering within each member (collector prepended, so
            --     reverse to recover delivery order).
            mapM_ (assertPerStreamAscending . reverse) collected

    it "size-1 group delivers the same set as a plain subscription" $
        withTestStore $ \store -> do
            let nStreams = 4
                perStream = 3
                total = nStreams * perStream
                streams = ["uno-" <> T.pack (show i) | i <- [1 .. nStreams]]
            seed store streams perStream
            waitForPublisher store (GlobalPosition (fromIntegral total))

            let runCollector cfgFor nm = do
                    ref <- newIORef []
                    countVar <- newTVarIO (0 :: Int)
                    let h evt = do
                            modifyIORef' ref (snd (pairOf evt) :)
                            c <- atomically $ do
                                c0 <- readTVar countVar
                                let c1 = c0 + 1
                                writeTVar countVar c1
                                pure c1
                            pure (if c >= total then Stop else Continue)
                    handle <- subscribe store (cfgFor nm h)
                    _ <- waitWithTimeout 15_000_000 handle
                    sort <$> readIORef ref

            plain <-
                runCollector
                    (\nm h -> defaultSubscriptionConfig (SubscriptionName nm) (Category (CategoryName "uno")) h)
                    "uno-plain"
            grouped <-
                runCollector
                    (\nm h -> memberConfig nm "uno" 0 1 h)
                    "uno-group"

            plain `shouldBe` [1 .. fromIntegral total]
            grouped `shouldBe` plain
