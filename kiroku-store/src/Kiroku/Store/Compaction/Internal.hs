{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

module Kiroku.Store.Compaction.Internal
  ( ValidatedCompaction (..),
    ValidationOutcome (..),
    LedgerOutcome (..),
    ledgerOutcomeTx,
    validateCompactionTx,
    buildReport,
    previewCompactionTx,
  )
where

import Data.Int (Int64)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.UUID (UUID)
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Compaction.SQL qualified as SQL
import Kiroku.Store.Compaction.Types
import Kiroku.Store.HistoryRetention.Internal qualified as Retention
import Kiroku.Store.SQL qualified as StoreSQL
import Kiroku.Store.Types

data ValidatedCompaction = ValidatedCompaction
  { report :: !CompactionReport,
    selectedEventIds :: !(Vector UUID),
    junctionRows :: !(Vector (UUID, Int64))
  }
  deriving stock (Eq, Show, Generic)

data ValidationOutcome
  = ValidationRefused (NonEmpty CompactionRefusal)
  | ValidationAlreadyApplied CompactionRecord
  | ValidationReady ValidatedCompaction
  deriving stock (Eq, Show)

data LedgerOutcome = LedgerUnrecorded | LedgerAlreadyApplied CompactionRecord | LedgerConflict CompactionId Int64
  deriving stock (Eq, Show)

selectedIds :: CompactionManifest -> Vector UUID
selectedIds = V.map (\s -> let EventId uid = s.eventId in uid) . manifestSelections

ledgerOutcomeTx :: CompactionManifest -> Tx.Transaction LedgerOutcome
ledgerOutcomeTx manifest = do
  found <- Tx.statement (compactionDigestBytes (compactionManifestDigest manifest)) SQL.ledgerRecordByDigestStmt
  case found of
    Nothing -> pure LedgerUnrecorded
    Just record -> do
      survivors <- Tx.statement (selectedIds manifest) SQL.survivingSelectedEventsStmt
      pure (if survivors == 0 then LedgerAlreadyApplied record else LedgerConflict record.compactionId survivors)

-- No import of Store.Transaction: it imports Effect, which consumes this module.
validateCompactionTx :: CompactionManifest -> Tx.Transaction ValidationOutcome
validateCompactionTx manifest = do
  identity <- Tx.statement () StoreSQL.storeIdentityStmt
  if identity /= manifestStoreIdentity manifest
    then pure (ValidationRefused (CompactionStoreIdentityMismatch (manifestStoreIdentity manifest) identity :| []))
    else do
      conflict <- Retention.activeHistoryRetentionConflictTx
      let leaseRefusals = maybe [] (pure . CompactionHistoryRetentionActive) conflict
      ledger <- ledgerOutcomeTx manifest
      case ledger of
        LedgerAlreadyApplied record -> pure $ case NE.nonEmpty leaseRefusals of
          Just refusals -> ValidationRefused refusals
          Nothing -> ValidationAlreadyApplied record
        LedgerConflict cid count -> pure (ValidationRefused (CompactionLedgerConflict cid count :| []))
        LedgerUnrecorded -> validateWitnessesTx manifest leaseRefusals

validateWitnessesTx :: CompactionManifest -> [CompactionRefusal] -> Tx.Transaction ValidationOutcome
validateWitnessesTx manifest leaseRefusals = do
  streams <- Tx.statement (manifestStreamNames manifest) SQL.resolveStreamsStmt
  let resolved = Map.fromList [(StreamName name, (sid, ver, deleted)) | (name, sid, ver, deleted) <- V.toList streams]
      allSelections = V.toList (manifestSelections manifest)
      resolvable = filter (\s -> Map.member s.originStream resolved) allSelections
      ids = V.fromList [uid | s <- resolvable, let EventId uid = s.eventId]
      streamRefusals = concatMap (checkStream resolved) (V.toList (manifestStreamHeads manifest))
  rows <- if V.null ids then pure V.empty else Tx.statement ids SQL.eventMembershipsStmt
  let grouped = Map.map reverse (Map.fromListWith (<>) [(EventId uid, [(sid, StreamName name, ver, origin, originVer)]) | (uid, sid, name, ver, origin, originVer) <- V.toList rows])
      knownNames =
        Map.fromList [(sid, StreamName name) | (name, sid, _, _) <- V.toList streams]
          <> Map.fromList [(sid, StreamName name) | (_, sid, name, _, _, _) <- V.toList rows]
      missingOriginIds = Set.toList (Set.fromList [origin | (_, _, _, _, origin, _) <- V.toList rows, Map.notMember origin knownNames])
  extraNames <- if null missingOriginIds then pure V.empty else Tx.statement missingOriginIds StoreSQL.lookupStreamNamesStmt
  -- The causation exclusion must cover the whole manifest, even when another
  -- selected event has an invalid witness. Report policies only for verified rows.
  deadLetters <- Tx.statement (selectedIds manifest) SQL.deadLetterCountsStmt
  dependents <- Tx.statement (selectedIds manifest) SQL.causationDependentCountsStmt
  let names = knownNames <> Map.fromList [(sid, StreamName name) | (sid, name) <- V.toList extraNames]
      deadMap = Map.fromList (V.toList deadLetters)
      dependentMap = Map.fromList (V.toList dependents)
      results = map (checkSelection resolved grouped names deadMap dependentMap) resolvable
      refusals = leaseRefusals <> streamRefusals <> concatMap fst results
      pairs = concatMap snd results
      links = sum [fromIntegral (V.length s.acknowledgedLinks) | s <- allSelections]
      deadCount = if manifestDeadLetterPolicy manifest == RemoveDeadLetters then sum (Map.elems deadMap) else 0
      causeCount = if manifestCausationPolicy manifest == AllowDanglingCausation then sum (Map.elems dependentMap) else 0
  pure $ case NE.nonEmpty refusals of
    Just found -> ValidationRefused found
    Nothing -> ValidationReady (ValidatedCompaction (buildReport manifest links deadCount causeCount) (selectedIds manifest) (V.fromList pairs))
  where
    checkStream resolved h = case Map.lookup h.stream resolved of
      Nothing -> [CompactionStreamMissing h.stream]
      Just (_, ver, deleted) ->
        [CompactionStreamSoftDeleted h.stream | deleted]
          <> [CompactionStreamHeadDrift h.stream h.headVersion (StreamVersion ver) | StreamVersion ver /= h.headVersion]
    checkSelection resolved grouped names deadMap dependentMap s =
      case Map.findWithDefault [] s.eventId grouped of
        [] -> ([CompactionSelectedEventMissing s.eventId], [])
        liveRows@((_, _, _, actualOrigin, actualVersion) : _) ->
          let EventId uid = s.eventId
              originId = maybe (-1) (\(sid, _, _) -> sid) (Map.lookup s.originStream resolved)
              actualName = Map.findWithDefault s.originStream actualOrigin names
              global = fmap (\(_, _, v, _, _) -> GlobalPosition v) (find (\(sid, _, _, _, _) -> sid == 0) liveRows)
              home = find (\(sid, _, _, _, _) -> sid == originId) liveRows
              matchesHome = case home of
                Just (_, _, ver, origin, originVer) -> origin == originId && StreamVersion ver == s.originVersion && StreamVersion originVer == s.originVersion
                Nothing -> False
              originsMatch = all (\(_, _, _, origin, ver) -> origin == originId && StreamVersion ver == s.originVersion) liveRows
              witnesses =
                [ CompactionWitnessMismatch s.eventId (WitnessMismatch actualName (StreamVersion actualVersion) global)
                | not (matchesHome && originsMatch && global == Just s.globalPosition)
                ]
              actualLinks = [(LinkWitness name (StreamVersion ver), sid) | (sid, name, ver, origin, _) <- liveRows, sid /= 0, sid /= origin]
              expectedLinks = V.toList s.acknowledgedLinks
              key (LinkWitness name ver) = (name, ver)
              actualKeys = Set.fromList (map (key . fst) actualLinks)
              expectedKeys = Set.fromList (map key expectedLinks)
              linkRefusals =
                [CompactionUnexpectedLink s.eventId link | (link, _) <- actualLinks, Set.notMember (key link) expectedKeys]
                  <> [CompactionAcknowledgedLinkMissing s.eventId link | link <- expectedLinks, Map.member link.stream resolved, Set.notMember (key link) actualKeys]
              verified = null witnesses && null linkRefusals
              dead = Map.findWithDefault 0 uid deadMap
              cause = Map.findWithDefault 0 uid dependentMap
              referenceRefusals =
                if not verified
                  then []
                  else
                    [CompactionDeadLettersPresent s.eventId dead | dead > 0, manifestDeadLetterPolicy manifest == RefuseDeadLetters]
                      <> [CompactionCausationDependentsPresent s.eventId cause | cause > 0, manifestCausationPolicy manifest == RefuseCausationDependents]
              pairs = if verified then (uid, originId) : (uid, 0) : [(uid, sid) | (_, sid) <- actualLinks] else []
           in (witnesses <> linkRefusals <> referenceRefusals, pairs)

buildReport :: CompactionManifest -> Int64 -> Int64 -> Int64 -> CompactionReport
buildReport manifest links dead cause =
  sealCompactionReport $
    CompactionReport
      digest
      (manifestStoreIdentity manifest)
      (manifestOperation manifest)
      (manifestDeadLetterPolicy manifest)
      (manifestCausationPolicy manifest)
      count
      count
      count
      links
      dead
      cause
      (V.head selections).globalPosition
      (V.last selections).globalPosition
      (manifestStreamHeads manifest)
      digest
  where
    selections = manifestSelections manifest
    count = fromIntegral (V.length selections)
    digest = compactionManifestDigest manifest

previewCompactionTx :: CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionPreview)
previewCompactionTx manifest =
  validateCompactionTx manifest >>= \case
    ValidationRefused refusals -> pure (Left refusals)
    ValidationAlreadyApplied record -> pure (Right (CompactionPreviewAlreadyApplied record))
    ValidationReady validated -> pure (Right (CompactionPreviewReady validated.report))
