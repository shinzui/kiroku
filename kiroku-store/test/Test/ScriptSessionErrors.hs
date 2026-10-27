module Test.ScriptSessionErrors (spec) where

import Control.Exception (bracket)
import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Errors qualified as Errors
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Config
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import System.Timeout (timeout)
import Test.Helpers (countEvents, makeEvent, withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "structured script session errors" $ do
  around withTestStore $ do
    it "preserves missing-relation SQLSTATE through runTransaction" $ \store -> do
      result <- runStoreIO store (runTransaction (Tx.sql (TE.encodeUtf8 missingRelation)))
      shouldBeMissingRelation result
    it "preserves missing-relation SQLSTATE without retry" $ \store -> do
      result <- runStoreIO store (runTransactionNoRetry (Tx.sql (TE.encodeUtf8 missingRelation)))
      shouldBeMissingRelation result
    forM_ ["40001", "40P01"] $ \code -> do
      it ("preserves script SQLSTATE and message " <> show code) $ \store -> do
        result <- timeout 5_000_000 $ runStoreIO store (runTransactionNoRetry (Tx.sql (TE.encodeUtf8 (raiseCode code))))
        result `shouldBe` Just (Left (TransientTransactionFailure code fixtureMessage))
      it ("preserves prepared-statement SQLSTATE and message " <> show code) $ \store -> do
        result <-
          timeout 5_000_000 $
            runStoreIO store $
              runTransactionNoRetry $
                Tx.statement () (preparable (raiseCode code) E.noParams D.noResult)
        result `shouldBe` Just (Left (TransientTransactionFailure code fixtureMessage))
    it "rolls back application writes before a script failure" $ \store -> do
      createSideTable store
      result <- runStoreIO store $ runTransactionNoRetry $ do
        Tx.sql "INSERT INTO public.script_error_rows VALUES (1)"
        Tx.sql (TE.encodeUtf8 missingRelation)
      shouldBeMissingRelation result
      countSideRows store `shouldReturn` Right 0
    it "rolls back composed appends and application writes on script failure" $ \store -> do
      createSideTable store
      result <- runStoreIO store $
        runTransactionAppendingNoRetry (StreamName "script-rollback") NoStream [makeEvent "Created" (Aeson.object [])] $ \_ -> do
          Tx.sql "INSERT INTO public.script_error_rows VALUES (1)"
          Tx.sql (TE.encodeUtf8 missingRelation)
      shouldBeMissingRelation result
      countSideRows store `shouldReturn` Right 0
      runStoreIO store (getStream (StreamName "script-rollback")) `shouldReturn` Right Nothing
      countEvents store `shouldReturn` 0

  it "preserves missing-relation SQLSTATE through the public pool-backed read" $
    withMigratedTestDatabase $ \connStr ->
      withStore (defaultConnectionSettings connStr) $ \store ->
        withPool connStr [Config.initSession (Session.script "SET search_path TO pg_catalog")] $ \pool -> do
          result <- runStoreIO (store & #pool .~ pool) (getStream (StreamName "missing"))
          shouldBeMissingRelation result

  it "keeps genuine connection establishment failures typed for transactions and reads" $
    withTestStore $ \store ->
      withPool "host=/nonexistent/kiroku-script-errors connect_timeout=1" [] $ \pool -> do
        let broken = store & #pool .~ pool
        tx <- timeout 5_000_000 $ runStoreIO broken (runTransactionNoRetry (Tx.sql "SELECT 1"))
        tx `shouldSatisfy` isConnectionLost
        readResult <- timeout 5_000_000 $ runStoreIO broken (getStream (StreamName "missing"))
        readResult `shouldSatisfy` isConnectionLost

  it "routes script server errors through every contextual mapper" $ do
    forM_ ["40001", "40P01", "42P01", "40003", "23503"] $ \code -> do
      let usage = scriptUsage code fixtureMessage Nothing
          expected = if code `elem` ["40001", "40P01"] then TransientTransactionFailure code fixtureMessage else UnexpectedServerError code fixtureMessage
      mapGenericUsageError usage `shouldBe` expected
      mapTransactionUsageError usage `shouldBe` expected
      mapLinkUsageError (StreamName "target") usage `shouldBe` expected
      isTransientSerializationError usage `shouldBe` (code `elem` ["40001", "40P01"])
      if code == "23503"
        then mapUsageError "target" AnyVersion usage `shouldBe` StreamNotFound (StreamName "target")
        else do
          mapUsageError "target" AnyVersion usage `shouldBe` expected
          attributeMultiStreamError [(StreamName "target", AnyVersion)] usage `shouldBe` expected

  it "retains script append and link constraint attribution" $ do
    let usage = scriptUsage "23505" "duplicate key value violates unique constraint \"stream_events_pkey\"" Nothing
    mapTransactionUsageError usage `shouldBe` DuplicateEvent Nothing
    mapUsageError "target" AnyVersion usage `shouldBe` DuplicateEvent Nothing
    mapLinkUsageError (StreamName "target") usage `shouldBe` EventAlreadyLinked (StreamName "target") Nothing
    let named = scriptUsage "23505" "duplicate key value violates unique constraint \"ix_streams_stream_name\"" (Just "Key (stream_name)=(second) already exists.")
    attributeMultiStreamError [(StreamName "first", AnyVersion), (StreamName "second", NoStream)] named
      `shouldBe` StreamAlreadyExists (StreamName "second")

  it "distinguishes session connection loss, acquisition timeout and unsupported errors" $ do
    let lost = Pool.SessionUsageError (Errors.ConnectionSessionError "connection detail")
        fallback = Pool.SessionUsageError (Errors.DriverSessionError "driver detail")
    forM_ [mapGenericUsageError, mapTransactionUsageError, mapUsageError "target" AnyVersion, mapLinkUsageError (StreamName "target")] $ \mapper -> do
      mapper lost `shouldBe` ConnectionLost "connection detail"
      mapper Pool.AcquisitionTimeoutUsageError `shouldBe` PoolAcquisitionTimeout
      mapper fallback `shouldSatisfy` (\case ConnectionError _ -> True; _ -> False)
    isTransientSerializationError lost `shouldBe` False

missingRelation :: Text
missingRelation = "INSERT INTO public.kiroku_script_missing_relation VALUES (1)"

fixtureMessage :: Text
fixtureMessage = "script error fixture"

raiseCode :: Text -> Text
raiseCode code = "DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '" <> code <> "', MESSAGE = '" <> fixtureMessage <> "'; END $$"

scriptUsage :: Text -> Text -> Maybe Text -> Pool.UsageError
scriptUsage code message detail = Pool.SessionUsageError (Errors.ScriptSessionError "fixture SQL" (Errors.ServerError code message detail Nothing Nothing))

shouldBeMissingRelation :: (Show a) => Either StoreError a -> Expectation
shouldBeMissingRelation result = case result of
  Left (UnexpectedServerError "42P01" _) -> pure ()
  other -> expectationFailure ("Expected structured 42P01, got " <> show other)

isConnectionLost :: Maybe (Either StoreError a) -> Bool
isConnectionLost (Just (Left (ConnectionLost _))) = True
isConnectionLost _ = False

withPool :: Text -> [Config.Setting] -> (Pool.Pool -> IO a) -> IO a
withPool connStr extra = bracket (Pool.acquire (Config.settings ([Config.staticConnectionSettings (Conn.connectionString connStr), Config.size 1, Config.acquisitionTimeout 1] <> extra))) Pool.release

createSideTable :: KirokuStore -> IO ()
createSideTable store = runStoreIO store (runTransactionNoRetry (Tx.sql "CREATE TABLE public.script_error_rows (id integer)")) `shouldReturn` Right ()

countSideRows :: KirokuStore -> IO (Either StoreError Int64)
countSideRows store =
  runStoreIO store $
    runTransactionNoRetry $
      Tx.statement () (preparable "SELECT count(*) FROM public.script_error_rows" E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))
