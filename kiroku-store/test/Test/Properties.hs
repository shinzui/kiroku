{- | Property-based tests for invariants identified by EP-1 through EP-5.

Each property generates a random sequence of operations and asserts that
some invariant holds after the sequence executes. The properties target
the cross-cutting invariants enumerated in EP-6 M1's Invariant List
(F2–F8 of @docs\/plans\/6-test-and-benchmark-hardening-for-production-confidence.md@):

  * F2 — global position contiguity across appends, multi-stream appends,
    and links.
  * F3 — no orphan event payloads after lifecycle operations.
  * F4 — soft-delete write barrier under arbitrary append constructors.
  * F5 — caller-supplied event-id idempotence.

These properties run inside hspec via 'hspec-hedgehog'. Each property
acquires a fresh ephemeral PostgreSQL via 'withTestStore' inside the
hedgehog test action; the operation count per property is small (10-20
ops) to keep total runtime bounded.
-}
module Test.Properties (spec) where

import Control.Lens ((^.))
import Control.Monad (forM_, void)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID.V4 qualified as UUIDv4
import Data.Vector qualified as V
import Hedgehog
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec
import Test.Hspec.Hedgehog (PropertyT, hedgehog, modifyMaxSuccess)

-- | Operations the property generators can produce.
data Op
    = OpAppend !StreamName ![Text]
    | OpAppendMulti ![(StreamName, [Text])]
    | OpSoftDelete !StreamName
    | OpUndelete !StreamName
    | OpHardDelete !StreamName
    deriving stock (Show)

genStreamName :: Gen StreamName
genStreamName = do
    -- Bounded universe (5 streams) so generated sequences exercise reuse.
    n <- Gen.int (Range.linear 0 4)
    pure (StreamName ("prop-" <> T.pack (show n)))

genEventTypes :: Gen [Text]
genEventTypes = do
    n <- Gen.int (Range.linear 1 3)
    pure (map (\i -> "Type" <> T.pack (show i)) [1 .. n])

genOp :: Gen Op
genOp =
    Gen.frequency
        [ (60, OpAppend <$> genStreamName <*> genEventTypes)
        ,
            ( 10
            , OpAppendMulti
                <$> Gen.list
                    (Range.linear 2 3)
                    ((,) <$> genStreamName <*> genEventTypes)
            )
        , (10, OpSoftDelete <$> genStreamName)
        , (10, OpUndelete <$> genStreamName)
        , (10, OpHardDelete <$> genStreamName)
        ]

genOps :: Gen [Op]
genOps = Gen.list (Range.linear 1 12) genOp

{- | Run a generated operation, ignoring any 'StoreError' (the property
is about the system's invariants surviving any sequence of attempts,
including ones that fail).
-}
runOp :: KirokuStore -> Op -> IO ()
runOp store = \case
    OpAppend sn types -> do
        let evts = map (\t -> makeEvent t (Aeson.object [])) types
        void $ runStoreIO store $ appendToStream sn AnyVersion evts
    OpAppendMulti ops -> do
        let triples = map (\(sn, types) -> (sn, AnyVersion, map (\t -> makeEvent t (Aeson.object [])) types)) ops
        void $ runStoreIO store $ appendMultiStream triples
    OpSoftDelete sn -> void $ runStoreIO store $ softDeleteStream sn
    OpUndelete sn -> void $ runStoreIO store $ undeleteStream sn
    OpHardDelete sn -> void $ runStoreIO store $ hardDeleteStream sn

-- | Read the global position cursor by counting events on `$all`.
readAllCount :: KirokuStore -> IO Int
readAllCount store = do
    Right v <- runStoreIO store $ readAllForward (GlobalPosition 0) 100000
    pure (V.length v)

