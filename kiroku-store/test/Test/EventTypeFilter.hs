{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Regression tests for EP-43 (MasterPlan 6, child plan 4) — per-subscription
event-type filtering in @kiroku-store@.

These pin the behavioral acceptance criteria from the ExecPlan:

  * __selective delivery__: a subscription with
    @'eventTypeFilter' = 'OnlyEventTypes' {A}@ over a mixed @A@\/@B@ stream
    delivers only the @A@ events to its handler;
  * __checkpoint advances past filtered events__: the persisted @last_seen@
    equals the global position of the /last event of any type/, including a
    trailing filtered-out event, so the subscription never re-scans skipped
    events after a restart;
  * __no stall__: a long run of non-matching events (1 @A@, 1000 @B@, 1 @A@)
    does not hang the subscription — both @A@s are delivered and the checkpoint
    reaches 1002;
  * __filter before dead-letter__: a handler that dead-letters /every/ event it
    sees, behind a filter that admits no events in the stream, is never invoked,
    writes no dead-letter rows, and still advances the checkpoint.

They also cover the opaque 'selector' escape hatch (a @RecordedEvent -> Bool@
predicate the type set cannot express, e.g. on payload\/metadata):

  * __selector no-stall__: a selector over a payload tag delivers only matching
    events and advances the checkpoint past a long run of rejected ones;
  * __AND composition__: 'selector' and 'eventTypeFilter' compose as a logical
    AND — an event is delivered only when it passes both.

All use an 'AllStreams' subscription (the FSM 'DeliverBatch' delivery path).
Events are appended and the publisher is awaited before subscribing, so delivery
happens during catch-up; the worker applies the filter in 'processEvents' before
the handler call.
-}
module Test.EventTypeFilter (spec) where

import Control.Concurrent (threadDelay)
import Control.Lens ((^.))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Test.Helpers (makeEvent, waitForPublisher, withTestStore)
import Test.Hspec

typeOf :: RecordedEvent -> Text
typeOf ev = case ev ^. #eventType of EventType t -> t

