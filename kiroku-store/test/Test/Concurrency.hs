{- | Deterministic concurrency tests for kiroku-store.

Each test spawns multiple threads that race on append paths the
single-threaded scenario suite cannot exercise. The tests target the
EP-6 M1 Concurrency Scenarios (F9–F11) and verify EP-1 F4 (the sorted
@SELECT … FOR UPDATE@ pre-pass that prevents multi-stream deadlocks)
under deliberate adversarial ordering.

Each test acquires a fresh ephemeral PostgreSQL via 'withTestStore'.
-}
module Test.Concurrency (spec) where

import Control.Concurrent.Async qualified as Async
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Set qualified as Set
import Data.Vector qualified as V
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "kiroku-store concurrency (deterministic)" $ do
    -- F9 — Two concurrent appends to different streams. Both calls
    -- must succeed, the global positions must be unique and contiguous,
    -- and the test must not deadlock.
    it "two concurrent appends to different streams both succeed (F9)" $
        withTestStore $ \store -> do
            (rA, rB) <-
                Async.concurrently
                    (runStoreIO store $ appendToStream (StreamName "f9-a") NoStream [makeEvent "A" (Aeson.object [])])
                    (runStoreIO store $ appendToStream (StreamName "f9-b") NoStream [makeEvent "B" (Aeson.object [])])
            case (rA, rB) of
                (Right resA, Right resB) -> do
                    let pA = case resA ^. #globalPosition of GlobalPosition n -> n
                        pB = case resB ^. #globalPosition of GlobalPosition n -> n
                    pA `shouldNotBe` pB
                    Set.fromList [pA, pB] `shouldBe` Set.fromList [1, 2]
                other -> expectationFailure ("F9: both should succeed, got: " <> show other)

    -- F10 — Two concurrent appends to the same stream with the same
    -- ExactVersion. Exactly one must succeed; the other must fail
    -- with WrongExpectedVersion. No deadlock. Stream is pre-created
    -- because ExactVersion 0 against a non-existent stream is itself
    -- an error in kiroku (streams start at version 1).
    it "two concurrent ExactVersion appends to same stream — one wins (F10)" $
        withTestStore $ \store -> do
            Right _ <- runStoreIO store $ appendToStream (StreamName "f10") NoStream [makeEvent "Init" (Aeson.object [])]
            (r1, r2) <-
                Async.concurrently
                    (runStoreIO store $ appendToStream (StreamName "f10") (ExactVersion (StreamVersion 1)) [makeEvent "X" (Aeson.object [])])
                    (runStoreIO store $ appendToStream (StreamName "f10") (ExactVersion (StreamVersion 1)) [makeEvent "Y" (Aeson.object [])])
            case (r1, r2) of
                (Right _, Left (WrongExpectedVersion _ _ _)) -> pure ()
                (Left (WrongExpectedVersion _ _ _), Right _) -> pure ()
                other -> expectationFailure ("F10: exactly one should win with the loser returning WrongExpectedVersion, got: " <> show other)
            -- Stream must have exactly init + winner = 2 events after the race.
            Right events <- runStoreIO store $ readStreamForward (StreamName "f10") (StreamVersion 0) 100
            V.length events `shouldBe` 2

    -- F11 — Two concurrent appendMultiStream calls touching the same
    -- streams in opposite order. EP-1 F4's sorted SELECT FOR UPDATE
    -- pre-pass ensures both transactions acquire row locks in the
    -- same canonical order, preventing the classic two-resource
    -- deadlock. Without the fix, this test would intermittently fail
    -- with PostgreSQL deadlock detection (40P01).
    it "two concurrent multi-stream appends in opposite order do not deadlock (F11)" $
        withTestStore $ \store -> do
            -- Pre-create both streams so the multi-stream calls take
            -- the existing-stream path (where pre-locking matters).
            Right _ <- runStoreIO store $ appendToStream (StreamName "f11-x") NoStream [makeEvent "init-x" (Aeson.object [])]
            Right _ <- runStoreIO store $ appendToStream (StreamName "f11-y") NoStream [makeEvent "init-y" (Aeson.object [])]
            let opsXY =
                    [ (StreamName "f11-x", AnyVersion, [makeEvent "Ax" (Aeson.object [])])
                    , (StreamName "f11-y", AnyVersion, [makeEvent "Ay" (Aeson.object [])])
                    ]
                opsYX =
                    [ (StreamName "f11-y", AnyVersion, [makeEvent "By" (Aeson.object [])])
                    , (StreamName "f11-x", AnyVersion, [makeEvent "Bx" (Aeson.object [])])
                    ]
            (rA, rB) <-
                Async.concurrently
                    (runStoreIO store $ appendMultiStream opsXY)
                    (runStoreIO store $ appendMultiStream opsYX)
            case (rA, rB) of
                (Right _, Right _) -> pure ()
                other -> expectationFailure ("F11: both calls must succeed without deadlock, got: " <> show other)
            -- Each stream contains its init event plus one event from
            -- each of the two concurrent multi-stream appends (3 each).
            Right xs <- runStoreIO store $ readStreamForward (StreamName "f11-x") (StreamVersion 0) 100
            Right ys <- runStoreIO store $ readStreamForward (StreamName "f11-y") (StreamVersion 0) 100
            V.length xs `shouldBe` 3
            V.length ys `shouldBe` 3
            -- \$all has 6 events total (2 inits + 4 from concurrent calls).
            Right allEvts <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
            V.length allEvts `shouldBe` 6
            let positions =
                    map
                        (\e -> case e ^. #globalPosition of GlobalPosition n -> n)
                        (V.toList allEvts)
            sort positions `shouldBe` [1, 2, 3, 4, 5, 6]
