{-# LANGUAGE MultilineStrings #-}

module Main where

import Control.Lens ((^.))
import Control.Monad (forM_, replicateM_, unless)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Effectful
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store
import Kiroku.Test.Fixtures.StreamHead (streamHeadFixtureSql)
import Kiroku.Test.Postgres (withMigratedTestDatabase, withSharedMigratedPostgres)
import System.Environment (getArgs)
import System.IO (BufferMode (LineBuffering), IOMode (WriteMode), hPutStrLn, hSetBuffering, withFile)

-- Fixed, paired measurements. The cell entry writes a predeclared balanced
-- ABBA/BAAB schedule. Each CSV row is one batch; no adaptive early stopping.
main :: IO ()
main = do
    [schedulePath, outputPath, callsText] <- getArgs
    let calls = read callsText :: Int
    unless (calls > 0 && calls <= 10000 && calls `mod` 5 == 0) (error "invalid batch size")
    schedule <- map (T.splitOn ",") . T.lines . T.pack <$> readFile schedulePath
    start <- getCurrentTime
    withSharedMigratedPostgres $ withMigratedTestDatabase $ \connection ->
        withStore (defaultConnectionSettings connection) $ \store -> do
            sql store streamHeadFixtureSql
            sql store "VACUUM (ANALYZE) stream_events"
            details <-
                Pool.use (store ^. #pool) $
                    Session.statement () $
                        preparable
                            "SELECT json_build_object('server', version(), 'shared_buffers', current_setting('shared_buffers'), 'work_mem', current_setting('work_mem'), 'jit', current_setting('jit'), 'plan_cache_mode', current_setting('plan_cache_mode'), 'streams', (SELECT count(*) FROM streams), 'events', (SELECT count(*) FROM events), 'junctions', (SELECT count(*) FROM stream_events))::text"
                            E.noParams
                            (D.singleRow (D.column (D.nonNullable D.text)))
            either (error . show) (putStrLn . T.unpack) details
            setup <- getCurrentTime
            putStrLn ("setup_seconds=" <> show (diffUTCTime setup start))
            small <- actions store (StreamName "bench-1") (StreamVersion 100)
            large <- actions store (StreamName "long-1") (StreamVersion 100000)
            let (frozenSmall, productionSmall) = small
                (frozenLarge, productionLarge) = large
                groups =
                    [ ("legacy-100", (frozenSmall, productionSmall, calls))
                    , ("legacy-100000", (frozenLarge, productionLarge, calls))
                    , ("aa-100", (productionSmall, productionSmall, calls))
                    , ("aa-100000", (productionLarge, productionLarge, calls))
                    , ("positive-20pct", (productionLarge, productionLarge, calls * 6 `div` 5))
                    ]
            -- Warm both actual implementations and connections before measurement.
            forM_ [frozenSmall, productionSmall, frozenLarge, productionLarge] (replicateM_ 1000)
            warmed <- getCurrentTime
            putStrLn ("warmup_seconds=" <> show (diffUTCTime warmed setup))
            withFile outputPath WriteMode $ \out -> do
                hSetBuffering out LineBuffering
                hPutStrLn out "round,case,order,slot,arm,calls,start_ns,end_ns,duration_ns"
                forM_ schedule $ \row -> case row of
                    [roundText, caseName, order] -> do
                        unless (order == "ABBA" || order == "BAAB") (error "invalid order")
                        (armA, armB, callsB) <- maybe (error "unknown case") pure (lookup caseName groups)
                        forM_ (zip [0 :: Int ..] (T.unpack order)) $ \(slot, arm) -> do
                            let count = if arm == 'A' then calls else callsB
                                action = if arm == 'A' then armA else armB
                            before <- getMonotonicTimeNSec
                            replicateM_ count action
                            after <- getMonotonicTimeNSec
                            hPutStrLn out $
                                T.unpack $
                                    T.intercalate
                                        ","
                                        [ roundText
                                        , caseName
                                        , order
                                        , T.pack (show slot)
                                        , T.singleton arm
                                        , T.pack (show count)
                                        , T.pack (show before)
                                        , T.pack (show after)
                                        , T.pack (show (after - before))
                                        ]
                    _ -> error "invalid schedule row"
            finished <- getCurrentTime
            putStrLn ("measurement_seconds=" <> show (diffUTCTime finished warmed))
            putStrLn ("total_seconds=" <> show (diffUTCTime finished start))

-- The A/A arms receive the same IO action, including validation. The positive
-- control repeats that same action 20% more times, without normalizing it away.
actions :: KirokuStore -> StreamName -> StreamVersion -> IO (IO (), IO ())
actions store name version = do
    Right (Just expected) <- runFrozen store (getStream name)
    unless (expected ^. #version == version) (error "invalid fixture version")
    let validate result = case result of
            Right (Just actual) -> unless (actual == expected) (error "unexpected metadata")
            other -> error ("metadata read failed: " <> show other)
    pure (runFrozen store (getStream name) >>= validate, runStoreIO store (getStream name) >>= validate)

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
