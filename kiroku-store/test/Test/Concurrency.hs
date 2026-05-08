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
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Kiroku.Store
import Test.Helpers (countEvents, makeEvent, withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "kiroku-store concurrency (deterministic)" $ do
    it "many AnyVersion writers to one stream preserve stream and global order" $
        withTestStore $ \store -> do
            let writerCount = 24
                stream = StreamName "stress-one-stream"
            results <-
                Async.forConcurrently [1 .. writerCount] $ \i -> do
                    runStoreIO store $
                        appendToStream
                            stream
                            AnyVersion
                            [makeEvent ("Stress" <> T.pack (show i)) (Aeson.object [])]
            mapM_ assertRightAppend results
            Right streamEvents <- runStoreIO store $ readStreamForward stream (StreamVersion 0) 1000
            V.length streamEvents `shouldBe` writerCount
            streamVersions streamEvents `shouldBe` [1 .. fromIntegral writerCount]
            Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 1000
            V.length allEvents `shouldBe` writerCount
            globalPositions allEvents `shouldBe` [1 .. fromIntegral writerCount]

    it "many AnyVersion writers to invoice-payment preserve stream and global order" $
        withTestStore $ \store -> do
            let writerCount = 32
                stream = StreamName "invoice-payment"
            results <-
                Async.forConcurrently [1 .. writerCount] $ \i -> do
                    runStoreIO store $
                        appendToStream
                            stream
                            AnyVersion
                            [makeEvent ("InvoicePayment" <> T.pack (show i)) (Aeson.object [])]
            mapM_ assertRightAppend results
            Right streamEvents <- runStoreIO store $ readStreamForward stream (StreamVersion 0) 1000
            V.length streamEvents `shouldBe` writerCount
            streamVersions streamEvents `shouldBe` [1 .. fromIntegral writerCount]
            Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 1000
            V.length allEvents `shouldBe` writerCount
            globalPositions allEvents `shouldBe` [1 .. fromIntegral writerCount]
            Set.fromList (eventIds streamEvents) `shouldBe` Set.fromList (eventIds allEvents)

    it "many batched writers to different streams preserve batch-local and global order" $
        withTestStore $ \store -> do
            let streamCount = 12
                batchSize = 10
                totalEvents = streamCount * batchSize
                mkStream i = StreamName ("stress-batch-" <> T.pack (show i))
                mkBatch i =
                    [ makeEvent ("Batch" <> T.pack (show i) <> "-" <> T.pack (show j)) (Aeson.object [])
                    | j <- [1 .. batchSize]
                    ]
            results <-
                Async.forConcurrently [1 .. streamCount] $ \i -> do
                    runStoreIO store $ appendToStream (mkStream i) NoStream (mkBatch i)
            mapM_ assertRightAppend results
            forM_ [1 .. streamCount] $ \i -> do
                Right streamEvents <- runStoreIO store $ readStreamForward (mkStream i) (StreamVersion 0) 1000
                streamVersions streamEvents `shouldBe` [1 .. fromIntegral batchSize]
            Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 1000
            V.length allEvents `shouldBe` totalEvents
            globalPositions allEvents `shouldBe` [1 .. fromIntegral totalEvents]

    it "large append batches return the final stream and global positions" $
        withTestStore $ \store -> do
            let stream = StreamName "stress-large-batches"
                mkBatch label n =
                    [ makeEvent (label <> "-" <> T.pack (show i)) (Aeson.object [])
                    | i <- [1 .. n]
                    ]
            Right r10 <- runStoreIO store $ appendToStream stream NoStream (mkBatch "Batch10" 10)
            (r10 ^. #streamVersion) `shouldBe` StreamVersion 10
            (r10 ^. #globalPosition) `shouldBe` GlobalPosition 10
            Right r100 <- runStoreIO store $ appendToStream stream AnyVersion (mkBatch "Batch100" 100)
            (r100 ^. #streamVersion) `shouldBe` StreamVersion 110
            (r100 ^. #globalPosition) `shouldBe` GlobalPosition 110
            Right streamEvents <- runStoreIO store $ readStreamForward stream (StreamVersion 0) 200
            streamVersions streamEvents `shouldBe` [1 .. 110]
            Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 200
            globalPositions allEvents `shouldBe` [1 .. 110]

    it "overlapping appendMultiStream stress preserves all-or-nothing ordering" $
        withTestStore $ \store -> do
            let streams = [StreamName "stress-multi-a", StreamName "stress-multi-b", StreamName "stress-multi-c"]
                rotations =
                    [ streams
                    , [StreamName "stress-multi-b", StreamName "stress-multi-c", StreamName "stress-multi-a"]
                    , [StreamName "stress-multi-c", StreamName "stress-multi-a", StreamName "stress-multi-b"]
                    ]
                opsFor i =
                    [ (sn, AnyVersion, [makeEvent ("Multi" <> T.pack (show i) <> "-" <> labelStream sn) (Aeson.object [])])
                    | sn <- rotations !! (i `mod` length rotations)
                    ]
            forM_ streams $ \sn -> do
                result <- runStoreIO store $ appendToStream sn NoStream [makeEvent "init" (Aeson.object [])]
                assertRightAppend result
            results <-
                Async.forConcurrently [1 .. 9] $ \i -> do
                    runStoreIO store $ appendMultiStream (opsFor i)
            mapM_ assertRightMulti results
            forM_ streams $ \sn -> do
                Right streamEvents <- runStoreIO store $ readStreamForward sn (StreamVersion 0) 100
                streamVersions streamEvents `shouldBe` [1 .. 10]
            Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
            V.length allEvents `shouldBe` 30
            globalPositions allEvents `shouldBe` [1 .. 30]

    it "duplicate event failure leaves touched streams and $all unchanged" $
        withTestStore $ \store -> do
            let duplicate =
                    EventId $
                        case UUID.fromString "01234567-89ab-7def-8012-34567890abce" of
                            Just u -> u
                            Nothing -> error "bad uuid"
                duplicateEvent =
                    EventData
                        { eventId = Just duplicate
                        , eventType = EventType "Duplicate"
                        , payload = Aeson.object []
                        , metadata = Nothing
                        , causationId = Nothing
                        , correlationId = Nothing
                        }
            Right _ <- runStoreIO store $ appendToStream (StreamName "rollback-seed") NoStream [duplicateEvent]
            Right _ <- runStoreIO store $ appendToStream (StreamName "rollback-a") NoStream [makeEvent "init-a" (Aeson.object [])]
            Right _ <- runStoreIO store $ appendToStream (StreamName "rollback-b") NoStream [makeEvent "init-b" (Aeson.object [])]
            beforeCount <- countEvents store
            Right beforeAll <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
            result <-
                runStoreIO store $
                    appendMultiStream
                        [ (StreamName "rollback-a", AnyVersion, [duplicateEvent])
                        , (StreamName "rollback-b", AnyVersion, [makeEvent "should-not-commit" (Aeson.object [])])
                        ]
            case result of
                Left (DuplicateEvent _) -> pure ()
                other -> expectationFailure ("duplicate event should abort the multi-stream transaction, got: " <> show other)
            countEvents store `shouldReturn` beforeCount
            Right afterAll <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
            globalPositions afterAll `shouldBe` globalPositions beforeAll
            Right streamA <- runStoreIO store $ readStreamForward (StreamName "rollback-a") (StreamVersion 0) 100
            Right streamB <- runStoreIO store $ readStreamForward (StreamName "rollback-b") (StreamVersion 0) 100
            streamVersions streamA `shouldBe` [1]
            streamVersions streamB `shouldBe` [1]

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

assertRightAppend :: Either StoreError AppendResult -> IO ()
assertRightAppend = \case
    Right _ -> pure ()
    Left err -> expectationFailure ("append should succeed, got: " <> show err)

assertRightMulti :: Either StoreError [AppendResult] -> IO ()
assertRightMulti = \case
    Right _ -> pure ()
    Left err -> expectationFailure ("appendMultiStream should succeed, got: " <> show err)

streamVersions :: V.Vector RecordedEvent -> [Int64]
streamVersions =
    map
        (\e -> case e ^. #streamVersion of StreamVersion n -> n)
        . V.toList

globalPositions :: V.Vector RecordedEvent -> [Int64]
globalPositions =
    map
        (\e -> case e ^. #globalPosition of GlobalPosition n -> n)
        . V.toList

eventIds :: V.Vector RecordedEvent -> [EventId]
eventIds =
    map (^. #eventId)
        . V.toList

labelStream :: StreamName -> Text
labelStream (StreamName name) = name
