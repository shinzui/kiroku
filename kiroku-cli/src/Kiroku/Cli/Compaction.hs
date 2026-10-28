-- | Pure renderers and file loading shared by embeddable operator hosts.
module Kiroku.Cli.Compaction
  ( loadCompactionManifest,
    CompactionCommandError (..),
    renderCompactionReport,
    renderCompactionRefusals,
    renderCompactionRecords,
    renderStoreIdentity,
    renderCompactionCommandError,
    renderCompactionResult,
  )
where

import Control.Exception (IOException, displayException, try)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.Vector (Vector)
import Data.Vector qualified as V
import Kiroku.Cli.Command (ManifestPath (..), OutputFormat (..))
import Kiroku.Store.Compaction.Types
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Types (GlobalPosition (..), StoreIdentity (..), StreamName (..), StreamVersion (..))

data CompactionCommandError
  = ManifestUnreadable FilePath Text
  | ManifestInvalid FilePath Text
  | ConfirmDigestUnparseable Text
  | ConfirmDigestMismatch {typed :: Text, manifest :: Text}
  | LedgerLimitOutOfRange Int32
  | StoreFailure StoreError
  deriving stock (Eq, Show)

loadCompactionManifest :: ManifestPath -> IO (Either CompactionCommandError CompactionManifest)
loadCompactionManifest (ManifestPath path) = do
  readResult <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
  pure $ case readResult of
    Left err -> Left (ManifestUnreadable path (T.pack (displayException err)))
    Right bytes -> case Aeson.eitherDecodeStrict bytes of
      Left err -> Left (ManifestInvalid path (T.pack err))
      Right value -> Right value

json :: (Aeson.ToJSON a) => a -> Text
json = TE.decodeUtf8 . LBS.toStrict . Aeson.encode

shown :: (Show a) => a -> Text
shown = T.pack . show

identityText :: StoreIdentity -> Text
identityText (StoreIdentity uid) = UUID.toText uid

positionText :: GlobalPosition -> Text
positionText (GlobalPosition n) = shown n

policyText :: (Aeson.ToJSON a) => a -> Text
policyText value = case Aeson.toJSON value of
  Aeson.String text -> text
  other -> json other

