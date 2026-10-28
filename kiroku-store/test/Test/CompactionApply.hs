{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Test.CompactionApply (spec) where

import Control.Concurrent (myThreadId, threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (newEmptyMVar)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_, void, when)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Hedgehog hiding (property)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Kiroku.Store hiding (id, target)
import Kiroku.Store.SQL qualified as StoreSQL
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import Test.CompactionHelpers
import Test.Helpers
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog, modifyMaxSuccess)

spec :: Spec
spec = describe "compaction apply" $ do
  it "removes exactly the selections, preserves retained envelopes and records the preview report" $ withTestStore $ \store -> do
    events <- seed store origin 6
    input <- inputFor store [events !! 1, events !! 3]
    let m = manifest input
        kept = filter (\e -> e.eventId `notElem` map (\s -> s.eventId) input.selections) events
    preview <- readyReport store m
    Right (CompactionAppliedNow record) <- storeRead =<< runStoreIO store (applyCompaction m)
    record.report `shouldBe` preview
    runStoreIO store (readAllForward (GlobalPosition 0) 100) `shouldReturn` Right (V.fromList kept)
    countEvents store `shouldReturn` 4
    Just info <- storeRead =<< runStoreIO store (getStream origin)
    info.version `shouldBe` StreamVersion 6
    runStoreIO store (compactionLedger (ledgerQuery 10)) `shouldReturn` Right (V.singleton record)
    runStoreIO store (runTransaction (compactionLedgerTx (ledgerQuery 10))) `shouldReturn` Right (V.singleton record)
    record.report.reportDigest `shouldBe` compactionReportDigest record.report
    runStoreIO store (applyCompaction m) `shouldReturn` Right (Right (CompactionAlreadyApplied record))
    runStoreIO store (previewCompaction m) `shouldReturn` Right (Right (CompactionPreviewAlreadyApplied record))
    let retainedVersions = [1, 3, 5, 6]
    forward <- storeRead =<< runStoreIO store (readStreamForward origin (StreamVersion 0) 100)
    map (\e -> e.streamVersion) (V.toList forward) `shouldBe` map StreamVersion retainedVersions
    backward <- storeRead =<< runStoreIO store (readStreamBackward origin (StreamVersion 100) 100)
    map (\e -> e.streamVersion) (V.toList backward) `shouldBe` map StreamVersion (reverse retainedVersions)
    allBack <- storeRead =<< runStoreIO store (readAllBackward (GlobalPosition 100) 100)
    allBack `shouldBe` V.fromList (reverse kept)
    afterGap <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 2) 100)
    afterGap `shouldBe` V.fromList (filter (\e -> e.globalPosition > GlobalPosition 2) kept)
    category <- storeRead =<< runStoreIO store (readCategory (CategoryName "orders") (GlobalPosition 0) 100)
    category `shouldBe` V.fromList kept
    appended <- storeRead =<< runStoreIO store (appendToStream origin (ExactVersion (StreamVersion 6)) [makeEvent "AfterCompaction" (Aeson.object [])])
    appended.streamVersion `shouldBe` StreamVersion 7
    runStoreIO store (appendToStream origin (ExactVersion (StreamVersion 4)) [makeEvent "Stale" (Aeson.object [])])
      `shouldReturn` Left (WrongExpectedVersion origin (ExactVersion (StreamVersion 4)) (StreamVersion 0))

  it "rolls back both deletion and ledger insertion when the caller condemns its transaction" $ withTestStore $ \store -> do
    events <- seed store origin 3
    input <- inputFor store [events !! 1]
    Right (CompactionAppliedNow _) <- storeRead =<< runStoreIO store (runTransaction (applyCompactionTx (manifest input) <* Tx.condemn))
    runStoreIO store (readAllForward (GlobalPosition 0) 100) `shouldReturn` Right (V.fromList events)
    runStoreIO store (compactionLedger (ledgerQuery 10)) `shouldReturn` Right V.empty

  it "refuses unexpected links and preserves retained links and all heads" $ withTestStore $ \store -> do
    events <- seed store origin 3
    _ <- storeRead =<< runStoreIO store (linkToStream target (map (\e -> e.eventId) events))
    _ <- storeRead =<< runStoreIO store (linkToStream mirror [(events !! 1).eventId])
    input <- inputFor store [events !! 1]
    let [selection] = input.selections
        refused = manifest (input & #selections .~ [selection & #acknowledgedLinks .~ V.empty] & #streamHeads .~ [StreamHeadWitness origin (StreamVersion 3)])
    Right (Left _) <- runStoreIO store (applyCompaction refused)
    countEvents store `shouldReturn` 3
    runStoreIO store (compactionLedger (ledgerQuery 10)) `shouldReturn` Right V.empty
    before <- storeRead =<< runStoreIO store (readStreamForward target (StreamVersion 0) 100)
    Right (CompactionAppliedNow record) <- storeRead =<< runStoreIO store (applyCompaction (manifest input))
    record.report.linkMemberships `shouldBe` 2
    after <- storeRead =<< runStoreIO store (readStreamForward target (StreamVersion 0) 100)
    after `shouldBe` V.filter (\e -> e.eventId /= selection.eventId) before
    Just info <- storeRead =<< runStoreIO store (getStream target)
    info.version `shouldBe` StreamVersion 3

  it "retains high-water frontiers after tail and complete-stream compaction" $ withTestStore $ \store -> do
    events <- seed store origin 3
    input <- inputFor store (drop 1 events)
    _ <- applied store (manifest input)
    runStoreIO store visibleGlobalHeadPosition `shouldReturn` Right (GlobalPosition 1)
    frontier <- storeRead =<< runStoreIO store subscriptionCheckpointInventory
    frontier.storePosition `shouldBe` GlobalPosition 3
    lastInput <- inputFor store [head events]
    _ <- applied store (manifest lastInput)
    runStoreIO store visibleGlobalHeadPosition `shouldReturn` Right (GlobalPosition 0)
    Just info <- storeRead =<< runStoreIO store (getStream origin)
    info.version `shouldBe` StreamVersion 3
    append <- storeRead =<< runStoreIO store (appendToStream origin (ExactVersion (StreamVersion 3)) [makeEvent "AfterEmpty" (Aeson.object [])])
    (append.streamVersion, append.globalPosition) `shouldBe` (StreamVersion 4, GlobalPosition 4)

  it "refuses changed heads, missing events and a ledger whose IDs reappear" $ withTestStore $ \store -> do
    events <- seed store origin 3
    input <- inputFor store [events !! 1]
    _ <- seed store origin 1
    runStoreIO store (applyCompaction (manifest input))
      `shouldReturn` Right (Left (CompactionStreamHeadDrift origin (StreamVersion 3) (StreamVersion 4) :| []))
    fresh <- inputFor store [events !! 1]
    record <- applied store (manifest fresh)
    let missing = manifest (fresh & #operation .~ operation "never-applied")
    runStoreIO store (applyCompaction missing) `shouldReturn` Right (Left (CompactionSelectedEventMissing (events !! 1).eventId :| []))
    _ <- storeRead =<< runStoreIO store (appendToStream (StreamName "reused-id") NoStream [makeEvent "Reused" (Aeson.object []) & #eventId .~ Just (events !! 1).eventId])
    runStoreIO store (applyCompaction (manifest fresh)) `shouldReturn` Right (Left (CompactionLedgerConflict record.compactionId 1 :| []))

  it "refuses a partially matching store before deleting any surviving selection" $ withTestStore $ \store -> do
    events <- seed store origin 3
    whole <- inputFor store (take 2 events)
    first <- inputFor store [head events]
    _ <- applied store (manifest first)
    runStoreIO store (applyCompaction (manifest whole))
      `shouldReturn` Right (Left (CompactionSelectedEventMissing (head events).eventId :| []))
    runStoreIO store (readAllForward (GlobalPosition 0) 100) `shouldReturn` Right (V.fromList (tail events))
    records <- storeRead =<< runStoreIO store (compactionLedger (ledgerQuery 10))
    V.length records `shouldBe` 1

  it "removes dead letters only by policy and permits explicitly dangling causation" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    let EventId uid = event.eventId
    _ <- storeRead =<< runStoreIO store (appendToStream target NoStream [makeEvent "Dependent" (Aeson.object []) & #causationId .~ Just uid])
    insertDeadLetterForEvent store "projection" event
    input <- inputFor store [event]
    Right (Left _) <- runStoreIO store (applyCompaction (manifest input))
    countEvents store `shouldReturn` 2
    record <- applied store (manifest (input & #deadLetterPolicy .~ RemoveDeadLetters & #causationPolicy .~ AllowDanglingCausation))
    (record.report.deadLettersRemoved, record.report.causationDependents) `shouldBe` (1, 1)
    countDeadLettersForEvents store [EventId uid] `shouldReturn` 0
    kept <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 0) 100)
    (V.head kept).causationId `shouldBe` Just uid

  it "refuses an active lease, then applies below a logical truncate marker" $ withTestStore $ \store -> do
    events <- seed store origin 3
    input <- inputFor store [head events]
    _ <- storeRead =<< runStoreIO store (setStreamTruncateBefore origin (StreamVersion 3))
    let Right owner = mkHistoryRetentionLeaseOwner "apply"
        Right reason = mkHistoryRetentionLeaseReason "test"
        Right duration = mkHistoryRetentionLeaseDuration 60
    lease <- storeRead =<< runStoreIO store (acquireHistoryRetentionLease (HistoryRetentionLeaseRequest owner reason duration))
    Right (Left (CompactionHistoryRetentionActive _ :| [])) <- runStoreIO store (applyCompaction (manifest input))
    countEvents store `shouldReturn` 3
    _ <- storeRead =<< runStoreIO store (releaseHistoryRetentionLease (HistoryRetentionLeaseHandle lease.leaseId owner))
    _ <- applied store (manifest input)
    Just info <- storeRead =<< runStoreIO store (getStream origin)
    info.truncateBefore `shouldBe` StreamVersion 3

  forM_ [(AllStreams, 1, False), (AllStreams, 2, False), (Category (CategoryName "orders"), 2, False), (AllStreams, 2, True), (Category (CategoryName "orders"), 2, True)] $ \(subscriptionTarget, checkpoint, grouped) ->
    it ("continues subscription catch-up and live delivery across removed positions: " <> show (subscriptionTarget, checkpoint, grouped)) $ do
      ready <- newEmptyMVar
      let name = SubscriptionName "compaction-resume"
          tweak settings = settings & #eventHandler .~ Just (caughtUpEventHandler name ready Nothing)
      withTestStoreSettings tweak $ \store -> do
        events <- seed store origin 6
        input <- inputFor store [events !! 1, events !! 3]
        _ <- applied store (manifest input)
        _ <- storeRead =<< runStoreIO store (runTransaction (Tx.statement ("compaction-resume", checkpoint) StoreSQL.saveCheckpointStmt))
        received <- newIORef []
        let handler event = do
              modifyIORef' received (event.globalPosition :)
              pure (if event.globalPosition == GlobalPosition 7 then Stop else Continue)
            config = (defaultSubscriptionConfig name subscriptionTarget handler) {consumerGroup = if grouped then Just (validConsumerGroup 0 1) else Nothing}
        handle <- subscribe store config
        within (waitForSubscriptionLive ready)
        _ <- storeRead =<< runStoreIO store (appendToStream origin (ExactVersion (StreamVersion 6)) [makeEvent "PostGap" (Aeson.object [])])
        completed <- waitWithTimeout 5_000_000 handle
        completed `shouldSatisfy` \case Right (Right ()) -> True; _ -> False
        reverse <$> readIORef received `shouldReturn` map GlobalPosition [3, 5, 6, 7]
        inventory <- storeRead =<< runStoreIO store subscriptionCheckpointInventory
        -- The worker persists the terminal delivery through the normal save path.
        rows <- storeRead =<< runStoreIO store (runTransaction (Tx.statement ("compaction-resume", 0) StoreSQL.getCheckpointMemberStmt))
        rows `shouldBe` Just 7
        inventory.storePosition `shouldBe` GlobalPosition 7

  it "serializes competing applies into one commit and one identical ledgered no-op" $ withTestStore $ \store -> do
    events <- seed store origin 3
    input <- inputFor store [head events]
    (first, second) <- Async.concurrently (runStoreIO store (applyCompaction (manifest input))) (runStoreIO store (applyCompaction (manifest input)))
    let records = [record | Right (Right (CompactionAppliedNow record)) <- [first, second]]
        repeated = [record | Right (Right (CompactionAlreadyApplied record)) <- [first, second]]
    length records `shouldBe` 1
    repeated `shouldBe` records

  it "blocks an append while apply holds stream locks, then continues from the unchanged head" $ withTestStore $ \store -> do
    events <- seed store origin 3
    input <- inputFor store [head events]
    Async.withAsync (runStoreIO store (runTransaction (applyCompactionTx (manifest input) <* pause "apply-held"))) $ \worker -> do
      waitPhase store "apply-held"
      Async.withAsync (runStoreIO store (appendToStream origin (ExactVersion (StreamVersion 3)) [makeEvent "BlockedAppend" (Aeson.object [])])) $ \writer -> do
        threadDelay 50_000
        Async.poll writer >>= (`shouldSatisfy` maybe True (const False))
        Right (Right (CompactionAppliedNow _)) <- within (Async.wait worker)
        Right result <- within (Async.wait writer)
        result.streamVersion `shouldBe` StreamVersion 4

  it "waits for a replay stream guard, but a recorded no-op never takes stream locks" $ withTestStore $ \store -> do
    events <- seed store origin 3
    input <- inputFor store [head events]
    let m = manifest input
    Async.withAsync (runStoreIO store (runTransaction (lockStreamHistoryForReplayTx origin <* pause "guard-held"))) $ \guard -> do
      waitPhase store "guard-held"
      Async.withAsync (runStoreIO store (applyCompaction m)) $ \worker -> do
        threadDelay 50_000
        Async.poll worker >>= (`shouldSatisfy` maybe True (const False))
        _ <- within (Async.wait guard)
        Right (Right (CompactionAppliedNow _)) <- within (Async.wait worker)
        pure ()
    Async.withAsync (runStoreIO store (runTransaction (lockStreamHistoryForReplayTx origin <* pause "noop-guard"))) $ \guard -> do
      waitPhase store "noop-guard"
      Right (Right (CompactionAlreadyApplied _)) <- withinShort (runStoreIO store (applyCompaction m))
      void (within (Async.wait guard))

  it "rejects another store's manifest before queuing for the coordinator" $ withTestStore $ \store -> do
    events <- seed store origin 1
    input <- inputFor store events
    let wrong = manifest (input & #storeIdentity .~ StoreIdentity UUID.nil)
    Async.withAsync (runStoreIO store (runTransaction (Tx.sql "SELECT singleton FROM history_retention_coordinator WHERE singleton FOR UPDATE" >> pause "coordinator-held"))) $ \holder -> do
      waitPhase store "coordinator-held"
      withinShort (runStoreIO store (applyCompaction wrong))
        `shouldReturn` Right (Left (CompactionStoreIdentityMismatch (StoreIdentity UUID.nil) input.storeIdentity :| []))
      void (within (Async.wait holder))

  it "keeps an unlisted concurrent link and rolls back every deletion (direct composer FK path)" $ withTestStore $ \store -> do
    events <- seed store origin 2
    input <- inputFor store [head events]
    Async.withAsync (runStoreIO store (runTransaction (applyCompactionTxWith (pause "concurrent-link") (manifest input)))) $ \worker -> do
      waitPhase store "concurrent-link"
      _ <- storeRead =<< runStoreIO store (linkToStream target [(head events).eventId])
      result <- within (Async.wait worker)
      result `shouldSatisfy` \case Left (UnexpectedServerError "23503" _) -> True; _ -> False
    runStoreIO store (readAllForward (GlobalPosition 0) 100) `shouldReturn` Right (V.fromList events)
    runStoreIO store (compactionLedger (ledgerQuery 10)) `shouldReturn` Right V.empty
    links <- storeRead =<< runStoreIO store (readStreamForward target (StreamVersion 0) 100)
    V.length links `shouldBe` 1

  forM_ [RefuseDeadLetters, RemoveDeadLetters] $ \policy ->
    it ("rolls back a concurrent dead letter under " <> show policy) $ withTestStore $ \store -> do
      events <- seed store origin 2
      input <- inputFor store [head events]
      let m = manifest (input & #deadLetterPolicy .~ policy)
      Async.withAsync (runStoreIO store (runTransaction (applyCompactionTxWith (pause "concurrent-dead-letter") m))) $ \worker -> do
        waitPhase store "concurrent-dead-letter"
        insertDeadLetterForEvent store "concurrent" (head events)
        result <- within (Async.wait worker)
        case policy of
          RefuseDeadLetters -> result `shouldSatisfy` \case Left (UnexpectedServerError "23503" _) -> True; _ -> False
          RemoveDeadLetters -> result `shouldSatisfy` \case Left (CompactionConcurrentMutation digest "dead-letter count") -> digest == compactionManifestDigest m; _ -> False
      countEvents store `shouldReturn` 2
      let EventId uid = (head events).eventId
      countDeadLettersForEvents store [EventId uid] `shouldReturn` 1
      runStoreIO store (compactionLedger (ledgerQuery 10)) `shouldReturn` Right V.empty

  it "maps the real effect's concurrent foreign-key failure to a typed retryable error" $ withTestStore $ \store -> do
    events <- seed store origin 2
    input <- inputFor store [head events]
    raw store "CREATE FUNCTION kiroku.test_compaction_pause() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(0.6); RETURN NULL; END $$; CREATE TRIGGER test_compaction_pause BEFORE DELETE ON kiroku.stream_events FOR EACH STATEMENT EXECUTE FUNCTION kiroku.test_compaction_pause()"
    Async.withAsync (runStoreIO store (applyCompaction (manifest input))) $ \worker -> do
      waitUntil store "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND state='active' AND wait_event='PgSleep' AND query LIKE 'DELETE FROM stream_events%')"
      _ <- storeRead =<< runStoreIO store (linkToStream target [(head events).eventId])
      result <- within (Async.wait worker)
      result `shouldSatisfy` \case Left (CompactionConcurrentMutation digest _) -> digest == compactionManifestDigest (manifest input); _ -> False
    countEvents store `shouldReturn` 2
    runStoreIO store (compactionLedger (ledgerQuery 10)) `shouldReturn` Right V.empty

  it "documents causation refusal as validation-time best-effort for unlisted writers" $ withTestStore $ \store -> do
    events <- seed store origin 2
    input <- inputFor store [head events]
    let EventId uid = (head events).eventId
    Async.withAsync (runStoreIO store (runTransaction (applyCompactionTxWith (pause "concurrent-causation") (manifest input)))) $ \worker -> do
      waitPhase store "concurrent-causation"
      _ <- storeRead =<< runStoreIO store (appendToStream target NoStream [makeEvent "LateDependent" (Aeson.object []) & #causationId .~ Just uid])
      Right (Right (CompactionAppliedNow record)) <- within (Async.wait worker)
      record.report.causationDependents `shouldBe` 0
    kept <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 0) 100)
    (V.last kept).causationId `shouldBe` Just uid

  it "accepts sequential disjoint chunks without changing their shared stream-head witness" $ withTestStore $ \store -> do
    events <- seed store origin 4
    first <- inputFor store [events !! 0]
    second <- inputFor store [events !! 1]
    older <- applied store (manifest first)
    newer <- applied store (manifest second)
    runStoreIO store (compactionLedger (ledgerQuery 1)) `shouldReturn` Right (V.singleton newer)
    runStoreIO store (compactionLedger (ledgerQuery 10)) `shouldReturn` Right (V.fromList [newer, older])
    retained <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 0) 100)
    retained `shouldBe` V.fromList (drop 2 events)

  it "shares KRCMP error mapping with every transaction composer and rejects malformed details" $ withTestStore $ \store -> do
    events <- seed store origin 1
    input <- inputFor store events
    let digest = compactionManifestDigest (manifest input)
        raise detail = runStoreIO store (runTransaction (Tx.sql (TE.encodeUtf8 ("DO $$ BEGIN RAISE EXCEPTION USING ERRCODE='KRCMP', MESSAGE='events count', DETAIL='" <> detail <> "'; END $$"))))
    raise (compactionDigestHex digest) `shouldReturn` Left (CompactionConcurrentMutation digest "events count")
    raise "malformed" `shouldReturn` Left (UnexpectedServerError "KRCMP" "events count")

  it "emits committed, already-applied and refused events with one caller checkout per apply" $ do
    owner <- myThreadId
    calls <- newIORef (0 :: Int)
    eventsRef <- newIORef []
    let tweak settings =
          settings
            { eventHandler = Just (\event -> modifyIORef' eventsRef (event :)),
              observationHandler = Just $ \case
                ConnectionObservation _ InUseConnectionStatus -> do current <- myThreadId; when (current == owner) (modifyIORef' calls (+ 1))
                _ -> pure ()
            }
    withTestStoreSettings tweak $ \store -> do
      events <- seed store origin 2
      input <- inputFor store [head events]
      writeIORef eventsRef []
      before <- readIORef calls
      record <- applied store (manifest input)
      readIORef calls `shouldReturn` before + 1
      emitted <- readIORef eventsRef
      [(cid, digest, count, memberships)] <- pure [(cid, d, n, ms) | KirokuEventCompactionApplied cid d n ms <- emitted]
      (cid, digest, count, memberships) `shouldBe` (record.compactionId, compactionManifestDigest (manifest input), 1, 2)
      _ <- storeRead =<< runStoreIO store (applyCompaction (manifest input))
      again <- readIORef eventsRef
      [repeated] <- pure [cid | KirokuEventCompactionAlreadyApplied cid _ <- again]
      repeated `shouldBe` record.compactionId
      let changed = manifest (input & #operation .~ operation "unrecorded")
      _ <- storeRead =<< runStoreIO store (applyCompaction changed)
      refused <- readIORef eventsRef
      [total] <- pure [n | KirokuEventCompactionRefused _ _ n <- refused]
      total `shouldBe` 1

  modifyMaxSuccess (const 20) $ it "compactingARandomSubsetPreservesTheRest across streams and links" $ hedgehog $ do
    widths <- forAll (Gen.list (Range.linear 2 4) (Gen.int (Range.linear 3 8)))
    picks <- forAll (Gen.list (Range.singleton (sum widths)) Gen.bool)
    evalIO $ withMigratedTestDatabase $ \conn -> withStore (defaultConnectionSettings conn) $ \store -> do
      groups <- sequence [seed store (StreamName ("random-" <> T.pack (show n))) width | (n, width) <- zip [1 :: Int ..] widths]
      let allEvents = concat groups
          chosen = case [e | (e, True) <- zip allEvents picks] of [] -> [head allEvents]; xs -> xs
      _ <- storeRead =<< runStoreIO store (linkToStream target (map (\e -> e.eventId) (take 3 allEvents)))
      input <- inputFor store chosen
      before <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 0) 100)
      linked <- storeRead =<< runStoreIO store (readStreamForward target (StreamVersion 0) 100)
      let selected = map (\e -> e.eventId) chosen
      _ <- applied store (manifest input)
      runStoreIO store (readAllForward (GlobalPosition 0) 100) `shouldReturn` Right (V.filter (\e -> e.eventId `notElem` selected) before)
      runStoreIO store (readStreamForward target (StreamVersion 0) 100) `shouldReturn` Right (V.filter (\e -> e.eventId `notElem` selected) linked)
      forM_ input.streamHeads $ \h -> do
        Just stream <- storeRead =<< runStoreIO store (getStream h.stream)
        stream.version `shouldBe` h.headVersion
      countEvents store `shouldReturn` fromIntegral (length allEvents - length chosen)

origin, target, mirror :: StreamName
origin = StreamName "orders-1"
target = StreamName "audit-1"
mirror = StreamName "audit-2"

operation :: Text -> CompactionOperation
operation = either (error . show) id . mkCompactionOperation

applied :: KirokuStore -> CompactionManifest -> IO CompactionRecord
applied store m = do
  Right (CompactionAppliedNow record) <- storeRead =<< runStoreIO store (applyCompaction m)
  pure record

pause :: Text -> Tx.Transaction ()
pause marker = void (Tx.statement () (preparable ("SELECT pg_sleep(0.6) IS NULL /* " <> marker <> " */") E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))))

waitPhase :: KirokuStore -> Text -> IO ()
waitPhase store marker = waitUntil store ("SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND state='active' AND query='SELECT pg_sleep(0.6) IS NULL /* " <> marker <> " */')")

waitUntil :: KirokuStore -> Text -> IO ()
waitUntil store query = within $ loop (150 :: Int)
  where
    loop 0 = fail "compaction barrier was not reached"
    loop n = do
      found <- storeRead =<< Pool.use (store ^. #pool) (Session.statement () (preparable query E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))))
      if found then pure () else threadDelay 10_000 >> loop (n - 1)

within :: IO a -> IO a
within action = Async.race (threadDelay 5_000_000) action >>= either (const (fail "compaction test deadline expired")) pure

withinShort :: IO a -> IO a
withinShort action = Async.race (threadDelay 250_000) action >>= either (const (fail "no-op or identity refusal waited for an unrelated lock")) pure
