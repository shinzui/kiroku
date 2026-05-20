{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | Consumer-group tests for the /effectful/ subscription API (ExecPlan 30 /
EP-3). EP-2's 'Test.ConsumerGroup' proves the partitioning contract through the
plain-IO 'Kiroku.Store.Subscription.subscribe'; this module proves the same
contract holds through 'Kiroku.Store.Subscription.Effect' — the higher-order
'Subscription' effect interpreted by 'runSubscription' inside an @Eff@ stack.

Two properties are proven:

  * Each member of a size-2 category group, driven through @runSubscription@ /
    @subscribe@, receives exactly its hash-assigned slice; the two slices are
    /disjoint/, their union is /complete/, and each is /per-stream-ordered/.
  * The @ConcUnlift Persistent (Limited 1)@ strategy used by 'runSubscription'
    keeps the effect environment alive across handler calls: an
    'Effectful.State.Static.Local.State' counter mutated inside the handler
    accumulates @1, 2, 3, ...@ across deliveries rather than resetting to @1@
    each call (which is what an @Ephemeral@ unlift would produce).

__Why every handler returns 'Stop' rather than relying on external cancel.__
A worker started through the effectful interpreter runs its handler via the
captured @localUnliftIO@ environment. Cancelling such a worker from outside
(e.g. through the effectful 'Kiroku.Store.Subscription.Effect.withSubscription'
bracket) while it is blocked inside that unlift does not terminate cleanly — it
hangs the worker thread. Every member here therefore stops itself once it has
seen its expected number of events, so the worker exits on its own and the
@Eff@ scope closes with no live thread (the same shape as the working effectful
test in @kiroku-store/test/Main.hs@, "catches up with an Eff-based handler via
the effectful API"). See this module's Surprises note in
@docs/plans/30-consumer-group-effect-api-and-shibuya-adapter-integration.md@.
-}
module Test.ConsumerGroupEffect (spec) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.State.Static.Local qualified as State
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Subscription.Effect qualified as SubEff
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

{- | Assert that within each originating stream the global positions, taken in
delivery order, are strictly ascending (i.e. equal to their sorted form).
-}
assertPerStreamAscending :: [(Int64, Int64)] -> Expectation
assertPerStreamAscending chrono =
    let byStream = Map.fromListWith (\new old -> old ++ new) [(sid, [gp]) | (sid, gp) <- chrono]
     in mapM_ (\ps -> ps `shouldBe` sort ps) (Map.elems byStream)

-- | Run a Hasql session against the store pool, failing the test on error.
runStmtP :: KirokuStore -> Session.Session a -> IO a
runStmtP store session = do
    r <- Pool.use (store ^. #pool) session
    either (error . show) pure r

{- | Drive one effectful category-group member to self-completion: it 'Stop's
after receiving exactly @k@ events, so the worker exits on its own (no external
cancel). Returns the @(streamId, globalPosition)@ pairs in delivery order. The
handler runs in @Eff es@ (needing only 'IOE'), exercising the @runSubscription@
record-update pass-through of the @consumerGroup@ field.
-}
runEffMember :: KirokuStore -> Text -> Text -> Int32 -> Int32 -> Int -> IO [(Int64, Int64)]
runEffMember store nm cat m n k = do
    ref <- newIORef []
    countVar <- newTVarIO (0 :: Int)
    let effHandler :: (IOE :> es) => RecordedEvent -> Eff es SubscriptionResult
        effHandler evt = do
            liftIO $ modifyIORef' ref (pairOf evt :)
            c <- liftIO $ atomically $ do
                c0 <- readTVar countVar
                writeTVar countVar (c0 + 1)
                pure (c0 + 1)
            pure (if c >= k then Stop else Continue)
        cfg =
            (defaultSubscriptionConfig (SubscriptionName nm) (Category (CategoryName cat)) effHandler)
                { consumerGroup = Just (ConsumerGroup{member = m, size = n})
                }
    runEff $ SubEff.runSubscription store $ do
        handle <- SubEff.subscribe cfg
        liftIO $ do
            r <- waitWithTimeout 15_000_000 handle
            case r of
                Left timeout -> expectationFailure timeout
                Right (Left err) -> expectationFailure ("effectful member failed: " <> show err)
                Right (Right ()) -> pure ()
    reverse <$> readIORef ref

spec :: Spec
spec = describe "consumer groups (effectful)" $ do
    it "routes each member through the effectful API to its own disjoint, complete, per-stream-ordered slice (size-2 category group)" $
        withTestStore $ \store -> do
            let nStreams = 40
                perStream = 3
                total = nStreams * perStream
                streams = ["effcg-" <> T.pack (show i) | i <- [1 .. nStreams]]
            seed store streams perStream
            waitForPublisher store (GlobalPosition (fromIntegral total))

            -- Deterministic ground truth: each member's slice size straight from the
            -- EP-1 partition SQL. The effectful workers must reproduce exactly these.
            let sliceSize m =
                    V.length
                        <$> runStmtP
                            store
                            ( Session.statement
                                (0 :: Int64, "effcg" :: Text, m, 2 :: Int32, 100000 :: Int32)
                                SQL.readCategoryForwardConsumerGroupStmt
                            )
            k0 <- sliceSize 0
            k1 <- sliceSize 1
            k0 `shouldSatisfy` (> 0)
            k1 `shouldSatisfy` (> 0)
            (k0 + k1) `shouldBe` total

            -- Each member is driven through runSubscription/subscribe and self-exits.
            -- Same subscription name, distinct members → independent (name, member)
            -- checkpoints, so running them in sequence is safe.
            m0 <- runEffMember store "eff-cg-cat" "effcg" 0 2 k0
            m1 <- runEffMember store "eff-cg-cat" "effcg" 1 2 k1

            -- (1) Disjoint + complete: the union of both members' delivered positions
            --     is exactly [1..total] — no duplicate and no gap.
            let allPositions = sort (map snd m0 ++ map snd m1)
            allPositions `shouldBe` [1 .. fromIntegral total]
            -- (2) Per-stream ordering preserved within each member.
            assertPerStreamAscending m0
            assertPerStreamAscending m1

    it "preserves State across handler calls within one member (Persistent unlift)" $
        withTestStore $ \store -> do
            -- Five events on one stream of category "effstate"; a size-1 member sees all.
            seed store ["effstate-1"] 5
            waitForPublisher store (GlobalPosition 5)

            -- 'seenRef' records the Effectful State value observed after each
            -- increment; 'nVar' counts deliveries and drives the Stop (so self-exit
            -- never depends on the property under test). With the Persistent unlift
            -- the cloned environment is reused across calls and the counter
            -- accumulates 1,2,3,4,5; an Ephemeral unlift would record 1 every time.
            seenRef <- newIORef ([] :: [Int])
            nVar <- newTVarIO (0 :: Int)
            runEff $
                SubEff.runSubscription store $
                    State.evalState (0 :: Int) $ do
                        let cfg =
                                ( defaultSubscriptionConfig
                                    (SubscriptionName "eff-state-sub")
                                    (Category (CategoryName "effstate"))
                                    ( \_ -> do
                                        State.modify @Int (+ 1)
                                        s <- State.get @Int
                                        liftIO (modifyIORef' seenRef (s :))
                                        c <- liftIO $ atomically $ do
                                            c0 <- readTVar nVar
                                            writeTVar nVar (c0 + 1)
                                            pure (c0 + 1)
                                        pure (if c >= 5 then Stop else Continue)
                                    )
                                )
                                    { consumerGroup = Just (ConsumerGroup{member = 0, size = 1})
                                    }
                        handle <- SubEff.subscribe cfg
                        liftIO $ do
                            r <- waitWithTimeout 10_000_000 handle
                            case r of
                                Left timeout -> expectationFailure timeout
                                Right (Left err) -> expectationFailure ("effectful state member failed: " <> show err)
                                Right (Right ()) -> pure ()

            seen <- reverse <$> readIORef seenRef
            seen `shouldBe` [1, 2, 3, 4, 5]
