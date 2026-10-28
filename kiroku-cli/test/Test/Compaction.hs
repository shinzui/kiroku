module Test.Compaction (spec) where

import Control.Concurrent (myThreadId)
import Control.Exception (try)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_, when)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Kiroku.Cli.Command qualified as C
import Kiroku.Cli.Compaction
import Kiroku.Cli.Parser
import Kiroku.Cli.Run
import Kiroku.Cli.Standalone
import Kiroku.Store hiding (id)
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import Options.Applicative qualified as Options
import System.Exit (ExitCode (..))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "compaction CLI" $ do
  it "parses all maintenance commands and requires explicit apply confirmation" $ do
    let cases =
          [ (["compaction", "preview", "--manifest", "m.json"], C.KirokuCompaction (C.CompactionPreview (C.CompactionOptions (C.ManifestPath "m.json") C.OutputTable))),
            (["compaction", "apply", "--manifest", "m.json", "--confirm-digest", "ab12", "--format", "json"], C.KirokuCompaction (C.CompactionApply (C.ApplyOptions (C.ManifestPath "m.json") "ab12" C.OutputJson))),
            (["compaction", "ledger"], C.KirokuCompaction (C.CompactionLedger (C.LedgerOptions 50 C.OutputTable))),
            (["compaction", "ledger", "--limit", "5"], C.KirokuCompaction (C.CompactionLedger (C.LedgerOptions 5 C.OutputTable))),
            (["store", "identity"], C.KirokuStore (C.ShowStoreIdentity (C.IdentityOptions C.OutputTable)))
          ]
    forM_ cases $ \(args, expected) -> case Options.execParserPure Options.defaultPrefs kirokuParserInfo args of
      Options.Success actual -> actual `shouldBe` expected
      _ -> expectationFailure ("could not parse " <> show args)
    Options.execParserPure Options.defaultPrefs kirokuParserInfo ["compaction", "apply", "--manifest", "m.json"] `shouldSatisfy` \case Options.Failure _ -> True; _ -> False

  it "embeds the same compaction command under an unrelated host parser" $ do
    let parser = Options.info (Options.subparser (kirokuSubparser Just)) Options.fullDesc
    case Options.execParserPure Options.defaultPrefs parser ["kiroku", "compaction", "preview", "--manifest", "m.json"] of
      Options.Success actual -> actual `shouldBe` Just (previewCommand "m.json" C.OutputTable)
      _ -> expectationFailure "nested compaction parser failed"

  it "refuses compaction and identity in the standalone remote client" $ do
    let commands = [previewCommand "m.json" C.OutputTable, C.KirokuCompaction (C.CompactionLedger (C.LedgerOptions 50 C.OutputTable)), C.KirokuStore (C.ShowStoreIdentity (C.IdentityOptions C.OutputTable))]
    forM_ commands $ \command -> case resolveStandaloneOptions [] (StandaloneOptions command) of
      Left message -> message `shouldBe` embeddableMessage
      Right _ -> expectationFailure "standalone accepted a store-owned maintenance command"

  it "returns typed file errors and detects corrupted manifest digests before store access" $
    withSystemTempDirectory "kiroku-manifest" $ \directory -> do
      let path = directory <> "/manifest.json"
      missing <- loadCompactionManifest (C.ManifestPath path)
      missing `shouldSatisfy` \case Left (ManifestUnreadable _ _) -> True; _ -> False
      TIO.writeFile path "not JSON"
      invalid <- loadCompactionManifest (C.ManifestPath path)
      invalid `shouldSatisfy` \case Left (ManifestInvalid _ _) -> True; _ -> False
      let Aeson.Object object = Aeson.toJSON sampleManifest
      Aeson.encodeFile path (Aeson.Object (KM.insert "digest" (Aeson.String (T.replicate 64 "0")) object))
      damaged <- loadCompactionManifest (C.ManifestPath path)
      damaged `shouldSatisfy` \case Left (ManifestInvalid _ message) -> T.isInfixOf "CompactionManifestDigestMismatch" message; _ -> False

  it "renders stable empty-ledger, identity and refusal tables and valid JSON" $ do
    renderCompactionRecords C.OutputTable V.empty `shouldBe` "COMPACTION_ID  APPLIED_AT  APPLIED_BY  OPERATION  SELECTED_EVENTS  MANIFEST_DIGEST"
    renderStoreIdentity C.OutputTable (StoreIdentity UUID.nil) `shouldBe` "STORE_IDENTITY\n00000000-0000-0000-0000-000000000000"
    renderStoreIdentity C.OutputJson (StoreIdentity UUID.nil) `shouldBe` "{\"store_identity\":\"00000000-0000-0000-0000-000000000000\"}"
    let refusals = CompactionSelectedEventMissing (EventId UUID.nil) :| []
        table = renderCompactionRefusals C.OutputTable refusals
    table `shouldSatisfy` T.isPrefixOf "refused: 1 refusal(s); no rows were changed\nKIND"
    table `shouldSatisfy` T.isInfixOf "CompactionSelectedEventMissing"
    validJSON (renderCompactionRefusals C.OutputJson refusals)
    validJSON (renderCompactionRecords C.OutputJson V.empty)
    let digest = compactionManifestDigest sampleManifest
    renderCompactionCommandError C.OutputTable (StoreFailure (CompactionConcurrentMutation digest "dead-letter count")) `shouldSatisfy` T.isInfixOf "re-run preview and apply"

  it "executes preview, confirmed apply, no-op reapply, ledger and identity against a live store" $
    withSystemTempDirectory "kiroku-live-manifest" $ \directory -> withTestStore $ \store -> do
      let path = directory <> "/manifest.json"
          driftPath = directory <> "/drift.json"
      input <- liveInput store
      let Right m = mkCompactionManifest input
          Right drift = mkCompactionManifest (input & #streamHeads .~ [StreamHeadWitness (StreamName "orders-cli") (StreamVersion 4)])
          digest = compactionDigestHex (compactionManifestDigest m)
      Aeson.encodeFile path m
      Aeson.encodeFile driftPath drift
      identity <- executeKirokuCommandWithStore store (C.KirokuStore (C.ShowStoreIdentity (C.IdentityOptions C.OutputJson)))
      assertOutcome ExitSuccess "store_identity" identity
      assertJSON identity
      ready <- executeKirokuCommandWithStore store (previewCommand path C.OutputTable)
      assertOutcome ExitSuccess "SELECTED_EVENTS" ready
      readyJSON <- executeKirokuCommandWithStore store (previewCommand path C.OutputJson)
      assertOutcome ExitSuccess "selected_events" readyJSON
      assertJSON readyJSON
      refusedJSON <- executeKirokuCommandWithStore store (previewCommand driftPath C.OutputJson)
      assertOutcome (ExitFailure 2) "stream_head_drift" refusedJSON
      assertJSON refusedJSON
      refused <- executeKirokuCommandWithStore store (previewCommand driftPath C.OutputTable)
      assertOutcome (ExitFailure 2) "CompactionStreamHeadDrift" refused
      exit <- try (runKirokuCommandWithStore store (previewCommand driftPath C.OutputTable)) :: IO (Either ExitCode ())
      exit `shouldBe` Left (ExitFailure 2)
      denied <- executeKirokuCommandWithStore store (applyCommand path (T.replicate 64 "0") C.OutputTable)
      assertOutcome (ExitFailure 2) "does not match" denied
      eventsBefore <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 0) 100)
      V.length eventsBefore `shouldBe` 3
      first <- executeKirokuCommandWithStore store (applyCommand path digest C.OutputTable)
      assertOutcome ExitSuccess "applied:" first
      again <- executeKirokuCommandWithStore store (applyCommand path digest C.OutputTable)
      assertOutcome ExitSuccess "already applied:" again
      previewed <- executeKirokuCommandWithStore store (previewCommand path C.OutputTable)
      assertOutcome ExitSuccess "already applied:" previewed
      forM_ [applyCommand path digest C.OutputJson, previewCommand path C.OutputJson, C.KirokuCompaction (C.CompactionLedger (C.LedgerOptions 10 C.OutputJson))] $ \command -> do
        result <- executeKirokuCommandWithStore store command
        assertOutcome ExitSuccess "" result
        assertJSON result
      eventsAfter <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 0) 100)
      map (\e -> e ^. #originalVersion) (V.toList eventsAfter) `shouldBe` [StreamVersion 1, StreamVersion 3]
      records <- storeRead =<< runStoreIO store (compactionLedger (CompactionLedgerQuery (either (error . show) id (mkCompactionLedgerLimit 10))))
      V.length records `shouldBe` 1
      ledger <- executeKirokuCommandWithStore store (C.KirokuCompaction (C.CompactionLedger (C.LedgerOptions 10 C.OutputTable)))
      assertOutcome ExitSuccess "MANIFEST_DIGEST" ledger

  it "rejects confirmation errors and invalid limits without any caller pool checkout" $
    withSystemTempDirectory "kiroku-confirm-manifest" $ \directory -> do
      calls <- newIORef (0 :: Int)
      owner <- myThreadId
      withMigratedTestDatabase $ \conn -> do
        let settings =
              (defaultConnectionSettings conn)
                { observationHandler = Just $ \case
                    ConnectionObservation _ InUseConnectionStatus -> do current <- myThreadId; when (current == owner) (modifyIORef' calls (+ 1))
                    _ -> pure ()
                }
        withStore settings $ \store -> do
          let path = directory <> "/manifest.json"
          Aeson.encodeFile path sampleManifest
          initialCalls <- readIORef calls
          mismatch <- executeKirokuCommandWithStore store (applyCommand path (T.replicate 64 "0") C.OutputJson)
          assertOutcome (ExitFailure 2) "does not match" mismatch
          assertJSON mismatch
          unparseable <- executeKirokuCommandWithStore store (applyCommand path "invalid" C.OutputTable)
          assertOutcome (ExitFailure 1) "invalid confirmation" unparseable
          invalidLimit <- executeKirokuCommandWithStore store (C.KirokuCompaction (C.CompactionLedger (C.LedgerOptions 0 C.OutputJson)))
          assertOutcome (ExitFailure 1) "ledger limit" invalidLimit
          unreadable <- executeKirokuCommandWithStore store (previewCommand (directory <> "/missing") C.OutputJson)
          assertOutcome (ExitFailure 1) "cannot read manifest" unreadable
          assertJSON unreadable
          readIORef calls `shouldReturn` initialCalls

previewCommand :: FilePath -> C.OutputFormat -> C.KirokuCommand
previewCommand path format = C.KirokuCompaction (C.CompactionPreview (C.CompactionOptions (C.ManifestPath path) format))

applyCommand :: FilePath -> Text -> C.OutputFormat -> C.KirokuCommand
applyCommand path digest format = C.KirokuCompaction (C.CompactionApply (C.ApplyOptions (C.ManifestPath path) digest format))

assertOutcome :: ExitCode -> Text -> KirokuCommandOutcome -> Expectation
assertOutcome expected needle (KirokuCommandOutcome output actual) = do
  actual `shouldBe` expected
  output `shouldSatisfy` T.isInfixOf needle

assertJSON :: KirokuCommandOutcome -> Expectation
assertJSON (KirokuCommandOutcome output _) = validJSON output

validJSON :: Text -> Expectation
validJSON output = (Aeson.eitherDecodeStrict (TE.encodeUtf8 output) :: Either String Aeson.Value) `shouldSatisfy` isRight

embeddableMessage :: Text
embeddableMessage = "kiroku: compaction and store identity commands run only inside a host that owns a KirokuStore; the standalone binary is a remote client"

sampleManifest :: CompactionManifest
sampleManifest = either (error . show) id (mkCompactionManifest (CompactionManifestInput (StoreIdentity UUID.nil) op RefuseDeadLetters RefuseCausationDependents [StreamHeadWitness name (StreamVersion 1)] [CompactionSelection (EventId UUID.nil) name (StreamVersion 1) (GlobalPosition 1) V.empty] Nothing))
  where
    name = StreamName "sample-1"
    op = either (error . show) id (mkCompactionOperation "sample")

withTestStore :: (KirokuStore -> IO a) -> IO a
withTestStore action = withMigratedTestDatabase $ \conn -> withStore (defaultConnectionSettings conn) action

storeRead :: (Show e) => Either e a -> IO a
storeRead = either (fail . show) pure

liveInput :: KirokuStore -> IO CompactionManifestInput
liveInput store = do
  let name = StreamName "orders-cli"
      event = EventData Nothing (EventType "CLI") (Aeson.object []) Nothing Nothing Nothing
  _ <- storeRead =<< runStoreIO store (appendToStream name NoStream [event, event, event])
  events <- storeRead =<< runStoreIO store (readAllForward (GlobalPosition 0) 10)
  identity <- storeRead =<< runStoreIO store storeIdentity
  op <- either (fail . show) pure (mkCompactionOperation "cli-test")
  let selected = events V.! 1
  pure (CompactionManifestInput identity op RefuseDeadLetters RefuseCausationDependents [StreamHeadWitness name (StreamVersion 3)] [CompactionSelection (selected ^. #eventId) name (selected ^. #originalVersion) (selected ^. #globalPosition) V.empty] Nothing)
