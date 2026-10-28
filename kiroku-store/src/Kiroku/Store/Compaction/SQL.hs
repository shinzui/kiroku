{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE MultilineStrings #-}

-- | Maintenance statements, exposed for deterministic query-plan checks.
module Kiroku.Store.Compaction.SQL
  ( resolveStreamsStmt,
    survivingSelectedEventsStmt,
    ledgerRecordByDigestStmt,
    compactionRecordRow,
    ledgerColumns,
    eventMembershipsStmt,
    deadLetterCountsStmt,
    causationDependentCountsStmt,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Data.Vector (Vector)
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
