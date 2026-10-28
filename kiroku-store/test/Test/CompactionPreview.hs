{-# LANGUAGE OverloadedRecordDot #-}

module Test.CompactionPreview (spec) where

import Control.Concurrent (myThreadId)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Kiroku.Store hiding (id, target)
import Test.CompactionHelpers
import Test.Helpers
import Test.Hspec

spec :: Spec
spec = describe "compaction preview" $ do
  it "returns a deterministic sealed report and leaves every event unchanged" $ withTestStore $ \store -> do
    events <- seed store origin 5
    input <- inputFor store [events !! 1, events !! 2]
    before <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 0) 100)
    first <- readyReport store (manifest input)
    second <- readyReport store (manifest input)
    second `shouldBe` first
    (first.selectedEvents, first.homeMemberships, first.globalMemberships, first.linkMemberships) `shouldBe` (2, 2, 2, 0)
    (first.lowestGlobalPosition, first.highestGlobalPosition) `shouldBe` (GlobalPosition 2, GlobalPosition 3)
    first.reportDigest `shouldBe` compactionReportDigest first
    runStoreIO store (readAllForward (GlobalPosition 0) 100) `shouldReturn` Right before
    runStoreIO store (runTransaction (previewCompactionTx (manifest input))) `shouldReturn` Right (Right (CompactionPreviewReady first))

  it "previews the stream head and logically truncated events" $ withTestStore $ \store -> do
    events <- seed store origin 3
    input <- inputFor store [head events, last events]
    _ <- storeRead =<< runStoreIO store (setStreamTruncateBefore origin (StreamVersion 3))
    report <- readyReport store (manifest input)
    report.selectedEvents `shouldBe` 2

  it "checks acknowledged links per fact, including links of links" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    _ <- storeRead =<< runStoreIO store (linkToStream target [event.eventId])
    _ <- storeRead =<< runStoreIO store (linkToStream mirror [event.eventId])
    input <- inputFor store [event]
    report <- readyReport store (manifest input)
    report.linkMemberships `shouldBe` 2
    let [selection] = input.selections
        unacknowledged = manifest (input & #selections .~ [selection & #acknowledgedLinks .~ V.singleton (LinkWitness target (StreamVersion 1))] & #streamHeads .~ filter (\h -> h.stream /= mirror) input.streamHeads)
    assertRefusals store unacknowledged [CompactionUnexpectedLink event.eventId (LinkWitness mirror (StreamVersion 1))]
    let badLink = LinkWitness target (StreamVersion 2)
        bad = manifest (input & #selections .~ [selection & #acknowledgedLinks .~ V.fromList [badLink, LinkWitness mirror (StreamVersion 1)]])
    assertRefusals store bad [CompactionUnexpectedLink event.eventId (LinkWitness target (StreamVersion 1)), CompactionAcknowledgedLinkMissing event.eventId badLink]

  it "reports missing streams without fabricating event or link refusals" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    input <- inputFor store [event]
    let [selection] = input.selections
        missing = StreamName "missing"
        changed =
          input
            & #selections .~ [selection & #originStream .~ missing]
            & #streamHeads .~ [StreamHeadWitness missing (StreamVersion 1)]
    assertRefusals store (manifest changed) [CompactionStreamMissing missing]
    let linked =
          input
            & #selections .~ [selection & #acknowledgedLinks .~ V.singleton (LinkWitness missing (StreamVersion 1))]
            & #streamHeads .~ (StreamHeadWitness missing (StreamVersion 1) : input.streamHeads)
    assertRefusals store (manifest linked) [CompactionStreamMissing missing]

  it "reports soft deletion and head drift" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    input <- inputFor store [event]
    let drifted = manifest (input & #streamHeads .~ [StreamHeadWitness origin (StreamVersion 2)])
    assertRefusals store drifted [CompactionStreamHeadDrift origin (StreamVersion 2) (StreamVersion 1)]
    _ <- storeRead =<< runStoreIO store (softDeleteStream origin)
    assertRefusals store (manifest input) [CompactionStreamSoftDeleted origin]

  it "reports wrong origin versions and global positions, and unknown selected IDs" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    input <- inputFor store [event]
    let [selection] = input.selections
        actual = WitnessMismatch origin (StreamVersion 1) (Just (GlobalPosition 1))
    assertRefusals store (manifest (input & #selections .~ [selection & #originVersion .~ StreamVersion 2])) [CompactionWitnessMismatch event.eventId actual]
    assertRefusals store (manifest (input & #selections .~ [selection & #globalPosition .~ GlobalPosition 2])) [CompactionWitnessMismatch event.eventId actual]
    assertRefusals store (manifest (input & #selections .~ [selection & #eventId .~ EventId UUID.nil])) [CompactionSelectedEventMissing (EventId UUID.nil)]

  it "detects missing home/global rows and inconsistent original-version columns" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    input <- inputFor store [event]
    raw store "BEGIN; ALTER TABLE kiroku.stream_events DISABLE TRIGGER no_update_stream_events; UPDATE kiroku.stream_events SET original_stream_version=2 WHERE stream_id=0; ALTER TABLE kiroku.stream_events ENABLE TRIGGER no_update_stream_events; COMMIT"
    assertRefusals store (manifest input) [CompactionWitnessMismatch event.eventId (WitnessMismatch origin (StreamVersion 2) (Just (GlobalPosition 1)))]
    raw store "BEGIN; SET LOCAL kiroku.enable_hard_deletes='on'; DELETE FROM kiroku.stream_events WHERE stream_id=0; COMMIT"
    assertRefusals store (manifest input) [CompactionWitnessMismatch event.eventId (WitnessMismatch origin (StreamVersion 1) Nothing)]
    -- Restore just the global row through SQL, then remove the home row.
    let EventId uid = event.eventId
        StreamId sid = event.originalStreamId
    raw store ("BEGIN; SET LOCAL kiroku.enable_hard_deletes='on'; INSERT INTO kiroku.stream_events(event_id,stream_id,stream_version,original_stream_id,original_stream_version,category) VALUES ('" <> UUID.toText uid <> "',0,1," <> T.pack (show sid) <> ",1,'orders'); DELETE FROM kiroku.stream_events WHERE stream_id <> 0; COMMIT")
    assertRefusals store (manifest input) [CompactionWitnessMismatch event.eventId (WitnessMismatch origin (StreamVersion 1) (Just (GlobalPosition 1)))]

  it "refuses or counts dead letters according to the sealed policy" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    input <- inputFor store [event]
    insertDeadLetterForEvent store "projection" event
    assertRefusals store (manifest input) [CompactionDeadLettersPresent event.eventId 1]
    report <- readyReport store (manifest (input & #deadLetterPolicy .~ RemoveDeadLetters))
    report.deadLettersRemoved `shouldBe` 1

  it "excludes the entire selected set from causation dependents" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    let EventId uid = event.eventId
    _ <- storeRead =<< runStoreIO store (appendToStream target NoStream [makeEvent "Dependent" (Aeson.object []) & #causationId .~ Just uid])
    input <- inputFor store [event]
    assertRefusals store (manifest input) [CompactionCausationDependentsPresent event.eventId 1]
    report <- readyReport store (manifest (input & #causationPolicy .~ AllowDanglingCausation))
    report.causationDependents `shouldBe` 1
    events <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 0) 100)
    together <- inputFor store (V.toList events)
    both <- readyReport store (manifest together)
    both.causationDependents `shouldBe` 0

  it "short-circuits a wrong store identity before all other findings" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    input <- inputFor store [event]
    let wrong = StoreIdentity UUID.nil
        changed = input & #storeIdentity .~ wrong & #streamHeads .~ [StreamHeadWitness origin (StreamVersion 99)]
    assertRefusals store (manifest changed) [CompactionStoreIdentityMismatch wrong input.storeIdentity]

  it "reports active leases and succeeds after release" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    input <- inputFor store [event]
    let Right owner = mkHistoryRetentionLeaseOwner "preview"
        Right reason = mkHistoryRetentionLeaseReason "test"
        Right duration = mkHistoryRetentionLeaseDuration 60
    lease <- storeRead =<< runStoreIO store (acquireHistoryRetentionLease (HistoryRetentionLeaseRequest owner reason duration))
    Right (Left (CompactionHistoryRetentionActive conflict :| [])) <- runStoreIO store (previewCompaction (manifest input))
    conflict.activeLeaseCount `shouldBe` 1
    _ <- storeRead =<< runStoreIO store (releaseHistoryRetentionLease (HistoryRetentionLeaseHandle (lease ^. #leaseId) owner))
    _ <- readyReport store (manifest input)
    pure ()

  it "returns every independent finding in deterministic order" $ withTestStore $ \store -> do
    [event] <- seed store origin 1
    input <- inputFor store [event]
    let [selection] = input.selections
        missing = StreamName "zz-missing"
        extra = CompactionSelection (EventId UUID.nil) missing (StreamVersion 1) (GlobalPosition 2) V.empty
        changed =
          input
            & #selections .~ [selection & #originVersion .~ StreamVersion 2, extra]
            & #streamHeads .~ [StreamHeadWitness origin (StreamVersion 2), StreamHeadWitness missing (StreamVersion 1)]
    assertRefusals
      store
      (manifest changed)
      [ CompactionStreamHeadDrift origin (StreamVersion 2) (StreamVersion 1),
        CompactionStreamMissing missing,
        CompactionWitnessMismatch event.eventId (WitnessMismatch origin (StreamVersion 1) (Just (GlobalPosition 1)))
      ]

  it "recognizes ledger conflicts and returns stored records without resealing them" $ withTestStore $ \store -> do
    events <- seed store origin 2
    input <- inputFor store events
    let m = manifest input
        StoreIdentity identity = input.storeIdentity
        digest = compactionDigestHex (compactionManifestDigest m)
        headsJson = TE.decodeUtf8 (LBS.toStrict (Aeson.encode input.streamHeads))
    raw store ("INSERT INTO kiroku.event_compactions(manifest_digest,report_digest,store_id,operation,dead_letter_policy,causation_policy,selected_events,home_memberships,global_memberships,link_memberships,dead_letters_removed,causation_dependents,lowest_global_position,highest_global_position,affected_streams) VALUES (decode('" <> digest <> "','hex'),decode(repeat('00',32),'hex'),'" <> UUID.toText identity <> "','stored-operation','refuse','refuse',2,2,2,0,0,0,1,2,'" <> headsJson <> "'::jsonb)")
    Right (Left (CompactionLedgerConflict cid 2 :| [])) <- runStoreIO store (previewCompaction m)
    raw store "BEGIN; SET LOCAL kiroku.enable_hard_deletes='on'; DELETE FROM kiroku.stream_events; DELETE FROM kiroku.events; COMMIT"
    Right (Right (CompactionPreviewAlreadyApplied record)) <- runStoreIO store (previewCompaction m)
    record.compactionId `shouldBe` cid
    record.report.operation `shouldBe` either (error . show) id (mkCompactionOperation "stored-operation")
    compactionDigestHex record.report.reportDigest `shouldBe` T.replicate 64 "0"

  it "uses one caller checkout and emits one typed outcome event" $ do
    ownerThread <- myThreadId
    checkouts <- newIORef (0 :: Int)
    observed <- newIORef []
    let tweak settings =
          settings
            { eventHandler = Just (\event -> modifyIORef' observed (event :)),
              observationHandler = Just $ \case
                ConnectionObservation _ InUseConnectionStatus -> do
                  current <- myThreadId
                  when (current == ownerThread) (modifyIORef' checkouts (+ 1))
                _ -> pure ()
            }
    withTestStoreSettings tweak $ \store -> do
      events <- seed store origin 2
      input <- inputFor store events
      writeIORef observed []
      before <- readIORef checkouts
      _ <- readyReport store (manifest input)
      readIORef checkouts `shouldReturn` (before + 1)
      recorded <- readIORef observed
      [(digest, count)] <- pure [(d, n) | KirokuEventCompactionPreviewed d n <- recorded]
      (digest, count) `shouldBe` (compactionManifestDigest (manifest input), 2)
      let drifted = manifest (input & #streamHeads .~ [StreamHeadWitness origin (StreamVersion 3)])
      _ <- storeRead =<< runStoreIO store (previewCompaction drifted)
      refused <- readIORef observed
      [total] <- pure [n | KirokuEventCompactionRefused _ _ n <- refused]
      total `shouldBe` 1

origin, target, mirror :: StreamName
origin = StreamName "orders-1"
target = StreamName "audit-1"
mirror = StreamName "audit-2"

assertRefusals :: KirokuStore -> CompactionManifest -> [CompactionRefusal] -> Expectation
assertRefusals store m expected = runStoreIO store (previewCompaction m) `shouldReturn` Right (Left (NE.fromList expected))
