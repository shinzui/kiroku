module Main (main) where

import Control.Monad (unless)
import Data.Aeson (object)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import Database.PostgreSQL.Migrate (defaultRunOptions, runMigrationPlan)
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Conn
import Kiroku.Store
import Kiroku.Store.Migrations (kirokuMigrationPlan)
import System.Timeout (timeout)

main :: IO ()
main = do
  result <- timeout 120_000_000 $ Pg.withCached $ \db -> do
    plan <- either (fail . show) pure kirokuMigrationPlan
    migrated <- runMigrationPlan defaultRunOptions (Conn.connectionString (Pg.connectionString db)) plan
    _ <- must migrated
    withStore (defaultConnectionSettings (Pg.connectionString db)) prove
  case result of
    Just (Right ()) -> putStrLn "disposable PostgreSQL stopped cleanly"
    Just (Left err) -> fail (show err)
    Nothing -> fail "consumer database execution exceeded 120 seconds"

prove :: KirokuStore -> IO ()
prove store = do
  let name = StreamName "consumer-proof"
  _ <- must =<< runStoreIO store (appendToStream name NoStream [sample "One", sample "Two", sample "Three"])
  events <- must =<< runStoreIO store (readStreamForward name (StreamVersion 0) 10)
  unless (V.length events == 3) (fail "expected three original events")
  let middle = events V.! 1
  identity <- must =<< runStoreIO store storeIdentity
  references <- must =<< runStoreIO store (lookupEventReferences [middle.eventId])
  position <- case Map.lookup middle.eventId references of
    Just inventory -> case [p | GlobalMembership p <- V.toList inventory.memberships] of
      [p] -> pure p
      other -> fail ("unexpected global memberships: " <> show other)
    Nothing -> fail "selected event missing from reference inventory"
  operation <- must (mkCompactionOperation "clean-consumer/proof")
  manifest <-
    must $
      mkCompactionManifest $
        CompactionManifestInput
          identity
          operation
          RefuseDeadLetters
          RefuseCausationDependents
          [StreamHeadWitness name (StreamVersion 3)]
          [CompactionSelection middle.eventId name middle.streamVersion position V.empty]
          Nothing
  preview <- must =<< runStoreIO store (previewCompaction manifest)
  report <- case preview of
    Right (CompactionPreviewReady report) -> pure report
    other -> fail ("unexpected preview: " <> show other)
  applied <- must =<< runStoreIO store (applyCompaction manifest)
  record <- case applied of
    Right (CompactionAppliedNow record) -> pure record
    other -> fail ("unexpected apply: " <> show other)
  reapplied <- must =<< runStoreIO store (applyCompaction manifest)
  case reapplied of
    Right (CompactionAlreadyApplied same) | same == record -> pure ()
    other -> fail ("unexpected reapply: " <> show other)
  limit <- must (mkCompactionLedgerLimit 50)
  ledger <- must =<< runStoreIO store (compactionLedger (CompactionLedgerQuery limit))
  unless (ledger == V.singleton record) (fail "ledger differs from apply record")
  survivors <- must =<< runStoreIO store (readStreamForward name (StreamVersion 0) 10)
  unless (survivors == V.filter (\e -> e.eventId /= middle.eventId) events) (fail "retained envelopes changed")
  headInfo <- must =<< runStoreIO store (getStream name)
  unless (fmap (\info -> info.version) headInfo == Just (StreamVersion 3)) (fail "stream head changed")
  appended <- must =<< runStoreIO store (appendToStream name (ExactVersion (StreamVersion 3)) [sample "Four"])
  unless (appended.streamVersion == StreamVersion 4 && report.selectedEvents == 1) (fail "append/count mismatch")
  putStrLn $
    "clean consumer verified: kiroku-store 0.13.0.0, kiroku-store-migrations 0.7.3.0, store "
      <> show identity
      <> ", manifest "
      <> show (compactionDigestHex (compactionManifestDigest manifest))
      <> ", selected 1, applied "
      <> show record.compactionId
      <> ", surviving versions [1,3], appended at version 4"

must :: (Show e) => Either e a -> IO a
must = either (fail . show) pure

sample :: Text -> EventData
sample name = EventData Nothing (EventType name) (object []) Nothing Nothing Nothing