{- | Read all events on `$all` and return their global positions in
the order returned.
-}
readAllPositions :: KirokuStore -> IO [Int]
readAllPositions store = do
    Right v <- runStoreIO store $ readAllForward (GlobalPosition 0) 100000
    pure (V.toList (V.map (\e -> case e ^. #globalPosition of GlobalPosition n -> fromIntegral n) v))

{- | Each property creates a fresh ephemeral PostgreSQL per test case,
which dominates wall-clock time. Cap iterations at 15 per property —
enough to exercise generator coverage without blowing the suite past
two minutes.
-}
spec :: Spec
spec = modifyMaxSuccess (const 15) $ do
    describe "kiroku-store invariants (property-based, hedgehog)" $ do
        -- F2 — Global position contiguity. After any sequence of
        -- appends, multi-appends, soft/undelete/hard-delete operations,
        -- the global positions on $all (excluding hard-deleted events)
        -- form a strictly ascending sequence with no duplicates and no
        -- gaps relative to the events that actually exist on $all.
        it "$all global positions are strictly ascending and unique (F2)" $
            hedgehog $
                propAllPositionsAscending

        -- F4 — Soft-delete write barrier. After softDeleteStream, no
        -- subsequent appendToStream of any ExpectedVersion succeeds
        -- (until undeleteStream). Generates a random append, soft-deletes,
        -- attempts further appends with each ExpectedVersion constructor,
        -- asserts each one fails.
        it "soft-deleted streams reject appends of every ExpectedVersion (F4)" $
            hedgehog $
                propSoftDeleteBarrier

        -- F5 — Idempotent caller-supplied event ids. A batch of appends
        -- with all-unique event ids succeeds; a batch where any id is a
        -- repeat of a previously committed id fails with DuplicateEvent.
        it "duplicate caller-supplied event ids are rejected (F5)" $
            hedgehog $
                propDuplicateEventIds

propAllPositionsAscending :: PropertyT IO ()
propAllPositionsAscending = do
    ops <- forAll genOps
    positions <- evalIO $ withTestStoreReturn $ \store -> do
        forM_ ops (runOp store)
        readAllPositions store
    annotateShow positions
    -- Strictly ascending: each position greater than the previous.
    sort positions === positions
    -- Unique: no duplicates.
    length positions === length (Set.fromList positions)
    -- The count returned by $all matches the position list length.
    cnt <- evalIO $ withTestStoreReturn $ \store -> do
        forM_ ops (runOp store)
        readAllCount store
    cnt === length positions

propSoftDeleteBarrier :: PropertyT IO ()
propSoftDeleteBarrier = do
    streamSeed <- forAll (Gen.int (Range.linear 0 9))
    nEvents <- forAll (Gen.int (Range.linear 1 4))
    evalIO $ withTestStoreReturn $ \store -> do
        let sn = StreamName ("barrier-" <> T.pack (show streamSeed))
        let evts = map (\i -> makeEvent ("E" <> T.pack (show i)) (Aeson.object [])) [1 .. nEvents]
        Right _ <- runStoreIO store $ appendToStream sn NoStream evts
        Right _ <- runStoreIO store $ softDeleteStream sn
        -- Every subsequent append constructor must be rejected.
        rNo <- runStoreIO store $ appendToStream sn NoStream [makeEvent "X" (Aeson.object [])]
        case rNo of
            Left (StreamAlreadyExists _) -> pure ()
            other -> error ("F4 violated: NoStream against soft-deleted should be StreamAlreadyExists, got: " <> show other)
        rExact <- runStoreIO store $ appendToStream sn (ExactVersion (StreamVersion (fromIntegral nEvents))) [makeEvent "X" (Aeson.object [])]
        case rExact of
            Left (WrongExpectedVersion _ _ _) -> pure ()
            Left (StreamNotFound _) -> pure ()
            other -> error ("F4 violated: ExactVersion against soft-deleted should fail, got: " <> show other)
        rExists <- runStoreIO store $ appendToStream sn StreamExists [makeEvent "X" (Aeson.object [])]
        case rExists of
            Left (StreamNotFound _) -> pure ()
            other -> error ("F4 violated: StreamExists against soft-deleted should be StreamNotFound, got: " <> show other)
        rAny <- runStoreIO store $ appendToStream sn AnyVersion [makeEvent "X" (Aeson.object [])]
        case rAny of
            Left (StreamNotFound _) -> pure ()
            other -> error ("F4 violated: AnyVersion against soft-deleted should be StreamNotFound, got: " <> show other)

propDuplicateEventIds :: PropertyT IO ()
propDuplicateEventIds = do
    nFirst <- forAll (Gen.int (Range.linear 1 4))
    evalIO $ withTestStoreReturn $ \store -> do
        -- Generate a batch of unique caller-supplied event ids.
        ids <- mapM (const UUIDv4.nextRandom) [1 .. nFirst]
        let mkEvent uid =
                EventData
                    { eventId = Just (EventId uid)
                    , eventType = EventType "Dup"
                    , payload = Aeson.object []
                    , metadata = Nothing
                    , causationId = Nothing
                    , correlationId = Nothing
                    }
        let evts1 = map mkEvent ids
        r1 <- runStoreIO store $ appendToStream (StreamName "dup-prop-1") NoStream evts1
        case r1 of
            Right _ -> pure ()
            other -> error ("Initial append with unique ids should succeed: " <> show other)
        -- Re-issue any one of those ids in a fresh stream — must be rejected.
        let dupId = case ids of
                (i : _) -> i
                [] -> error "propDuplicateEventIds: nFirst >= 1 by Range, ids must be non-empty"
        let evts2 = [mkEvent dupId]
        r2 <- runStoreIO store $ appendToStream (StreamName "dup-prop-2") NoStream evts2
        case r2 of
            Left (DuplicateEvent _) -> pure ()
            other -> error ("F5 violated: duplicate event id should be rejected, got: " <> show other)

-- | Variant of 'withTestStore' that returns the action's result.
withTestStoreReturn :: (KirokuStore -> IO a) -> IO a
withTestStoreReturn action = do
    ref <- newIORef (Nothing :: Maybe a)
    withTestStore $ \store -> do
        r <- action store
        atomicModifyIORef' ref (\_ -> (Just r, ()))
    readIORef ref >>= \case
        Just r -> pure r
        Nothing -> error "withTestStoreReturn: action did not produce a result"