readCheckpoint :: KirokuStore -> Text -> IO (Maybe Int64)
readCheckpoint store subName = do
    result <- Pool.use (store ^. #pool) (Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt)
    case result of
        Left err -> error ("readCheckpoint failed: " <> show err)
        Right mPos -> pure mPos

readDeadLetters :: KirokuStore -> Text -> IO [SQL.DeadLetterRecord]
readDeadLetters store subName = do
    result <- Pool.use (store ^. #pool) (Session.statement (subName, 0 :: Int32) SQL.readDeadLettersStmt)
    case result of
        Left err -> error ("readDeadLetters failed: " <> show err)
        Right v -> pure (V.toList v)

-- Poll the checkpoint until it reaches @target@ (or ~10s elapse). Because the
-- worker saves the checkpoint at the batch tail only after every handler call in
-- the batch, a checkpoint at @target@ means all deliveries up to @target@ are
-- done, so the collected delivery list is stable once this returns 'True'.
waitForCheckpoint :: KirokuStore -> Text -> Int64 -> IO Bool
waitForCheckpoint store subName target = go (0 :: Int)
  where
    go n
        | n > 200 = pure False
        | otherwise = do
            mPos <- readCheckpoint store subName
            case mPos of
                Just p | p >= target -> pure True
                _ -> threadDelay 50_000 >> go (n + 1)

mkE :: Text -> EventData
mkE typ = makeEvent typ (Aeson.object [])

-- An event tagged @{ "keep": True\/False }@ in its payload — a property the
-- 'eventTypeFilter' type set cannot express, used to exercise the opaque
-- 'selector' escape hatch.
mkTagged :: Text -> Bool -> EventData
mkTagged typ keep = makeEvent typ (Aeson.object ["keep" .= keep])

-- The opaque selector: deliver only events whose payload says @keep = True@.
keepOnly :: RecordedEvent -> Bool
keepOnly ev = (ev ^. #payload) == Aeson.object ["keep" .= True]

posOf :: RecordedEvent -> Int64
posOf ev = case ev ^. #globalPosition of GlobalPosition p -> p

spec :: Spec
spec = describe "event-type filter" $ do
    it "delivers only matching types and advances the checkpoint past filtered events" $ do
        withTestStore $ \store -> do
            let subT = "etf-mixed" :: Text
                subName = SubscriptionName subT
            -- A, B, A, B, A on one stream -> global positions 1..5.
            Right _ <-
                runStoreIO store $
                    appendToStream
                        (StreamName "etf-mixed-stream")
                        NoStream
                        [mkE "A", mkE "B", mkE "A", mkE "B", mkE "A"]
            waitForPublisher store (GlobalPosition 5)

            deliveredRef <- newIORef ([] :: [Text])
            let handler' ev = do
                    modifyIORef' deliveredRef (<> [typeOf ev])
                    pure Continue
                cfg =
                    (defaultSubscriptionConfig subName AllStreams handler')
                        { eventTypeFilter = OnlyEventTypes (Set.fromList [EventType "A"])
                        }
            handle <- subscribe store cfg
            reached <- waitForCheckpoint store subT 5
            cancel handle

            reached `shouldBe` True
            delivered <- readIORef deliveredRef
            delivered `shouldBe` ["A", "A", "A"]
            readCheckpoint store subT `shouldReturn` Just 5

    it "advances the checkpoint past a trailing filtered-out event" $ do
        withTestStore $ \store -> do
            let subT = "etf-trailing" :: Text
                subName = SubscriptionName subT
            -- A then B: the last event (B at position 2) is filtered out.
            Right _ <-
                runStoreIO store $
                    appendToStream
                        (StreamName "etf-trailing-stream")
                        NoStream
                        [mkE "A", mkE "B"]
            waitForPublisher store (GlobalPosition 2)

            deliveredRef <- newIORef ([] :: [Text])
            let handler' ev = do
                    modifyIORef' deliveredRef (<> [typeOf ev])
                    pure Continue
                cfg =
                    (defaultSubscriptionConfig subName AllStreams handler')
                        { eventTypeFilter = OnlyEventTypes (Set.fromList [EventType "A"])
                        }
            handle <- subscribe store cfg
            reached <- waitForCheckpoint store subT 2
            cancel handle

            reached `shouldBe` True
            delivered <- readIORef deliveredRef
            delivered `shouldBe` ["A"]
            -- last_seen is 2 (the trailing B), proving the cursor advanced past
            -- a filtered-out event rather than stopping at the last delivered A.
            readCheckpoint store subT `shouldReturn` Just 2

    it "never stalls on a long run of non-matching events (1 A, 1000 B, 1 A)" $ do
        withTestStore $ \store -> do
            let subT = "etf-nostall" :: Text
                subName = SubscriptionName subT
                events = [mkE "A"] <> replicate 1000 (mkE "B") <> [mkE "A"]
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "etf-nostall-stream") NoStream events
            waitForPublisher store (GlobalPosition 1002)

            deliveredRef <- newIORef ([] :: [Text])
            let handler' ev = do
                    modifyIORef' deliveredRef (<> [typeOf ev])
                    pure Continue
                cfg =
                    (defaultSubscriptionConfig subName AllStreams handler')
                        { eventTypeFilter = OnlyEventTypes (Set.fromList [EventType "A"])
                        , batchSize = 2000
                        }
            handle <- subscribe store cfg
            reached <- waitForCheckpoint store subT 1002
            cancel handle

            reached `shouldBe` True
            delivered <- readIORef deliveredRef
            -- Exactly the two As; the 1000 Bs advanced the cursor without delivery.
            delivered `shouldBe` ["A", "A"]
            readCheckpoint store subT `shouldReturn` Just 1002

    it "does not dead-letter a filtered-out type even when the handler would" $ do
        withTestStore $ \store -> do
            let subT = "etf-no-dl" :: Text
                subName = SubscriptionName subT
            -- Only Bs; the filter admits only A, so the handler never runs.
            Right _ <-
                runStoreIO store $
                    appendToStream
                        (StreamName "etf-no-dl-stream")
                        NoStream
                        [mkE "B", mkE "B", mkE "B", mkE "B", mkE "B"]
            waitForPublisher store (GlobalPosition 5)

            deliveredRef <- newIORef ([] :: [Text])
            let handler' ev = do
                    -- The handler would dead-letter everything it sees — but a
                    -- filtered-out event must never reach it.
                    modifyIORef' deliveredRef (<> [typeOf ev])
                    pure (DeadLetter (DeadLetterPoison "should-never-fire"))
                cfg =
                    (defaultSubscriptionConfig subName AllStreams handler')
                        { eventTypeFilter = OnlyEventTypes (Set.fromList [EventType "A"])
                        }
            handle <- subscribe store cfg
            reached <- waitForCheckpoint store subT 5
            cancel handle

            reached `shouldBe` True
            delivered <- readIORef deliveredRef
            delivered `shouldBe` []
            -- No dead-letter rows were written for the filtered-out Bs, and the
            -- checkpoint still advanced past them.
            dls <- readDeadLetters store subT
            length dls `shouldBe` 0
            readCheckpoint store subT `shouldReturn` Just 5

    -- The opaque 'selector' escape hatch: a predicate over the whole
    -- 'RecordedEvent' (here, its payload) that the 'eventTypeFilter' type set
    -- cannot express. Same no-stall / checkpoint-advances guarantees apply.
    it "delivers only events matching an opaque selector and advances past the rest (no stall)" $ do
        withTestStore $ \store -> do
            let subT = "sel-nostall" :: Text
                subName = SubscriptionName subT
                -- All one type "A" (so eventTypeFilter cannot distinguish them);
                -- only the payload tag differs. keep, 1000 skips, keep.
                events =
                    [mkTagged "A" True]
                        <> replicate 1000 (mkTagged "A" False)
                        <> [mkTagged "A" True]
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "sel-nostall-stream") NoStream events
            waitForPublisher store (GlobalPosition 1002)

            deliveredRef <- newIORef ([] :: [Int64])
            let handler' ev = do
                    modifyIORef' deliveredRef (<> [posOf ev])
                    pure Continue
                cfg =
                    (defaultSubscriptionConfig subName AllStreams handler')
                        { selector = Just keepOnly
                        , batchSize = 2000
                        }
            handle <- subscribe store cfg
            reached <- waitForCheckpoint store subT 1002
            cancel handle

            reached `shouldBe` True
            delivered <- readIORef deliveredRef
            -- Only the two keep events (positions 1 and 1002); the 1000 skips
            -- advanced the cursor without delivery.
            delivered `shouldBe` [1, 1002]
            readCheckpoint store subT `shouldReturn` Just 1002

    it "composes the selector with eventTypeFilter as a logical AND" $ do
        withTestStore $ \store -> do
            let subT = "sel-and-type" :: Text
                subName = SubscriptionName subT
                -- A/keep, A/skip, B/keep, B/skip, A/keep -> positions 1..5.
                -- Only events that are type A AND keep survive: positions 1, 5.
                events =
                    [ mkTagged "A" True
                    , mkTagged "A" False
                    , mkTagged "B" True
                    , mkTagged "B" False
                    , mkTagged "A" True
                    ]
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "sel-and-type-stream") NoStream events
            waitForPublisher store (GlobalPosition 5)

            deliveredRef <- newIORef ([] :: [Int64])
            let handler' ev = do
                    modifyIORef' deliveredRef (<> [posOf ev])
                    pure Continue
                cfg =
                    (defaultSubscriptionConfig subName AllStreams handler')
                        { eventTypeFilter = OnlyEventTypes (Set.fromList [EventType "A"])
                        , selector = Just keepOnly
                        }
            handle <- subscribe store cfg
            reached <- waitForCheckpoint store subT 5
            cancel handle

            reached `shouldBe` True
            delivered <- readIORef deliveredRef
            -- B/keep (pos 3) is rejected by the type filter; A/skip (pos 2) by the
            -- selector. Only A-and-keep at 1 and 5 are delivered.
            delivered `shouldBe` [1, 5]
            readCheckpoint store subT `shouldReturn` Just 5
