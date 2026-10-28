{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | Maintenance statements, exposed for deterministic query-plan checks.
module Kiroku.Store.Compaction.SQL
  ( resolveStreamsStmt,
    survivingSelectedEventsStmt,
    ledgerRecordByDigestStmt,
    compactionRecordRow,
    ledgerColumns,
    lockCompactionStreamsStmt,
    deleteJunctionRowsStmt,
    deleteSelectedDeadLettersStmt,
    deleteSelectedEventsStmt,
    CompactionRecordInsert (..),
    insertCompactionRecordStmt,
    compactionLedgerStmt,
    eventMembershipsStmt,
    deadLetterCountsStmt,
    causationDependentCountsStmt,
  )
where

import Contravariant.Extras (contrazip2)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Data.Vector (Vector)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Kiroku.Store.Compaction.Types
import Kiroku.Store.SQL (causationDependentCountsStmt, deadLetterCountsStmt, eventMembershipsStmt)
import Kiroku.Store.Types (GlobalPosition (..), StoreIdentity (..))

resolveStreamsStmt :: Statement (Vector Text) (Vector (Text, Int64, Int64, Bool))
resolveStreamsStmt =
  preparable
    """
    SELECT s.stream_name, s.stream_id, s.stream_version, s.deleted_at IS NOT NULL
    FROM unnest($1::text[]) AS requested(stream_name)
    JOIN streams s USING (stream_name)
    """
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
    (D.rowVector ((,,,) <$> col D.text <*> col D.int8 <*> col D.int8 <*> col D.bool))

survivingSelectedEventsStmt :: Statement (Vector UUID) Int64
survivingSelectedEventsStmt =
  preparable
    "SELECT count(*) FROM events WHERE event_id = ANY($1::uuid[])"
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
    (D.singleRow (col D.int8))

ledgerColumns :: Text
ledgerColumns = "compaction_id, manifest_digest, report_digest, store_id, operation, dead_letter_policy, causation_policy, selected_events, home_memberships, global_memberships, link_memberships, dead_letters_removed, causation_dependents, lowest_global_position, highest_global_position, affected_streams, applied_at, applied_by"

ledgerRecordByDigestStmt :: Statement ByteString (Maybe CompactionRecord)
ledgerRecordByDigestStmt =
  preparable
    ("SELECT " <> ledgerColumns <> " FROM event_compactions WHERE manifest_digest = $1")
    (E.param (E.nonNullable E.bytea))
    (D.rowMaybe compactionRecordRow)

-- | Decode the stored report digest verbatim. Audits compare it with the
-- recomputed digest; reading an audit record must not silently reseal it.
compactionRecordRow :: D.Row CompactionRecord
compactionRecordRow = do
  cid <- CompactionId <$> col D.uuid
  md <- col digestValue
  rd <- col digestValue
  identity <- StoreIdentity <$> col D.uuid
  operation <- col (D.refine (either (Left . T.pack . show) Right . mkCompactionOperation) D.text)
  dead <- col (D.refine (\case "refuse" -> Right RefuseDeadLetters; "remove" -> Right RemoveDeadLetters; _ -> Left "invalid dead-letter policy") D.text)
  cause <- col (D.refine (\case "refuse" -> Right RefuseCausationDependents; "allow" -> Right AllowDanglingCausation; _ -> Left "invalid causation policy") D.text)
  selected <- col D.int8
  home <- col D.int8
  global <- col D.int8
  links <- col D.int8
  deadLetters <- col D.int8
  dependents <- col D.int8
  lo <- GlobalPosition <$> col D.int8
  hi <- GlobalPosition <$> col D.int8
  streams <- col (D.refine parseHeads D.jsonb)
  applied <- col D.timestamptz
  actor <- col D.text
  pure (CompactionRecord cid (CompactionReport md identity operation dead cause selected home global links deadLetters dependents lo hi streams rd) applied actor)
  where
    digestValue = D.refine (maybe (Left "invalid SHA-256 byte length") Right . mkCompactionDigest) D.bytea
    parseHeads value = case Aeson.fromJSON value of
      Aeson.Error err -> Left (T.pack err)
      Aeson.Success heads -> Right heads

col :: D.Value a -> D.Row a
col = D.column . D.nonNullable

lockCompactionStreamsStmt :: Statement (Vector Text) (Vector (Text, Int64, Int64, Maybe UTCTime))
lockCompactionStreamsStmt =
  preparable
    "SELECT stream_name,stream_id,stream_version,deleted_at FROM streams WHERE stream_name = ANY($1::text[]) ORDER BY stream_id FOR UPDATE"
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
    (D.rowVector ((,,,) <$> col D.text <*> col D.int8 <*> col D.int8 <*> D.column (D.nullable D.timestamptz)))

deleteJunctionRowsStmt :: Statement (Vector UUID, Vector Int64) (Vector (Int64, Int64))
deleteJunctionRowsStmt =
  preparable
    "DELETE FROM stream_events se USING unnest($1::uuid[], $2::bigint[]) AS k(event_id,stream_id) WHERE se.event_id=k.event_id AND se.stream_id=k.stream_id RETURNING se.stream_id,se.original_stream_id"
    (contrazip2 (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid)))) (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.int8)))))
    (D.rowVector ((,) <$> col D.int8 <*> col D.int8))

