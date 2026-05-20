{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Runnable demonstration of consumer groups (MasterPlan 4 / EP-4).

This program starts its own ephemeral PostgreSQL (no external database needed),
appends 120 events across 40 streams in one category, then runs a size-4
consumer group. Each of the four members collects the global position of every
event it receives into its own 'IORef'. After the group has processed all 120
events, the program prints each member's count and verifies the two key
guarantees:

  * /complete/ — the four members' counts sum to 120.
  * /disjoint/ — the union of all positions is exactly @[1 .. 120]@, with no
    event delivered to two members and none dropped.

Run it from the repository root:

@cabal run kiroku-store:kiroku-consumer-group-example@

The per-member counts vary run to run (they depend on which streams hash to
which member via PostgreSQL's @hashtextextended@), but @complete: OK@ and
@disjoint: OK@ are deterministic. See @docs/user/consumer-groups.md@ for the
full explanation of the guarantees demonstrated here.
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, check)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.List (sort)
import Data.Text qualified as T
import EphemeralPg qualified as Pg
import Kiroku.Store
import Kiroku.Store.Subscription.EventPublisher (publisherPosition)
import Kiroku.Store.Subscription.Types (ConsumerGroup (..))

-- | Block until the publisher has ingested at least 'target' events.
waitForPublisher :: KirokuStore -> GlobalPosition -> IO ()
waitForPublisher store (GlobalPosition target) =
    atomically do
        GlobalPosition p <- publisherPosition (store ^. #publisher)
        check (p >= target)

-- | Poll 'act' every 20 ms until it returns 'True' or 'budget' microseconds elapse.
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

main :: IO ()
main = do
    result <- Pg.withCached \db -> do
        let connStr = Pg.connectionString db
        withStore (defaultConnectionSettings connStr) \store -> do
            -- 1. Append 120 events across 40 streams in category "example".
            --    A stream's category is its name up to the first '-', so
            --    "example-0" .. "example-39" all live in category "example".
            let streamNames = ["example-" <> T.pack (show i) | i <- [0 .. 39 :: Int]]
            for_ streamNames \sn -> do
                let evs =
                        [ EventData
                            { eventId = Nothing
                            , eventType = EventType "ExampleEvent"
                            , payload = Aeson.object []
                            , metadata = Nothing
                            , causationId = Nothing
                            , correlationId = Nothing
                            }
                        | _ <- [1 .. 3 :: Int]
                        ]
                r <- runStoreIO store (appendToStream (StreamName sn) AnyVersion evs)
                case r of
                    Left err -> error ("append failed for " <> T.unpack sn <> ": " <> show err)
                    Right _ -> pure ()

            -- 2. Wait for the publisher to ingest all 120 events.
            waitForPublisher store (GlobalPosition 120)
            putStrLn "Appended 120 events across 40 streams. Starting 4-member consumer group..."

            -- 3. Start one collector per member. Each member records the global
            --    position of every event it receives into its own IORef.
            let groupSize = 4 :: Int32
            refs <- mapM (const (newIORef ([] :: [GlobalPosition]))) [0 .. groupSize - 1]
            handles <-
                mapM
                    ( \m -> do
                        let ref = refs !! fromIntegral m
                            h evt = do
                                modifyIORef' ref (evt ^. #globalPosition :)
                                pure Continue
                            cfg =
                                ( defaultSubscriptionConfig
                                    (SubscriptionName "example-group")
                                    (Category (CategoryName "example"))
                                    h
                                )
                                    { consumerGroup = Just (ConsumerGroup{member = m, size = groupSize})
                                    }
                        subscribe store cfg
                    )
                    [0 .. groupSize - 1]

            -- 4. Wait until all 120 events are collected, then stop every member.
            let collectedCount = sum <$> mapM (fmap length . readIORef) refs
            waitUntil 30_000_000 (fmap (>= 120) collectedCount)
            for_ handles cancel

            -- 5. Compute and print the summary.
            collected <- mapM readIORef refs
            let memberCounts = map length collected
                totalCollected = sum memberCounts
                allPositions = sort (concat collected)
                expectedPositions = map GlobalPosition [1 .. 120]
                isComplete = totalCollected == 120
                isDisjoint = allPositions == expectedPositions

            putStrLn ""
            putStrLn "=== Consumer Group Partition Summary ==="
            for_ (zip [0 :: Int ..] memberCounts) \(m, cnt) ->
                putStrLn ("  member " <> show m <> ": " <> show cnt <> " events")
            putStrLn ("  total : " <> show totalCollected)
            putStrLn ""
            putStrLn ("complete: " <> if isComplete then "OK" else "FAIL (expected 120)")
            putStrLn ("disjoint: " <> if isDisjoint then "OK" else "FAIL (duplicate or missing positions)")
            putStrLn ""
            let sample = take 5 (reverse (collected !! 0))
            putStrLn ("member 0 first 5 positions (delivery order): " <> show sample)

    case result of
        Left err -> error ("EphemeralPg failed: " <> show err)
        Right () -> pure ()
