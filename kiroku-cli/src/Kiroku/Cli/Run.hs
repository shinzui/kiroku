module Kiroku.Cli.Run
  ( runKirokuCommand,
    runKirokuCommandWithStore,
    renderKirokuCommandWithStore,
    KirokuCommandOutcome (..),
    executeKirokuCommandWithStore,
  )
where

import Control.Monad (when)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Kiroku.Cli.Command
import Kiroku.Cli.Compaction
import Kiroku.Cli.Subscription.Status (renderRemoteSubscriptionStatus, renderSubscriptionStatusRows, subscriptionStatusRows)
import Kiroku.Store (KirokuStore)
import Kiroku.Store.Compaction qualified as Store
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Read (storeIdentity)
import Kiroku.Store.Subscription (subscriptionStates)
import System.Exit (ExitCode (..), exitWith)

data KirokuCommandOutcome = KirokuCommandOutcome {output :: !Text, exitCode :: !ExitCode}
  deriving stock (Eq, Show)

runKirokuCommand :: KirokuCommand -> IO ()
runKirokuCommand KirokuNoCommand = putStrLn "No Kiroku operator command was selected."
runKirokuCommand (KirokuSubscriptions _) = putStrLn storeRequired
runKirokuCommand (KirokuCompaction _) = putStrLn storeRequired
runKirokuCommand (KirokuStore _) = putStrLn storeRequired

storeRequired :: String
storeRequired = "This command needs a live KirokuStore. Use runKirokuCommandWithStore from the embeddable library API."

runKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO ()
runKirokuCommandWithStore store command = do
  KirokuCommandOutcome {output, exitCode} <- executeKirokuCommandWithStore store command
  TIO.putStrLn output
  when (exitCode /= ExitSuccess) (exitWith exitCode)

renderKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO Text
renderKirokuCommandWithStore store command = do
  KirokuCommandOutcome {output} <- executeKirokuCommandWithStore store command
  pure output

-- | Structured execution for hosts. Refusals use exit 2, load/store errors use
-- exit 1, and success/already-applied use exit 0. Legacy status behavior stays
-- compatible, including its rendered remote-fetch errors with exit 0.
executeKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO KirokuCommandOutcome
executeKirokuCommandWithStore _ KirokuNoCommand = pure (success "No Kiroku operator command was selected.")
executeKirokuCommandWithStore store (KirokuSubscriptions (SubscriptionStatus (StatusOptions format endpoint))) =
  success <$> case endpoint of
    Just ep -> renderRemoteSubscriptionStatus ep format
    Nothing -> renderSubscriptionStatusRows format . subscriptionStatusRows <$> subscriptionStates store
executeKirokuCommandWithStore store (KirokuStore (ShowStoreIdentity (IdentityOptions format))) = do
  result <- runStoreIO store storeIdentity
  pure $ either (failure format 1 . StoreFailure) (success . renderStoreIdentity format) result
executeKirokuCommandWithStore store (KirokuCompaction command) = case command of
  CompactionPreview (CompactionOptions path format) -> withManifest path format $ \manifest -> do
    result <- runStoreIO store (Store.previewCompaction manifest)
    pure $ case result of
      Left err -> failure format 1 (StoreFailure err)
      Right (Left refusals) -> KirokuCommandOutcome (renderCompactionRefusals format refusals) (ExitFailure 2)
      Right (Right (Store.CompactionPreviewReady report)) -> success (renderCompactionReport format Nothing report)
      Right (Right (Store.CompactionPreviewAlreadyApplied record)) -> success (renderCompactionResult format True record)
  CompactionApply (ApplyOptions path typedDigest format) -> withManifest path format $ \manifest ->
    case Store.parseCompactionDigestHex typedDigest of
      Nothing -> pure (failure format 1 (ConfirmDigestUnparseable typedDigest))
      Just digest
        | digest /= Store.compactionManifestDigest manifest ->
            pure (failure format 2 (ConfirmDigestMismatch typedDigest (Store.compactionDigestHex (Store.compactionManifestDigest manifest))))
      Just _ -> do
        result <- runStoreIO store (Store.applyCompaction manifest)
        pure $ case result of
          Left err -> failure format 1 (StoreFailure err)
          Right (Left refusals) -> KirokuCommandOutcome (renderCompactionRefusals format refusals) (ExitFailure 2)
          Right (Right (Store.CompactionAppliedNow record)) -> success (renderCompactionResult format False record)
          Right (Right (Store.CompactionAlreadyApplied record)) -> success (renderCompactionResult format True record)
  CompactionLedger (LedgerOptions limit format) -> case Store.mkCompactionLedgerLimit limit of
    Left _ -> pure (failure format 1 (LedgerLimitOutOfRange limit))
    Right validated -> do
      result <- runStoreIO store (Store.compactionLedger (Store.CompactionLedgerQuery validated))
      pure $ either (failure format 1 . StoreFailure) (success . renderCompactionRecords format) result

withManifest :: ManifestPath -> OutputFormat -> (Store.CompactionManifest -> IO KirokuCommandOutcome) -> IO KirokuCommandOutcome
withManifest path format continuation = loadCompactionManifest path >>= either (pure . failure format 1) continuation

success :: Text -> KirokuCommandOutcome
success text = KirokuCommandOutcome text ExitSuccess

failure :: OutputFormat -> Int -> CompactionCommandError -> KirokuCommandOutcome
failure format code err = KirokuCommandOutcome (renderCompactionCommandError format err) (ExitFailure code)