deleteSelectedDeadLettersStmt :: Statement (Vector UUID) Int64
deleteSelectedDeadLettersStmt =
  preparable
    "WITH removed AS (DELETE FROM dead_letters WHERE event_id=ANY($1::uuid[]) RETURNING 1) SELECT count(*) FROM removed"
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
    (D.singleRow (col D.int8))

deleteSelectedEventsStmt :: Statement (Vector UUID) Int64
deleteSelectedEventsStmt =
  preparable
    "WITH removed AS (DELETE FROM events WHERE event_id=ANY($1::uuid[]) RETURNING 1) SELECT count(*) FROM removed"
    (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
    (D.singleRow (col D.int8))

compactionLedgerStmt :: Statement Int32 (Vector CompactionRecord)
compactionLedgerStmt =
  preparable
    ("SELECT " <> ledgerColumns <> " FROM event_compactions ORDER BY applied_at DESC,compaction_id LIMIT $1")
    (E.param (E.nonNullable E.int4))
    (D.rowVector compactionRecordRow)

data CompactionRecordInsert = CompactionRecordInsert
  { manifestDigest :: !CompactionDigest,
    reportDigest :: !CompactionDigest,
    storeId :: !StoreIdentity,
    operation :: !CompactionOperation,
    deadLetterPolicy :: !DeadLetterPolicy,
    causationPolicy :: !CausationPolicy,
    selectedEvents :: !Int64,
    homeMemberships :: !Int64,
    globalMemberships :: !Int64,
    linkMemberships :: !Int64,
    deadLettersRemoved :: !Int64,
    causationDependents :: !Int64,
    lowestGlobalPosition :: !GlobalPosition,
    highestGlobalPosition :: !GlobalPosition,
    affectedStreams :: !(Vector StreamHeadWitness)
  }
  deriving stock (Eq, Show, Generic)

insertCompactionRecordStmt :: Statement CompactionRecordInsert (UUID, UTCTime, Text)
insertCompactionRecordStmt =
  preparable
    """
    INSERT INTO event_compactions (manifest_digest,report_digest,store_id,operation,
      dead_letter_policy,causation_policy,selected_events,home_memberships,
      global_memberships,link_memberships,dead_letters_removed,causation_dependents,
      lowest_global_position,highest_global_position,affected_streams)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
    RETURNING compaction_id,applied_at,applied_by
    """
    ( ((\r -> compactionDigestBytes r.manifestDigest) >$< E.param (E.nonNullable E.bytea))
        <> ((\r -> compactionDigestBytes r.reportDigest) >$< E.param (E.nonNullable E.bytea))
        <> ((\r -> let StoreIdentity uid = r.storeId in uid) >$< E.param (E.nonNullable E.uuid))
        <> ((\r -> compactionOperationText r.operation) >$< E.param (E.nonNullable E.text))
        <> ((\r -> if r.deadLetterPolicy == RefuseDeadLetters then "refuse" else "remove") >$< E.param (E.nonNullable E.text))
        <> ((\r -> if r.causationPolicy == RefuseCausationDependents then "refuse" else "allow") >$< E.param (E.nonNullable E.text))
        <> ((\r -> r.selectedEvents) >$< E.param (E.nonNullable E.int8))
        <> ((\r -> r.homeMemberships) >$< E.param (E.nonNullable E.int8))
        <> ((\r -> r.globalMemberships) >$< E.param (E.nonNullable E.int8))
        <> ((\r -> r.linkMemberships) >$< E.param (E.nonNullable E.int8))
        <> ((\r -> r.deadLettersRemoved) >$< E.param (E.nonNullable E.int8))
        <> ((\r -> r.causationDependents) >$< E.param (E.nonNullable E.int8))
        <> ((\r -> let GlobalPosition n = r.lowestGlobalPosition in n) >$< E.param (E.nonNullable E.int8))
        <> ((\r -> let GlobalPosition n = r.highestGlobalPosition in n) >$< E.param (E.nonNullable E.int8))
        <> ((\r -> Aeson.toJSON r.affectedStreams) >$< E.param (E.nonNullable E.jsonb))
    )
    (D.singleRow ((,,) <$> col D.uuid <*> col D.timestamptz <*> col D.text))
