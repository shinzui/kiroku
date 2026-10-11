{-# LANGUAGE MultilineStrings #-}

module Main where

import Control.Lens ((^.))
import Control.Monad (replicateM_, unless)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Effectful
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store
import Kiroku.Test.Fixtures.StreamHead (streamHeadFixtureSql)
import Kiroku.Test.Postgres (withMigratedTestDatabase, withSharedMigratedPostgres)
import Test.Tasty.Bench

main :: IO ()
main = do
    start <- getCurrentTime
    withSharedMigratedPostgres $ withMigratedTestDatabase $ \connection ->
        withStore (defaultConnectionSettings connection) $ \store -> do
            sql store streamHeadFixtureSql
            sql store "VACUUM (ANALYZE) stream_events"
            setup <- getCurrentTime
            putStrLn ("setup_seconds=" <> show (diffUTCTime setup start))
            groups <- mapM (sizeGroup store) [("100", StreamName "bench-1"), ("100000", StreamName "long-1")]
            warmed <- getCurrentTime
            putStrLn ("warmup_seconds=" <> show (diffUTCTime warmed setup))
            defaultMain groups

sizeGroup :: KirokuStore -> (String, StreamName) -> IO Benchmark
sizeGroup store (label, name) = do
    Right (Just expected) <- runFrozen store (getStream name)
    unless (expected ^. #version == StreamVersion (read label)) (error "invalid fixture version")
    let validate result = case result of
            Right (Just actual) -> unless (actual == expected) (error "unexpected metadata")
            other -> error ("metadata read failed: " <> show other)
        control = replicateM_ 100 (runFrozen store (getStream name) >>= validate)
        production = replicateM_ 100 (runStoreIO store (getStream name) >>= validate)
    -- Equality checks every StreamInfo field in successful calls in both arms.
    control
    production
    pure $
        bgroup
            label
            [ bench "control-metadata" (whnfIO control)
            , bcompareWithin 0 1.10 ("$(NF-1) == \"" <> label <> "\" && $NF == \"control-metadata\"") $
                bench "production-metadata" (whnfIO production)
            ]

sql :: KirokuStore -> T.Text -> IO ()
sql store command = Pool.use (store ^. #pool) (Session.script command) >>= either (error . show) pure

-- Frozen from 109d58f57dbd5757ad55792474d046a37cc2e87d before EP-97.
-- Do not substitute production SQL, decoders, handlers or pool helpers here.
runFrozen :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)
runFrozen store = runEff . runErrorNoCallStack . frozenInterpreter store

frozenInterpreter :: (IOE :> es, Error StoreError :> es) => KirokuStore -> Eff (Store : es) a -> Eff es a
frozenInterpreter store = interpret_ $ \case
    GetStream (StreamName name) -> frozenPool (store ^. #pool) (Session.statement name frozenStatement)
    _ -> error "unexpected operation in frozen metadata control"

frozenPool :: (IOE :> es, Error StoreError :> es) => Pool.Pool -> Session.Session a -> Eff es a
frozenPool pool session = do
    result <- liftIO (Pool.use pool session)
    case result of
        Left usageErr -> throwError (ConnectionError (T.pack (show usageErr)))
        Right a -> pure a

frozenStatement :: Statement T.Text (Maybe StreamInfo)
frozenStatement =
    preparable
        """
        SELECT stream_id, stream_name, stream_version, created_at, deleted_at, truncate_before
        FROM streams
        WHERE stream_name = $1
        """
        (E.param (E.nonNullable E.text))
        (D.rowMaybe frozenRow)

frozenRow :: D.Row StreamInfo
frozenRow =
    StreamInfo
        <$> (StreamId <$> D.column (D.nonNullable D.int8))
        <*> (StreamName <$> D.column (D.nonNullable D.text))
        <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)
        <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
