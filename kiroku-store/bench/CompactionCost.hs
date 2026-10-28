{-# LANGUAGE OverloadedRecordDot #-}

-- A bounded maintenance-path sizing probe, not a statistical regression gate.
module Main (main) where

import Control.Lens ((^.))
import Control.Monad (forM_, unless)
import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Vector qualified as V
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store hiding (id)
import Kiroku.Test.Postgres (withMigratedTestDatabase, withSharedMigratedPostgres)
import Text.Printf (printf)

main :: IO ()
main = withSharedMigratedPostgres $ do
  putStrLn "selections,link_memberships,dead_letters,apply_wall_seconds,coordinator_hold_upper_bound_seconds,microseconds_per_selection,report_digest"
  forM_ [10000, 50000, 100000 :: Int] $ \size ->
    withMigratedTestDatabase $ \conn -> withStore (defaultConnectionSettings conn) $ \store -> do
      let origin = StreamName "cost-origin"
          target = StreamName "cost-links"
      forM_ [0, 2500 .. size - 1] $ \offset -> do
        let events =
              [ EventData
                  Nothing
                  (EventType "CompactionCost")
                  (object ["ordinal" .= n, "payload" .= T.replicate 256 "x"])
                  Nothing
                  Nothing
                  Nothing
              | n <- [offset + 1 .. min size (offset + 2500)]
              ]
        _ <- require =<< runStoreIO store (appendToStream origin AnyVersion events)
        pure ()
      events <- require =<< runStoreIO store (readAllForward (GlobalPosition 0) (fromIntegral size))
      let linked = V.filter (\e -> let GlobalPosition p = e.globalPosition in p `mod` 10 == 0) events
      _ <- require =<< runStoreIO store (linkToStream target (map (\e -> e.eventId) (V.toList linked)))
      require
        =<< Pool.use
          (store ^. #pool)
          ( Session.script
              "INSERT INTO dead_letters(subscription_name,consumer_group_member,global_position,event_id,reason,reason_summary,attempt_count) SELECT 'cost',0,stream_version,event_id,'{}'::jsonb,'cost fixture',1 FROM stream_events WHERE stream_id=0 AND stream_version % 10=0"
          )
      identity <- require =<< runStoreIO store storeIdentity
      op <- either (fail . show) pure (mkCompactionOperation ("cost-" <> T.pack (show size)))
      let selections =
            [ CompactionSelection
                e.eventId
                origin
                e.originalVersion
                e.globalPosition
                (let GlobalPosition pos = e.globalPosition in if pos `mod` 10 == 0 then V.singleton (LinkWitness target (StreamVersion (pos `div` 10))) else V.empty)
            | e <- V.toList events
            ]
          heads = [StreamHeadWitness origin (StreamVersion (fromIntegral size)), StreamHeadWitness target (StreamVersion (fromIntegral (size `div` 10)))]
      manifest <- either (fail . show) pure (mkCompactionManifest (CompactionManifestInput identity op RemoveDeadLetters RefuseCausationDependents heads selections Nothing))
      start <- getMonotonicTimeNSec
      result <- require =<< runStoreIO store (applyCompaction manifest)
      end <- getMonotonicTimeNSec
      record <- case result of
        Right (CompactionAppliedNow value) -> pure value
        other -> fail (show other)
      let seconds = fromIntegral (end - start) / 1e9 :: Double
          report = record.report
      unless (report.selectedEvents == fromIntegral size && report.linkMemberships == fromIntegral (size `div` 10) && report.deadLettersRemoved == fromIntegral (size `div` 10)) (fail "count mismatch")
      ledger <- require =<< runStoreIO store (compactionLedger (CompactionLedgerQuery (either (error . show) id (mkCompactionLedgerLimit 10))))
      unless (ledger == V.singleton record && report.reportDigest == compactionReportDigest report) (fail "ledger mismatch")
      repeated <- require =<< runStoreIO store (applyCompaction manifest)
      unless (repeated == Right (CompactionAlreadyApplied record)) (fail "reapply mismatch")
      printf "%d,%d,%d,%.6f,%.6f,%.3f,%s\n" size (size `div` 10) (size `div` 10) seconds seconds (seconds * 1e6 / fromIntegral size) (T.unpack (compactionDigestHex report.reportDigest))

require :: (Show e) => Either e a -> IO a
require = either (fail . show) pure
