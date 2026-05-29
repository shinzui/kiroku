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
import Control.Exception (fromException)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Subscription.Stream (subscriptionStream)
import Kiroku.Store.Subscription.Types (ConsumerGroup (..), SubscriptionConfigM (..))
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import Streamly.Data.Stream qualified as Stream
import Test.Helpers (makeEvent, waitForPublisher, waitWithTimeout, withTestStore, withTestStoreSettings)
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

-- | A size-@n@ @$all@-group config for member @m@ with the given handler.
memberConfigAll ::
    Text -> Int32 -> Int32 -> EventHandler -> SubscriptionConfig
memberConfigAll nm m n h =
    (defaultSubscriptionConfig (SubscriptionName nm) AllStreams h)
        { consumerGroup = Just (ConsumerGroup{member = m, size = n})
        }

{- | Run a subscription built from the given config-completer, collecting the
global positions it delivers and stopping the handler after @k@ events. Returns
the @k@ positions in delivery order.
-}
collectStopAfter :: KirokuStore -> (EventHandler -> SubscriptionConfig) -> Int -> IO [Int64]
collectStopAfter store mkCfg k = do
    ref <- newIORef []
    countVar <- newTVarIO (0 :: Int)
    let h evt = do
            modifyIORef' ref (snd (pairOf evt) :)
            c <- atomically $ do
                c0 <- readTVar countVar
                let c1 = c0 + 1
                writeTVar countVar c1
                pure c1
            pure (if c >= k then Stop else Continue)
    handle <- subscribe store (mkCfg h)
    _ <- waitWithTimeout 15_000_000 handle
    reverse <$> readIORef ref

