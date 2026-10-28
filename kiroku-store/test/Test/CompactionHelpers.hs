{-# LANGUAGE OverloadedRecordDot #-}

module Test.CompactionHelpers (seed, inputFor, manifest, ledgerQuery, raw, storeRead, readyReport) where

import Control.Lens ((^.))
import Control.Monad (forM)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store hiding (id)
import Test.Helpers (makeEvent)

seed :: KirokuStore -> StreamName -> Int -> IO [RecordedEvent]
seed store name count = do
  _ <- storeRead =<< runStoreIO store (appendToStream name AnyVersion [makeEvent "CompactionFixture" (Aeson.object ["ordinal" Aeson..= n]) | n <- [1 .. count]])
  Just sid <- storeRead =<< runStoreIO store (lookupStreamId name)
  events <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 0) 1000000)
  pure (filter (\event -> event.originalStreamId == sid) (V.toList events))

inputFor :: KirokuStore -> [RecordedEvent] -> IO CompactionManifestInput
inputFor store events = do
  identity <- storeRead =<< runStoreIO store storeIdentity
  references <- storeRead =<< runStoreIO store (lookupEventReferences (map (\e -> e.eventId) events))
  selections <- forM events $ \event -> do
    let inventory = references Map.! event.eventId
        [HomeMembership name _ version] = [home | home@HomeMembership {} <- V.toList inventory.memberships]
        [GlobalMembership position] = [global | global@GlobalMembership {} <- V.toList inventory.memberships]
        links = V.fromList [LinkWitness target version | LinkMembership target _ version <- V.toList inventory.memberships]
    pure (CompactionSelection event.eventId name version position links)
  let names = Set.toList (Set.fromList (concatMap (\s -> s.originStream : map (\l -> l.stream) (V.toList s.acknowledgedLinks)) selections))
  heads <- forM names $ \name -> do
    Just stream <- storeRead =<< runStoreIO store (getStream name)
    pure (StreamHeadWitness name (stream ^. #version))
  operation <- either (fail . show) pure (mkCompactionOperation "test-compaction")
  pure (CompactionManifestInput identity operation RefuseDeadLetters RefuseCausationDependents heads selections Nothing)

manifest :: CompactionManifestInput -> CompactionManifest
manifest = either (error . show) id . mkCompactionManifest

ledgerQuery :: Int32 -> CompactionLedgerQuery
ledgerQuery = CompactionLedgerQuery . either (error . show) id . mkCompactionLedgerLimit

raw :: KirokuStore -> Text -> IO ()
raw store sql = storeRead =<< Pool.use (store ^. #pool) (Session.script sql)

storeRead :: (Show e) => Either e a -> IO a
storeRead = either (fail . show) pure

readyReport :: KirokuStore -> CompactionManifest -> IO CompactionReport
readyReport store m = do
  Right (CompactionPreviewReady report) <- storeRead =<< runStoreIO store (previewCompaction m)
  pure report