renderCompactionReport :: OutputFormat -> Maybe CompactionRecord -> CompactionReport -> Text
renderCompactionReport OutputJson Nothing report = json report
renderCompactionReport OutputJson (Just record) _ = json record
renderCompactionReport OutputTable context report =
  maybe "" (\record -> "COMPACTION_ID  " <> compactionIdText (record ^. #compactionId) <> "\n") context
    <> table
      ["FIELD", "VALUE"]
      [ ["MANIFEST_DIGEST", compactionDigestHex (report ^. #manifestDigest)],
        ["STORE_IDENTITY", identityText (report ^. #storeIdentity)],
        ["OPERATION", compactionOperationText (report ^. #operation)],
        ["DEAD_LETTER_POLICY", policyText (report ^. #deadLetterPolicy)],
        ["CAUSATION_POLICY", policyText (report ^. #causationPolicy)],
        ["SELECTED_EVENTS", shown (report ^. #selectedEvents)],
        ["HOME_MEMBERSHIPS", shown (report ^. #homeMemberships)],
        ["GLOBAL_MEMBERSHIPS", shown (report ^. #globalMemberships)],
        ["LINK_MEMBERSHIPS", shown (report ^. #linkMemberships)],
        ["DEAD_LETTERS_REMOVED", shown (report ^. #deadLettersRemoved)],
        ["CAUSATION_DEPENDENTS", shown (report ^. #causationDependents)],
        ["LOWEST_GLOBAL_POSITION", positionText (report ^. #lowestGlobalPosition)],
        ["HIGHEST_GLOBAL_POSITION", positionText (report ^. #highestGlobalPosition)],
        ["REPORT_DIGEST", compactionDigestHex (report ^. #reportDigest)]
      ]
    <> "\nAFFECTED_STREAMS\n"
    <> table
      ["STREAM", "HEAD_VERSION"]
      [[name, shown version] | StreamHeadWitness (StreamName name) (StreamVersion version) <- V.toList (report ^. #affectedStreams)]

renderCompactionRefusals :: OutputFormat -> NonEmpty CompactionRefusal -> Text
renderCompactionRefusals OutputJson refusals = json (NE.toList refusals)
renderCompactionRefusals OutputTable refusals =
  "refused: "
    <> shown (NE.length refusals)
    <> " refusal(s); no rows were changed\n"
    <> table ["KIND", "EVENT_ID", "STREAM", "DETAIL"] (map row (NE.toList refusals))
  where
    row refusal = case Aeson.toJSON refusal of
      Aeson.Object object -> [tag refusal, optional "event_id" object, optional "stream" object, shown refusal]
      _ -> [tag refusal, "", "", shown refusal]
    optional key object = case KeyMap.lookup key object of
      Just (Aeson.String text) -> text
      _ -> ""
    tag = refusalName

refusalName :: CompactionRefusal -> Text
refusalName = \case
  CompactionStoreIdentityMismatch {} -> "CompactionStoreIdentityMismatch"
  CompactionHistoryRetentionActive {} -> "CompactionHistoryRetentionActive"
  CompactionStreamMissing {} -> "CompactionStreamMissing"
  CompactionStreamSoftDeleted {} -> "CompactionStreamSoftDeleted"
  CompactionStreamHeadDrift {} -> "CompactionStreamHeadDrift"
  CompactionSelectedEventMissing {} -> "CompactionSelectedEventMissing"
  CompactionWitnessMismatch {} -> "CompactionWitnessMismatch"
  CompactionUnexpectedLink {} -> "CompactionUnexpectedLink"
  CompactionAcknowledgedLinkMissing {} -> "CompactionAcknowledgedLinkMissing"
  CompactionDeadLettersPresent {} -> "CompactionDeadLettersPresent"
  CompactionCausationDependentsPresent {} -> "CompactionCausationDependentsPresent"
  CompactionLedgerConflict {} -> "CompactionLedgerConflict"

renderCompactionRecords :: OutputFormat -> Vector CompactionRecord -> Text
renderCompactionRecords OutputJson = json
renderCompactionRecords OutputTable = table ["COMPACTION_ID", "APPLIED_AT", "APPLIED_BY", "OPERATION", "SELECTED_EVENTS", "MANIFEST_DIGEST"] . map row . V.toList
  where
    row record =
      [ compactionIdText (record ^. #compactionId),
        shown (record ^. #appliedAt),
        record ^. #appliedBy,
        compactionOperationText (record ^. #report . #operation),
        shown (record ^. #report . #selectedEvents),
        compactionDigestHex (record ^. #report . #manifestDigest)
      ]

compactionIdText :: CompactionId -> Text
compactionIdText (CompactionId uid) = UUID.toText uid

renderStoreIdentity :: OutputFormat -> StoreIdentity -> Text
renderStoreIdentity OutputTable identity = table ["STORE_IDENTITY"] [[identityText identity]]
renderStoreIdentity OutputJson identity = json (Aeson.object ["store_identity" Aeson..= identity])

-- | JSON remains a single valid document; human status prefixes are table-only.
renderCompactionResult :: OutputFormat -> Bool -> CompactionRecord -> Text
renderCompactionResult OutputJson already record = json (Aeson.object ["result" Aeson..= (if already then "already_applied" else "applied" :: Text), "record" Aeson..= record])
renderCompactionResult OutputTable already record =
  (if already then "already applied: " else "applied: ")
    <> compactionIdText (record ^. #compactionId)
    <> " at "
    <> shown (record ^. #appliedAt)
    <> " by "
    <> record ^. #appliedBy
    <> "\n"
    <> renderCompactionReport OutputTable Nothing (record ^. #report)

renderCompactionCommandError :: OutputFormat -> CompactionCommandError -> Text
renderCompactionCommandError OutputJson err = json (Aeson.object ["error" Aeson..= errorText err])
renderCompactionCommandError OutputTable err = "kiroku: " <> errorText err

errorText :: CompactionCommandError -> Text
errorText = \case
  ManifestUnreadable path detail -> "cannot read manifest " <> T.pack path <> ": " <> detail
  ManifestInvalid path detail -> "invalid manifest " <> T.pack path <> ": " <> detail
  ConfirmDigestUnparseable value -> "invalid confirmation digest: " <> value
  ConfirmDigestMismatch typed expected -> "confirmation digest " <> typed <> " does not match manifest " <> expected
  LedgerLimitOutOfRange value -> "ledger limit must be 1–1000; got " <> shown value
  StoreFailure (CompactionConcurrentMutation digest guard) ->
    "compaction " <> compactionDigestHex digest <> ": " <> guard <> "; a concurrent reference appeared mid-apply; nothing was deleted — re-run preview and apply"
  StoreFailure err -> shown err

table :: [Text] -> [[Text]] -> Text
table headers rows = T.intercalate "\n" (map render (headers : rows))
  where
    widths = [maximum (map T.length (header : [row !! i | row <- rows])) | (i, header) <- zip [0 ..] headers]
    render columns = T.stripEnd (T.intercalate "  " (zipWith (\width value -> T.justifyLeft width ' ' value) widths columns))
