{-# LANGUAGE OverloadedStrings #-}

{- | SQL-level tests for consumer-group partition routing and per-member
checkpoints (ExecPlan 28 / EP-1). These exercise the new prepared statements in
"Kiroku.Store.SQL" directly through the connection pool, with no subscription
runtime, on a fresh ephemeral PostgreSQL per test.

Terms: a /consumer group/ of /size/ N has members 0..N-1; each source stream is
assigned to exactly one member by 'Kiroku.Store.SQL'-encoded hash routing. The
properties proven here — disjointness, completeness, per-stream affinity,
determinism, and size-1 equivalence — are the contract EP-2's runtime depends on.
-}
module Test.ConsumerGroupSql (spec) where

import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

-- | A generous limit that returns every seeded event in one read.
bigLimit :: Int32
bigLimit = 100000

-- | Run a statement against the store's pool, failing the test on a usage error.
runStmt :: KirokuStore -> Session.Session a -> IO a
runStmt store session = do
    result <- Pool.use (store ^. #pool) session
    case result of
        Left err -> error ("ConsumerGroupSql statement failed: " <> show err)
        Right a -> pure a

{- | Append one event to each of the named streams, seeding the store. Each
stream gets a single event; per-stream affinity is what we test, so one event
per stream is enough, but the helper appends 'n' events to vary versions.
-}
seedStreams :: KirokuStore -> [Text] -> Int -> IO ()
seedStreams store names n =
    mapM_
        ( \name -> do
            let events = map (\i -> makeEvent ("E" <> T.pack (show i)) (Aeson.object [])) [1 .. n]
            r <- runStoreIO store $ appendToStream (StreamName name) NoStream events
            case r of
                Left err -> error ("seed append failed for " <> T.unpack name <> ": " <> show err)
                Right _ -> pure ()
        )
        names

-- | Collect the event ids from a read result, in order.
eventIds :: Vector RecordedEvent -> [UUID]
eventIds = map (\e -> case e ^. #eventId of EventId u -> u) . V.toList

-- | Collect (originalStreamId, globalPosition) pairs from a read result.
streamPositions :: Vector RecordedEvent -> [(Int64, Int64)]
streamPositions =
    map
        ( \e ->
            ( case e ^. #originalStreamId of StreamId s -> s
            , case e ^. #globalPosition of GlobalPosition p -> p
            )
        )
        . V.toList

{- | Direct call to the partition rule for one stream id and size, returning the
member index PostgreSQL computes. Mirrors IP-1 exactly so the test pins the
formula, not just its consequences.
-}
runMemberOf :: KirokuStore -> Int64 -> Int32 -> IO Int32
runMemberOf store streamId size = runStmt store (Session.statement (streamId, size) stmt)
  where
    stmt :: Statement (Int64, Int32) Int32
    stmt =
        preparable
            "SELECT (((hashtextextended($1::text, 0) % $2) + $2) % $2)::int4"
            ( (fst >$< E.param (E.nonNullable E.int8))
                <> (snd >$< E.param (E.nonNullable E.int4))
            )
            (D.singleRow (D.column (D.nonNullable D.int4)))

-- | All distinct (originalStreamId) values present in the unpartitioned read.
distinctStreamIds :: Vector RecordedEvent -> [Int64]
distinctStreamIds = Set.toList . Set.fromList . map fst . streamPositions

spec :: Spec
spec = do
    describe "ConsumerGroupSql" $ do
        categorySpec
        checkpointSpec
        allSpec
        memberOfSpec

-- ---------------------------------------------------------------------------
-- M1: category partitioning
-- ---------------------------------------------------------------------------

categorySpec :: Spec
categorySpec = around withTestStore $ do
    describe "category consumer-group partitioning (size 4)" $ do
        let cat = "acct"
            names = map (\i -> "acct-" <> T.pack (show i)) [1 .. 50 :: Int]
            size = 4 :: Int32

        let readMember store m =
                runStmt store $
                    Session.statement (0 :: Int64, cat, m, size, bigLimit) SQL.readCategoryForwardConsumerGroupStmt
            readFull store =
                runStmt store $
                    Session.statement (0 :: Int64, cat, bigLimit) SQL.readCategoryForwardStmt

        it "splits a category into 4 pairwise-disjoint member slices" $ \store -> do
            seedStreams store names 2
            slices <- mapM (readMember store) [0 .. size - 1]
            let idSets = map (Set.fromList . eventIds) slices
            -- pairwise disjoint: union of sizes equals size of union
            let totalIds = sum (map Set.size idSets)
                unionIds = Set.size (Set.unions idSets)
            totalIds `shouldBe` unionIds

        it "union of all member slices equals the unpartitioned category read" $ \store -> do
            seedStreams store names 2
            slices <- mapM (readMember store) [0 .. size - 1]
            full <- readFull store
            let unionIds = Set.unions (map (Set.fromList . eventIds) slices)
                fullIds = Set.fromList (eventIds full)
            unionIds `shouldBe` fullIds

        it "every stream's events go to exactly one member, in ascending global position" $ \store -> do
            seedStreams store names 3
            slices <- mapM (readMember store) [0 .. size - 1]
            -- For each member slice, every stream present must have all its events
            -- in ascending global position, and no stream may appear in two slices.
            let perMemberStreams = map (Set.fromList . map fst . streamPositions) slices
            -- per-stream affinity: stream sets are pairwise disjoint
            let totalStreams = sum (map Set.size perMemberStreams)
                unionStreams = Set.size (Set.unions perMemberStreams)
            totalStreams `shouldBe` unionStreams
            -- ascending global position within each slice
            mapM_
                ( \slice -> do
                    let ps = map snd (streamPositions slice)
                    ps `shouldBe` sort ps
                )
                slices

        it "member assignment is deterministic across repeated reads" $ \store -> do
            seedStreams store names 1
            firstReads <- mapM (\m -> eventIds <$> readMember store m) [0 .. size - 1]
            secondReads <- mapM (\m -> eventIds <$> readMember store m) [0 .. size - 1]
            firstReads `shouldBe` secondReads

        it "size 1 is equivalent to an unpartitioned category read" $ \store -> do
            seedStreams store names 2
            one <-
                runStmt store $
                    Session.statement (0 :: Int64, cat, 0 :: Int32, 1 :: Int32, bigLimit) SQL.readCategoryForwardConsumerGroupStmt
            full <- readFull store
            eventIds one `shouldBe` eventIds full

-- ---------------------------------------------------------------------------
-- M2: per-member checkpoints
-- ---------------------------------------------------------------------------

checkpointSpec :: Spec
checkpointSpec = around withTestStore $ do
    describe "per-member checkpoints" $ do
        let subName = "proj-acct" :: Text

        it "stores and reads independent checkpoints per member" $ \store -> do
            runStmt store $ Session.statement (subName, 0 :: Int32, 7 :: Int64) SQL.saveCheckpointMemberStmt
            runStmt store $ Session.statement (subName, 1 :: Int32, 13 :: Int64) SQL.saveCheckpointMemberStmt
            m0 <- runStmt store $ Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt
            m1 <- runStmt store $ Session.statement (subName, 1 :: Int32) SQL.getCheckpointMemberStmt
            m0 `shouldBe` Just 7
            m1 `shouldBe` Just 13

        it "never moves a member checkpoint backward (GREATEST monotonicity)" $ \store -> do
            runStmt store $ Session.statement (subName, 0 :: Int32, 20 :: Int64) SQL.saveCheckpointMemberStmt
            runStmt store $ Session.statement (subName, 0 :: Int32, 5 :: Int64) SQL.saveCheckpointMemberStmt
            m0 <- runStmt store $ Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt
            m0 `shouldBe` Just 20

        it "missing member checkpoint reads as Nothing" $ \store -> do
            m9 <- runStmt store $ Session.statement (subName, 9 :: Int32) SQL.getCheckpointMemberStmt
            m9 `shouldBe` Nothing

        it "the existing name-keyed checkpoint statements still round-trip (as member 0)" $ \store -> do
            runStmt store $ Session.statement (subName, 42 :: Int64) SQL.saveCheckpointStmt
            -- name-keyed read returns the same row (member 0)
            byName <- runStmt store $ Session.statement subName SQL.getCheckpointStmt
            byMember0 <- runStmt store $ Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt
            byName `shouldBe` Just 42
            byMember0 `shouldBe` Just 42

-- ---------------------------------------------------------------------------
-- M3: $all partitioning
-- ---------------------------------------------------------------------------

allSpec :: Spec
allSpec = around withTestStore $ do
    describe "$all consumer-group partitioning (size 4)" $ do
        -- \$all spans several categories; partitioning is by originating stream.
        let names =
                concatMap
                    (\c -> map (\i -> c <> "-" <> T.pack (show i)) [1 .. 20 :: Int])
                    ["acct", "user", "order"]
            size = 4 :: Int32

        let readMember store m =
                runStmt store $
                    Session.statement (0 :: Int64, m, size, bigLimit) SQL.readAllForwardConsumerGroupStmt
            readFull store =
                runStmt store $
                    Session.statement (0 :: Int64, bigLimit) SQL.readAllForwardStmt

        it "splits $all into 4 pairwise-disjoint member slices" $ \store -> do
            seedStreams store names 2
            slices <- mapM (readMember store) [0 .. size - 1]
            let idSets = map (Set.fromList . eventIds) slices
                totalIds = sum (map Set.size idSets)
                unionIds = Set.size (Set.unions idSets)
            totalIds `shouldBe` unionIds

        it "union of all member slices equals the unpartitioned $all read" $ \store -> do
            seedStreams store names 2
            slices <- mapM (readMember store) [0 .. size - 1]
            full <- readFull store
            let unionIds = Set.unions (map (Set.fromList . eventIds) slices)
                fullIds = Set.fromList (eventIds full)
            unionIds `shouldBe` fullIds

        it "every stream's events go to exactly one member, in ascending global position" $ \store -> do
            seedStreams store names 3
            slices <- mapM (readMember store) [0 .. size - 1]
            let perMemberStreams = map (Set.fromList . map fst . streamPositions) slices
                totalStreams = sum (map Set.size perMemberStreams)
                unionStreams = Set.size (Set.unions perMemberStreams)
            totalStreams `shouldBe` unionStreams
            mapM_
                ( \slice -> do
                    let ps = map snd (streamPositions slice)
                    ps `shouldBe` sort ps
                )
                slices

        it "size 1 is equivalent to an unpartitioned $all read" $ \store -> do
            seedStreams store names 2
            one <-
                runStmt store $
                    Session.statement (0 :: Int64, 0 :: Int32, 1 :: Int32, bigLimit) SQL.readAllForwardConsumerGroupStmt
            full <- readFull store
            eventIds one `shouldBe` eventIds full

-- ---------------------------------------------------------------------------
-- The partition rule, pinned directly.
-- ---------------------------------------------------------------------------

memberOfSpec :: Spec
memberOfSpec = around withTestStore $ do
    describe "member_of assignment rule" $ do
        it "returns a member index in [0, size) for every stream" $ \store -> do
            let names = map (\i -> "rule-" <> T.pack (show i)) [1 .. 30 :: Int]
            seedStreams store names 1
            full <- runStmt store $ Session.statement (0 :: Int64, bigLimit) SQL.readAllForwardStmt
            let sids = distinctStreamIds full
            mapM_
                ( \sid -> do
                    m <- runMemberOf store sid 4
                    m `shouldSatisfy` (\x -> x >= 0 && x < 4)
                )
                sids