-- | Run a Hasql session against the store pool, failing the test on a usage error.
runStmtP :: KirokuStore -> Session.Session a -> IO a
runStmtP store session = do
    r <- Pool.use (store ^. #pool) session
    either (error . show) pure r

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

    it "$all group partitions the whole store across members" $
        withTestStore $ \store -> do
            let cats = ["acct", "user", "order"]
                perCat = 10
                perStream = 2
                streams = [c <> "-" <> T.pack (show i) | c <- cats, i <- [1 .. perCat]]
                total = length streams * perStream
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
                        subscribe store (memberConfigAll "cg-all" m n h)
                    )
                    [0 .. n - 1]

            let collectedCount = sum <$> mapM (fmap length . readIORef) refs
            waitUntil 15_000_000 (fmap (>= total) collectedCount)
            mapM_ cancel handles

            collected <- mapM readIORef refs
            let allPositions = sort (concatMap (map snd) collected)
            allPositions `shouldBe` [1 .. fromIntegral total]
            mapM_ (assertPerStreamAscending . reverse) collected

    it "resumes member 2 from its own (name, member) checkpoint" $
        withTestStore $ \store -> do
            let nStreams = 60
                streams = ["rz-" <> T.pack (show i) | i <- [1 .. nStreams]]
            seed store streams 1
            waitForPublisher store (GlobalPosition (fromIntegral nStreams))

            -- Member 2's slice positions, in order, straight from the EP-1 partition
            -- SQL — the deterministic ground truth for what member 2 should receive.
            sliceV <-
                runStmtP store $
                    Session.statement
                        (0 :: Int64, "rz" :: Text, 2 :: Int32, 4 :: Int32, 100000 :: Int32)
                        SQL.readCategoryForwardConsumerGroupStmt
            let slice = map (snd . pairOf) (V.toList sliceV)
            length slice `shouldSatisfy` (>= 4)

            -- Run 1: member 2 stops after 2 events; checkpoint (rz-sub, 2) = slice!!1.
            run1 <- collectStopAfter store (memberConfig "rz-sub" "rz" 2 4) 2
            run1 `shouldBe` take 2 slice

            -- A competing, much higher checkpoint for a DIFFERENT member under the
            -- SAME name. If checkpoints were keyed by name only, member 2's restart
            -- would resume from here and skip its events; member-keyed checkpoints
            -- must ignore it.
            runStmtP store $
                Session.statement
                    ("rz-sub" :: Text, 0 :: Int32, 10_000_000 :: Int64)
                    SQL.saveCheckpointMemberStmt

            -- Run 2: member 2 restarts and must resume from its OWN checkpoint
            -- (slice!!1), delivering the next two member-2 events.
            run2 <- collectStopAfter store (memberConfig "rz-sub" "rz" 2 4) 2
            run2 `shouldBe` take 2 (drop 2 slice)

    it "lifecycle events carry the consumer-group member context (GroupMember 2 4)" $ do
        ref <- newIORef ([] :: [KirokuEvent])
        let evtHandler e = modifyIORef' ref (e :)
            isStartedMember2 ev = case ev of
                KirokuEventSubscriptionStarted (SubscriptionName "obs-sub") _ (GroupMember 2 4) -> True
                _ -> False
        withTestStoreSettings (\s -> s & #eventHandler .~ Just evtHandler) $ \store -> do
            handle <- subscribe store (memberConfig "obs-sub" "obs" 2 4 (\_ -> pure Continue))
            waitUntil 5_000_000 (any isStartedMember2 <$> readIORef ref)
            cancel handle
            evts <- readIORef ref
            any isStartedMember2 evts `shouldBe` True

    it "consumerGroupGuard fails fast when another holder holds the (name, member) lock" $ do
        withMigratedTestDatabase $ \cs -> do
            withStore (defaultConnectionSettings cs) $ \store -> do
                -- Holder: a dedicated connection takes the SESSION-level advisory
                -- lock for the same key the worker's guard probes, namely
                -- hashtextextended("guard-sub:3", 0). It is held until release.
                eConn <- Connection.acquire (Conn.connectionString cs)
                conn <- either (\e -> error ("guard holder connect failed: " <> show e)) pure eConn
                let holdStmt :: Statement Text ()
                    holdStmt =
                        preparable
                            "SELECT pg_advisory_lock(hashtextextended($1, 0))"
                            (E.param (E.nonNullable E.text))
                            D.noResult
                lockRes <- Connection.use conn (Session.statement "guard-sub:3" holdStmt)
                either (\e -> error ("guard holder lock failed: " <> show e)) pure lockRes

                let cfg =
                        (defaultSubscriptionConfig (SubscriptionName "guard-sub") (Category (CategoryName "guardcat")) (\_ -> pure Continue))
                            { consumerGroup = Just (ConsumerGroup{member = 3, size = 4})
                            , consumerGroupGuard = True
                            , retryPolicy = defaultRetryPolicy
                            }
                handle <- subscribe store cfg
                res <- waitWithTimeout 5_000_000 handle
                Connection.release conn
                case res of
                    Right (Left e)
                        | Just (ConsumerGroupGuardConflict (SubscriptionName "guard-sub") 3) <- fromException e ->
                            pure ()
                    other ->
                        expectationFailure ("expected ConsumerGroupGuardConflict, got: " <> show other)

    it "subscriptionStream forwards the consumer-group field (member 0 of 2 sees its slice)" $
        withTestStore $ \store -> do
            let nStreams = 20
                perStream = 2
                total = nStreams * perStream
                streams = ["bridge-" <> T.pack (show i) | i <- [1 .. nStreams]]
            seed store streams perStream
            waitForPublisher store (GlobalPosition (fromIntegral total))

            sliceV <-
                runStmtP store $
                    Session.statement
                        (0 :: Int64, "bridge" :: Text, 0 :: Int32, 2 :: Int32, 100000 :: Int32)
                        SQL.readCategoryForwardConsumerGroupStmt
            let slicePos = sort (map (snd . pairOf) (V.toList sliceV))
                k = length slicePos
            -- A proper, non-trivial subset of the whole category.
            k `shouldSatisfy` (\x -> x > 0 && x < total)

            (stream, cancelStream) <-
                subscriptionStream store (memberConfig "bridge-sub" "bridge" 0 2 (\_ -> pure Continue)) 64
            pulled <- Stream.toList (Stream.take k stream)
            cancelStream
            sort (map (snd . pairOf) pulled) `shouldBe` slicePos
