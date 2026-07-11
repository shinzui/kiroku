{-# LANGUAGE TemplateHaskell #-}

module Kiroku.Store.Migrations.History.Codd (
    kirokuCoddHistoryMappings,
    kirokuCoddManifestText,
    kirokuCoddSourceConfig,
    kirokuCoddSourcePayloads,
    kirokuLegacyMigrationNames,
) where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Database.PostgreSQL.Migrate (
    Confirmation,
    ConnectionProvider,
    EvidenceRequirement (Evidence),
    HistoryMapping,
    PayloadRelation (SamePayload),
    historyMapping,
    migrationId,
 )
import Database.PostgreSQL.Migrate.History.Codd (
    CoddDefinitionError,
    CoddSourceConfig,
    coddEvidenceKey,
    coddSourceConfig,
    parseCoddManifest,
 )
import Kiroku.Store.Migrations.Internal.Definition (embeddedMigrationEntries)
import Kiroku.Store.Migrations.Internal.EmbedFile (embedTextFile)

kirokuLegacyMigrationNames :: NonEmpty FilePath
kirokuLegacyMigrationNames =
    "2026-05-16-12-17-14-kiroku-bootstrap.sql"
        :| [ "2026-05-29-15-26-04-add-subscription-dead-letters.sql"
           , "2026-06-14-13-17-09-notify-trigger-append-guard.sql"
           , "2026-06-14-13-25-40-dead-letters-event-id-index.sql"
           , "2026-06-14-13-54-48-index-hygiene-and-streams-fillfactor.sql"
           , "2026-06-14-14-01-17-stream-name-length-check.sql"
           , "2026-06-24-09-42-22-stream-truncate-before.sql"
           ]

kirokuCoddHistoryMappings :: NonEmpty HistoryMapping
kirokuCoddHistoryMappings =
    zipWithNonEmpty mapping kirokuLegacyMigrationNames nativeMigrationNames
  where
    mapping sourceFilename targetName =
        historyMapping
            (definitionInvariant (migrationId "kiroku" targetName))
            (Evidence sourceKey)
            (SamePayload sourceKey)
      where
        sourceKey = definitionInvariant (first show (coddEvidenceKey sourceFilename))

kirokuCoddSourceConfig ::
    ConnectionProvider ->
    Bool ->
    Text ->
    Confirmation ->
    Either CoddDefinitionError CoddSourceConfig
kirokuCoddSourceConfig sourceProvider strictSource reason confirmation =
    coddSourceConfig
        sourceProvider
        kirokuLegacyMigrationNames
        strictSource
        kirokuCoddSourcePayloads
        (Just (definitionInvariant (parseCoddManifest kirokuCoddManifestText)))
        reason
        confirmation

nativeMigrationNames :: NonEmpty Text
nativeMigrationNames =
    "0001-kiroku-bootstrap"
        :| [ "0002-add-subscription-dead-letters"
           , "0003-notify-trigger-append-guard"
           , "0004-dead-letters-event-id-index"
           , "0005-index-hygiene-and-streams-fillfactor"
           , "0006-stream-name-length-check"
           , "0007-stream-truncate-before"
           ]

kirokuCoddSourcePayloads :: Map.Map FilePath ByteString
kirokuCoddSourcePayloads =
    Map.fromList
        (zip (toList kirokuLegacyMigrationNames) (snd <$> toList embeddedMigrationEntries))

kirokuCoddManifestText :: Text
kirokuCoddManifestText = $(embedTextFile "migrations.lock")

zipWithNonEmpty :: (a -> b -> c) -> NonEmpty a -> NonEmpty b -> NonEmpty c
zipWithNonEmpty combine (firstA :| restA) (firstB :| restB) =
    combine firstA firstB :| zipWith combine restA restB

definitionInvariant :: (Show error) => Either error value -> value
definitionInvariant = either (error . ("invalid checked-in Kiroku migration definition: " <>) . show) id
