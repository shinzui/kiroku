{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | Digest-sealed, explicitly witnessed selective compaction inputs and outcomes.
-- Canonical bytes are a versioned cross-language contract, independent of JSON.
module Kiroku.Store.Compaction.Types
  ( CompactionOperation,
    CompactionDigest,
    CompactionId (..),
    LinkWitness (..),
    StreamHeadWitness (..),
    CompactionSelection (..),
    DeadLetterPolicy (..),
    CausationPolicy (..),
    CompactionManifestInput (..),
    CompactionManifestError (..),
    CompactionRefusal (..),
    WitnessMismatch (..),
    CompactionReport (..),
    CompactionRecord (..),
    CompactionPreview (..),
    CompactionApplyResult (..),
    CompactionLedgerLimit,
    CompactionLedgerQuery (..),
    CompactionManifest,
    CompactionLedgerError (..),
    mkCompactionManifest,
    compactionManifestDigest,
    canonicalCompactionManifestBytes,
    maxCompactionSelections,
    mkCompactionOperation,
    compactionOperationText,
    mkCompactionDigest,
    compactionDigestBytes,
    compactionDigestHex,
    parseCompactionDigestHex,
    mkCompactionLedgerLimit,
    compactionLedgerLimitValue,
    sealCompactionReport,
    compactionReportDigest,
    canonicalCompactionReportBytes,
    manifestStoreIdentity,
    manifestOperation,
    manifestDeadLetterPolicy,
    manifestCausationPolicy,
    manifestStreamHeads,
    manifestSelections,
    manifestStreamNames,
  )
where

import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (String), object, withObject, withText, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder
import Data.ByteString.Lazy qualified as LBS
import Data.Char (digitToInt, intToDigit)
import Data.Int (Int32, Int64)
import Data.List (sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Kiroku.Store.HistoryRetention.Types (HistoryRetentionConflict (..))
import Kiroku.Store.Types

newtype CompactionOperation = CompactionOperation Text -- validated 1..512 UTF-8 bytes
  deriving stock (Eq, Ord, Show, Generic)

newtype CompactionDigest = CompactionDigest ByteString -- exactly 32 bytes (SHA-256)
  deriving stock (Eq, Ord, Show, Generic)

newtype CompactionId = CompactionId UUID
  deriving stock (Eq, Ord, Show, Generic)

data LinkWitness = LinkWitness {stream :: !StreamName, streamVersion :: !StreamVersion}
  deriving stock (Eq, Show, Generic)

data StreamHeadWitness = StreamHeadWitness {stream :: !StreamName, headVersion :: !StreamVersion}
  deriving stock (Eq, Show, Generic)

data CompactionSelection = CompactionSelection
  { eventId :: !EventId,
    originStream :: !StreamName,
    originVersion :: !StreamVersion,
    globalPosition :: !GlobalPosition,
    acknowledgedLinks :: !(Vector LinkWitness) -- sorted by (stream, streamVersion), unique
  }
  deriving stock (Eq, Show, Generic)

data DeadLetterPolicy = RefuseDeadLetters | RemoveDeadLetters
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data CausationPolicy = RefuseCausationDependents | AllowDanglingCausation
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data CompactionManifestInput = CompactionManifestInput
  { storeIdentity :: !StoreIdentity,
    operation :: !CompactionOperation,
    deadLetterPolicy :: !DeadLetterPolicy,
    causationPolicy :: !CausationPolicy,
    streamHeads :: ![StreamHeadWitness],
    selections :: ![CompactionSelection],
    expectedDigest :: !(Maybe CompactionDigest)
  }
  deriving stock (Eq, Show, Generic)

data CompactionManifestError
  = CompactionManifestEmpty
  | CompactionManifestTooLarge !Int
  | CompactionManifestDuplicateEvent !EventId
  | CompactionManifestReservedStream !StreamName
  | CompactionManifestInvalidStreamName !StreamName !Int
  | CompactionManifestNonPositiveVersion !EventId
  | CompactionManifestNonPositivePosition !EventId
  | CompactionManifestDuplicatePosition !GlobalPosition
  | CompactionManifestDuplicateOriginVersion !StreamName !StreamVersion
  | CompactionManifestDuplicateLink !EventId !LinkWitness
  | CompactionManifestLinkIntoOrigin !EventId
  | CompactionManifestMissingStreamHead !StreamName
  | CompactionManifestUnusedStreamHead !StreamName
  | CompactionManifestDuplicateStreamHead !StreamName
  | CompactionManifestOperationEmpty
  | CompactionManifestOperationTooLong !Int
  | CompactionManifestDigestMismatch {expected :: !CompactionDigest, computed :: !CompactionDigest}
  deriving stock (Eq, Show, Generic)

data CompactionRefusal
  = CompactionStoreIdentityMismatch {expectedIdentity :: !StoreIdentity, actualIdentity :: !StoreIdentity}
  | CompactionHistoryRetentionActive !HistoryRetentionConflict
  | CompactionStreamMissing !StreamName
  | CompactionStreamSoftDeleted !StreamName
  | CompactionStreamHeadDrift {stream :: !StreamName, expectedHead :: !StreamVersion, actualHead :: !StreamVersion}
  | CompactionSelectedEventMissing !EventId
  | CompactionWitnessMismatch !EventId !WitnessMismatch
  | CompactionUnexpectedLink !EventId !LinkWitness
  | CompactionAcknowledgedLinkMissing !EventId !LinkWitness
  | CompactionDeadLettersPresent !EventId !Int64
  | CompactionCausationDependentsPresent !EventId !Int64
  | CompactionLedgerConflict {compactionId :: !CompactionId, survivingEvents :: !Int64}
  deriving stock (Eq, Show, Generic)

data WitnessMismatch = WitnessMismatch
  { actualOriginStream :: !StreamName,
    actualOriginVersion :: !StreamVersion,
    actualGlobalPosition :: !(Maybe GlobalPosition) -- Nothing when the $all row is gone
  }
  deriving stock (Eq, Show, Generic)

data CompactionReport = CompactionReport
  { manifestDigest :: !CompactionDigest,
    storeIdentity :: !StoreIdentity,
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
    affectedStreams :: !(Vector StreamHeadWitness), -- sorted by stream name
    reportDigest :: !CompactionDigest
  }
  deriving stock (Eq, Show, Generic)

data CompactionRecord = CompactionRecord
  { compactionId :: !CompactionId,
    report :: !CompactionReport,
    appliedAt :: !UTCTime,
    appliedBy :: !Text
  }
  deriving stock (Eq, Show, Generic)

data CompactionPreview
  = CompactionPreviewReady !CompactionReport
  | CompactionPreviewAlreadyApplied !CompactionRecord
  deriving stock (Eq, Show, Generic)

data CompactionApplyResult
  = CompactionAppliedNow !CompactionRecord
  | CompactionAlreadyApplied !CompactionRecord
  deriving stock (Eq, Show, Generic)

newtype CompactionLedgerLimit = CompactionLedgerLimit Int32 -- validated 1..1000
  deriving stock (Eq, Ord, Show, Generic)

data CompactionLedgerQuery = CompactionLedgerQuery {limit :: !CompactionLedgerLimit}
  deriving stock (Eq, Show, Generic)

data CompactionLedgerError = CompactionLedgerLimitOutOfRange !Int32
  deriving stock (Eq, Show, Generic)

data CompactionManifest = CompactionManifest
  { identityValue :: !StoreIdentity,
    operationValue :: !CompactionOperation,
    deadPolicyValue :: !DeadLetterPolicy,
    causationPolicyValue :: !CausationPolicy,
    headValues :: !(Vector StreamHeadWitness),
    selectionValues :: !(Vector CompactionSelection)
  }
  deriving stock (Eq, Show, Generic)

manifestStoreIdentity :: CompactionManifest -> StoreIdentity
manifestStoreIdentity m = m.identityValue

manifestOperation :: CompactionManifest -> CompactionOperation
manifestOperation m = m.operationValue

manifestDeadLetterPolicy :: CompactionManifest -> DeadLetterPolicy
manifestDeadLetterPolicy m = m.deadPolicyValue

manifestCausationPolicy :: CompactionManifest -> CausationPolicy
manifestCausationPolicy m = m.causationPolicyValue

manifestStreamHeads :: CompactionManifest -> Vector StreamHeadWitness
manifestStreamHeads m = m.headValues

manifestSelections :: CompactionManifest -> Vector CompactionSelection
manifestSelections m = m.selectionValues

manifestStreamNames :: CompactionManifest -> Vector Text
manifestStreamNames m = V.map (\h -> let StreamName name = h.stream in name) m.headValues

maxCompactionSelections :: Int
maxCompactionSelections = 100000

mkCompactionOperation :: Text -> Either CompactionManifestError CompactionOperation
mkCompactionOperation value
  | bytes == 0 = Left CompactionManifestOperationEmpty
  | bytes > 512 = Left (CompactionManifestOperationTooLong bytes)
  | otherwise = Right (CompactionOperation value)
  where
    bytes = BS.length (TE.encodeUtf8 value)

compactionOperationText :: CompactionOperation -> Text
compactionOperationText (CompactionOperation t) = t

mkCompactionDigest :: ByteString -> Maybe CompactionDigest
mkCompactionDigest b
  | BS.length b == 32 = Just (CompactionDigest b)
  | otherwise = Nothing

compactionDigestBytes :: CompactionDigest -> ByteString
compactionDigestBytes (CompactionDigest b) = b

compactionDigestHex :: CompactionDigest -> Text
compactionDigestHex (CompactionDigest b) = T.pack (concatMap hex (BS.unpack b))
  where
    hex n = [intToDigit (fromIntegral n `div` 16), intToDigit (fromIntegral n `mod` 16)]

parseCompactionDigestHex :: Text -> Maybe CompactionDigest
parseCompactionDigestHex t
  | T.length t /= 64 || not (T.all (\c -> c `elem` ("0123456789abcdefABCDEF" :: String)) t) = Nothing
  | otherwise = mkCompactionDigest (BS.pack (pairs (T.unpack t)))
  where
    pairs (a : b : rest) = fromIntegral (16 * digitToInt a + digitToInt b) : pairs rest
    pairs _ = []

mkCompactionLedgerLimit :: Int32 -> Either CompactionLedgerError CompactionLedgerLimit
mkCompactionLedgerLimit n
  | n >= 1 && n <= 1000 = Right (CompactionLedgerLimit n)
  | otherwise = Left (CompactionLedgerLimitOutOfRange n)

compactionLedgerLimitValue :: CompactionLedgerLimit -> Int32
compactionLedgerLimitValue (CompactionLedgerLimit n) = n

-- Kept below Store.Error in the import graph: Error consumes the digest type.
-- These are the same reserved-name and UTF-8 length rules as ordinary writes.
validateName :: StreamName -> Either CompactionManifestError ()
validateName name@(StreamName text)
  | text == "$all" = Left (CompactionManifestReservedStream name)
  | bytes > 512 = Left (CompactionManifestInvalidStreamName name bytes)
  | otherwise = Right ()
  where
    bytes = BS.length (TE.encodeUtf8 text)

uniqueBy :: (Ord b) => (a -> b) -> (a -> CompactionManifestError) -> [a] -> Either CompactionManifestError ()
uniqueBy key err = go Set.empty
  where
    go _ [] = Right ()
    go seen (x : xs)
      | Set.member (key x) seen = Left (err x)
      | otherwise = go (Set.insert (key x) seen) xs

mkCompactionManifest :: CompactionManifestInput -> Either CompactionManifestError CompactionManifest
mkCompactionManifest input = do
  let sels = input.selections
      heads = input.streamHeads
      CompactionOperation op = input.operation
  _ <- mkCompactionOperation op
  when (null sels) (Left CompactionManifestEmpty)
  when (length sels > maxCompactionSelections) (Left (CompactionManifestTooLarge (length sels)))
  mapM_ validateSelection sels
  uniqueBy (\s -> s.eventId) (\s -> CompactionManifestDuplicateEvent s.eventId) sels
  uniqueBy (\s -> s.globalPosition) (\s -> CompactionManifestDuplicatePosition s.globalPosition) sels
  uniqueBy (\s -> (s.originStream, s.originVersion)) (\s -> CompactionManifestDuplicateOriginVersion s.originStream s.originVersion) sels
  mapM_ (\h -> validateName h.stream) heads
  uniqueBy (\h -> h.stream) (\h -> CompactionManifestDuplicateStreamHead h.stream) heads
  let touched = Set.fromList (concatMap (\s -> s.originStream : map (\l -> l.stream) (V.toList s.acknowledgedLinks)) sels)
      declared = Set.fromList (map (\h -> h.stream) heads)
  case Set.lookupMin (touched Set.\\ declared) of
    Just name -> Left (CompactionManifestMissingStreamHead name)
    Nothing -> pure ()
  case Set.lookupMin (declared Set.\\ touched) of
    Just name -> Left (CompactionManifestUnusedStreamHead name)
    Nothing -> pure ()
  let canonicalSelection s = s {acknowledgedLinks = V.fromList (sortOn linkKey (V.toList s.acknowledgedLinks))}
      m =
        CompactionManifest
          input.storeIdentity
          input.operation
          input.deadLetterPolicy
          input.causationPolicy
          (V.fromList (sortOn (\h -> nameBytes h.stream) heads))
          (V.fromList (map canonicalSelection (sortOn (\s -> s.globalPosition) sels)))
      computed = compactionManifestDigest m
  case input.expectedDigest of
    Just expected | expected /= computed -> Left (CompactionManifestDigestMismatch expected computed)
    _ -> Right m
  where
    nameBytes (StreamName t) = TE.encodeUtf8 t
    linkKey l = (nameBytes l.stream, l.streamVersion)
    validateSelection s = do
      validateName s.originStream
      let StreamVersion ver = s.originVersion
          GlobalPosition pos = s.globalPosition
      when (ver < 1) (Left (CompactionManifestNonPositiveVersion s.eventId))
      when (pos < 1) (Left (CompactionManifestNonPositivePosition s.eventId))
      mapM_ (validateLink s) s.acknowledgedLinks
      uniqueBy linkKey (CompactionManifestDuplicateLink s.eventId) (V.toList s.acknowledgedLinks)
    validateLink s l = do
      validateName l.stream
      let StreamVersion ver = l.streamVersion
      when (ver < 1) (Left (CompactionManifestNonPositiveVersion s.eventId))
      when (l.stream == s.originStream) (Left (CompactionManifestLinkIntoOrigin s.eventId))

sha256 :: ByteString -> CompactionDigest
sha256 bytes = CompactionDigest (convert (hash bytes :: Digest SHA256))

lengthPrefixed :: Text -> Builder
lengthPrefixed t = let b = TE.encodeUtf8 t in word32BE (fromIntegral (BS.length b)) <> byteString b

uuidBytes :: UUID -> Builder
uuidBytes = lazyByteString . UUID.toByteString

counted :: Vector a -> (a -> Builder) -> Builder
counted values encode = word32BE (fromIntegral (V.length values)) <> foldMap encode values

headBytes :: StreamHeadWitness -> Builder
headBytes (StreamHeadWitness (StreamName name) (StreamVersion ver)) = lengthPrefixed name <> int64BE ver

linkBytes :: LinkWitness -> Builder
linkBytes (LinkWitness (StreamName name) (StreamVersion ver)) = lengthPrefixed name <> int64BE ver

policyBytes :: DeadLetterPolicy -> CausationPolicy -> Builder
policyBytes dead cause = word8 (if dead == RefuseDeadLetters then 0 else 1) <> word8 (if cause == RefuseCausationDependents then 0 else 1)

canonicalCompactionManifestBytes :: CompactionManifest -> ByteString
canonicalCompactionManifestBytes m =
  LBS.toStrict . toLazyByteString $
    byteString "kiroku-compaction-manifest/1\n"
      <> uuidBytes uid
      <> lengthPrefixed (compactionOperationText m.operationValue)
      <> policyBytes m.deadPolicyValue m.causationPolicyValue
      <> counted m.headValues headBytes
      <> counted m.selectionValues selectionBytes
  where
    StoreIdentity uid = m.identityValue
    selectionBytes s =
      let EventId eid = s.eventId
          StreamName name = s.originStream
          StreamVersion ver = s.originVersion
          GlobalPosition pos = s.globalPosition
       in uuidBytes eid <> lengthPrefixed name <> int64BE ver <> int64BE pos <> counted s.acknowledgedLinks linkBytes

compactionManifestDigest :: CompactionManifest -> CompactionDigest
compactionManifestDigest = sha256 . canonicalCompactionManifestBytes

canonicalCompactionReportBytes :: CompactionReport -> ByteString
canonicalCompactionReportBytes r =
  LBS.toStrict . toLazyByteString $
    byteString "kiroku-compaction-report/1\n"
      <> byteString (compactionDigestBytes r.manifestDigest)
      <> uuidBytes uid
      <> lengthPrefixed (compactionOperationText r.operation)
      <> policyBytes r.deadLetterPolicy r.causationPolicy
      <> foldMap
        int64BE
        [ r.selectedEvents,
          r.homeMemberships,
          r.globalMemberships,
          r.linkMemberships,
          r.deadLettersRemoved,
          r.causationDependents,
          lo,
          hi
        ]
      <> counted r.affectedStreams headBytes
  where
    StoreIdentity uid = r.storeIdentity
    GlobalPosition lo = r.lowestGlobalPosition
    GlobalPosition hi = r.highestGlobalPosition

compactionReportDigest :: CompactionReport -> CompactionDigest
compactionReportDigest = sha256 . canonicalCompactionReportBytes

sealCompactionReport :: CompactionReport -> CompactionReport
sealCompactionReport r = r {reportDigest = compactionReportDigest r}

instance ToJSON CompactionId where
  toJSON (CompactionId uid) = toJSON uid

instance FromJSON CompactionId where
  parseJSON value = CompactionId <$> parseJSON value

instance ToJSON CompactionDigest where
  toJSON = toJSON . compactionDigestHex

instance FromJSON CompactionDigest where
  parseJSON = withText "CompactionDigest" $ \t -> maybe (fail "expected a 64-character SHA-256 hex digest") pure (parseCompactionDigestHex t)

instance ToJSON CompactionOperation where
  toJSON = toJSON . compactionOperationText

instance FromJSON CompactionOperation where
  parseJSON = withText "CompactionOperation" $ either (fail . show) pure . mkCompactionOperation

instance ToJSON DeadLetterPolicy where
  toJSON p = String (if p == RefuseDeadLetters then "refuse" else "remove")

instance FromJSON DeadLetterPolicy where
  parseJSON = withText "DeadLetterPolicy" $ \case
    "refuse" -> pure RefuseDeadLetters
    "remove" -> pure RemoveDeadLetters
    _ -> fail "dead_letter_policy must be refuse or remove"

instance ToJSON CausationPolicy where
  toJSON p = String (if p == RefuseCausationDependents then "refuse" else "allow")

instance FromJSON CausationPolicy where
  parseJSON = withText "CausationPolicy" $ \case
    "refuse" -> pure RefuseCausationDependents
    "allow" -> pure AllowDanglingCausation
    _ -> fail "causation_policy must be refuse or allow"

streamText :: StreamName -> Text
streamText (StreamName name) = name

versionInt :: StreamVersion -> Int64
versionInt (StreamVersion ver) = ver

positionInt :: GlobalPosition -> Int64
positionInt (GlobalPosition pos) = pos

eventUuid :: EventId -> UUID
eventUuid (EventId uid) = uid

instance ToJSON LinkWitness where
  toJSON r =
    object
      [ "stream" .= (streamText r.stream),
        "stream_version" .= (versionInt r.streamVersion)
      ]

instance FromJSON LinkWitness where
  parseJSON = withObject "LinkWitness" $ \o ->
    LinkWitness
      <$> (StreamName <$> o .: "stream")
      <*> (StreamVersion <$> o .: "stream_version")

instance ToJSON StreamHeadWitness where
  toJSON r =
    object
      [ "stream" .= (streamText r.stream),
        "head_version" .= (versionInt r.headVersion)
      ]

instance FromJSON StreamHeadWitness where
  parseJSON = withObject "StreamHeadWitness" $ \o ->
    StreamHeadWitness
      <$> (StreamName <$> o .: "stream")
      <*> (StreamVersion <$> o .: "head_version")

instance ToJSON CompactionSelection where
  toJSON r =
    object
      [ "event_id" .= (eventUuid r.eventId),
        "origin_stream" .= (streamText r.originStream),
        "origin_version" .= (versionInt r.originVersion),
        "global_position" .= (positionInt r.globalPosition),
        "acknowledged_links" .= (r.acknowledgedLinks)
      ]

instance FromJSON CompactionSelection where
  parseJSON = withObject "CompactionSelection" $ \o ->
    CompactionSelection
      <$> (EventId <$> o .: "event_id")
      <*> (StreamName <$> o .: "origin_stream")
      <*> (StreamVersion <$> o .: "origin_version")
      <*> (GlobalPosition <$> o .: "global_position")
      <*> o .: "acknowledged_links"

instance ToJSON WitnessMismatch where
  toJSON r =
    object
      [ "actual_origin_stream" .= (streamText r.actualOriginStream),
        "actual_origin_version" .= (versionInt r.actualOriginVersion),
        "actual_global_position" .= (fmap positionInt r.actualGlobalPosition)
      ]

instance FromJSON WitnessMismatch where
  parseJSON = withObject "WitnessMismatch" $ \o ->
    WitnessMismatch
      <$> (StreamName <$> o .: "actual_origin_stream")
      <*> (StreamVersion <$> o .: "actual_origin_version")
      <*> (fmap GlobalPosition <$> o .: "actual_global_position")

instance ToJSON CompactionReport where
  toJSON r =
    object
      [ "manifest_digest" .= (r.manifestDigest),
        "store_identity" .= (r.storeIdentity),
        "operation" .= (r.operation),
        "dead_letter_policy" .= (r.deadLetterPolicy),
        "causation_policy" .= (r.causationPolicy),
        "selected_events" .= (r.selectedEvents),
        "home_memberships" .= (r.homeMemberships),
        "global_memberships" .= (r.globalMemberships),
        "link_memberships" .= (r.linkMemberships),
        "dead_letters_removed" .= (r.deadLettersRemoved),
        "causation_dependents" .= (r.causationDependents),
        "lowest_global_position" .= (positionInt r.lowestGlobalPosition),
        "highest_global_position" .= (positionInt r.highestGlobalPosition),
        "affected_streams" .= (r.affectedStreams),
        "report_digest" .= (r.reportDigest)
      ]

instance FromJSON CompactionReport where
  parseJSON = withObject "CompactionReport" $ \o -> do
    r <-
      CompactionReport
        <$> o .: "manifest_digest"
        <*> o .: "store_identity"
        <*> o .: "operation"
        <*> o .: "dead_letter_policy"
        <*> o .: "causation_policy"
        <*> o .: "selected_events"
        <*> o .: "home_memberships"
        <*> o .: "global_memberships"
        <*> o .: "link_memberships"
        <*> o .: "dead_letters_removed"
        <*> o .: "causation_dependents"
        <*> (GlobalPosition <$> o .: "lowest_global_position")
        <*> (GlobalPosition <$> o .: "highest_global_position")
        <*> o .: "affected_streams"
        <*> o .: "report_digest"
    unless (compactionReportDigest r == r.reportDigest) (fail "compaction report digest mismatch")
    pure r

instance ToJSON CompactionRecord where
  toJSON r =
    object
      [ "compaction_id" .= (r.compactionId),
        "report" .= (r.report),
        "applied_at" .= (r.appliedAt),
        "applied_by" .= (r.appliedBy)
      ]

instance FromJSON CompactionRecord where
  parseJSON = withObject "CompactionRecord" $ \o ->
    CompactionRecord
      <$> o .: "compaction_id"
      <*> o .: "report"
      <*> o .: "applied_at"
      <*> o .: "applied_by"

instance ToJSON CompactionManifest where
  toJSON m =
    object
      [ "format" .= ("kiroku-compaction-manifest/1" :: Text),
        "store_identity" .= manifestStoreIdentity m,
        "operation" .= manifestOperation m,
        "dead_letter_policy" .= manifestDeadLetterPolicy m,
        "causation_policy" .= manifestCausationPolicy m,
        "stream_heads" .= manifestStreamHeads m,
        "selections" .= manifestSelections m,
        "digest" .= compactionManifestDigest m
      ]

instance FromJSON CompactionManifest where
  parseJSON = withObject "CompactionManifest" $ \o -> do
    format <- o .: "format"
    unless (format == ("kiroku-compaction-manifest/1" :: Text)) (fail "unsupported compaction manifest format")
    digest <- o .:? "digest" >>= maybe (fail "compaction manifest requires a digest") pure
    input <-
      CompactionManifestInput
        <$> o .: "store_identity"
        <*> o .: "operation"
        <*> o .: "dead_letter_policy"
        <*> o .: "causation_policy"
        <*> o .: "stream_heads"
        <*> o .: "selections"
        <*> pure (Just digest)
    either (fail . show) pure (mkCompactionManifest input)

instance ToJSON CompactionRefusal where
  toJSON refusal = object $ case refusal of
    CompactionStoreIdentityMismatch expected actual -> tag "store_identity_mismatch" <> ["expected" .= expected, "actual" .= actual]
    CompactionHistoryRetentionActive (HistoryRetentionConflict count expiry) -> tag "history_retention_active" <> ["active_lease_count" .= count, "earliest_expiry" .= expiry]
    CompactionStreamMissing stream -> tag "stream_missing" <> ["stream" .= streamText stream]
    CompactionStreamSoftDeleted stream -> tag "stream_soft_deleted" <> ["stream" .= streamText stream]
    CompactionStreamHeadDrift stream expected actual -> tag "stream_head_drift" <> ["stream" .= streamText stream, "expected" .= versionInt expected, "actual" .= versionInt actual]
    CompactionSelectedEventMissing eid -> tag "selected_event_missing" <> ["event_id" .= eventUuid eid]
    CompactionWitnessMismatch eid witness -> tag "witness_mismatch" <> ["event_id" .= eventUuid eid, "witness" .= witness]
    CompactionUnexpectedLink eid link -> tag "unexpected_link" <> ["event_id" .= eventUuid eid, "link" .= link]
    CompactionAcknowledgedLinkMissing eid link -> tag "acknowledged_link_missing" <> ["event_id" .= eventUuid eid, "link" .= link]
    CompactionDeadLettersPresent eid count -> tag "dead_letters_present" <> ["event_id" .= eventUuid eid, "count" .= count]
    CompactionCausationDependentsPresent eid count -> tag "causation_dependents_present" <> ["event_id" .= eventUuid eid, "count" .= count]
    CompactionLedgerConflict cid count -> tag "ledger_conflict" <> ["compaction_id" .= cid, "surviving_events" .= count]
    where
      tag name = ["refusal" .= (name :: Text)]

instance FromJSON CompactionRefusal where
  parseJSON = withObject "CompactionRefusal" $ \o -> do
    kind <- o .: "refusal" :: Parser Text
    let stream = StreamName <$> o .: "stream"
        eid = EventId <$> o .: "event_id"
    case kind of
      "store_identity_mismatch" -> CompactionStoreIdentityMismatch <$> o .: "expected" <*> o .: "actual"
      "history_retention_active" -> CompactionHistoryRetentionActive <$> (HistoryRetentionConflict <$> o .: "active_lease_count" <*> o .: "earliest_expiry")
      "stream_missing" -> CompactionStreamMissing <$> stream
      "stream_soft_deleted" -> CompactionStreamSoftDeleted <$> stream
      "stream_head_drift" -> CompactionStreamHeadDrift <$> stream <*> (StreamVersion <$> o .: "expected") <*> (StreamVersion <$> o .: "actual")
      "selected_event_missing" -> CompactionSelectedEventMissing <$> eid
      "witness_mismatch" -> CompactionWitnessMismatch <$> eid <*> o .: "witness"
      "unexpected_link" -> CompactionUnexpectedLink <$> eid <*> o .: "link"
      "acknowledged_link_missing" -> CompactionAcknowledgedLinkMissing <$> eid <*> o .: "link"
      "dead_letters_present" -> CompactionDeadLettersPresent <$> eid <*> o .: "count"
      "causation_dependents_present" -> CompactionCausationDependentsPresent <$> eid <*> o .: "count"
      "ledger_conflict" -> CompactionLedgerConflict <$> o .: "compaction_id" <*> o .: "surviving_events"
      _ -> fail "unknown compaction refusal"
