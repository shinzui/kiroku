module Main where

import Control.Lens ((^.))
import Control.Monad (forM, unless)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Test.Postgres (withMigratedTestDatabase, withSharedMigratedPostgres)
import Test.Tasty (localOption)
import Test.Tasty.Bench

main :: IO ()
main =
    withSharedMigratedPostgres $
        withMigratedTestDatabase $ \controlConnectionString ->
            withMigratedTestDatabase $ \candidateConnectionString ->
                withStore (defaultConnectionSettings controlConnectionString) $ \controlStore ->
                    withStore (defaultConnectionSettings candidateConnectionString) $ \candidateStore -> do
                        let fourStreams = namedStreams "workload-gate-4" 4
                            eightStreams = namedStreams "workload-gate-8" 8
                        seedStreams controlStore (fourStreams <> eightStreams)
                        seedStreams candidateStore (fourStreams <> eightStreams)

                        runSequentialMultiAppend controlStore fourStreams
                        runProductionMultiAppend candidateStore fourStreams
                        runSequentialMultiAppend controlStore eightStreams
                        runProductionMultiAppend candidateStore eightStreams

                        defaultMain
                            [ localOption WallTime $
                                bgroup
                                    "append-multi-stream"
                                    [ bench "sequential-control-4" $
                                        whnfIO (runSequentialMultiAppend controlStore fourStreams)
                                    , bcompareWithin 0 0.90 "sequential-control-4" $
                                        bench "production-pipeline-4" $
                                            whnfIO (runProductionMultiAppend candidateStore fourStreams)
                                    , bench "sequential-control-8" $
                                        whnfIO (runSequentialMultiAppend controlStore eightStreams)
                                    , bcompareWithin 0 0.90 "sequential-control-8" $
                                        bench "production-pipeline-8" $
                                            whnfIO (runProductionMultiAppend candidateStore eightStreams)
                                    ]
                            ]

namedStreams :: Text -> Int -> [(StreamName, Text)]
namedStreams prefix count =
    [ ( StreamName (prefix <> "-" <> T.pack (show index))
      , "WorkloadGate" <> T.pack (show index)
      )
    | index <- [1 .. count]
    ]

seedStreams :: KirokuStore -> [(StreamName, Text)] -> IO ()
seedStreams store streams =
    mapM_
        ( \(streamName, eventType) -> do
            result <- runStoreIO store $ appendToStream streamName NoStream [makeEvent (eventType <> "Seed")]
            forceStoreResults "seed append" (fmap pure result)
        )
        streams

runProductionMultiAppend :: KirokuStore -> [(StreamName, Text)] -> IO ()
runProductionMultiAppend store streams = do
    result <-
        runStoreIO store $
            appendMultiStream
                [ (streamName, AnyVersion, [makeEvent eventType])
                | (streamName, eventType) <- streams
                ]
    forceStoreResults "production appendMultiStream" result

runSequentialMultiAppend :: KirokuStore -> [(StreamName, Text)] -> IO ()
runSequentialMultiAppend store streams = do
    now <- getCurrentTime
    preparedOps <-
        forM streams $ \(streamName@(StreamName name), eventType) -> do
            enriched <- enrichEvents (store ^. #storeSettings) [makeEvent eventType]
            prepared <- prepareEvents enriched
            pure (streamName, name, buildAppendParams name now prepared)
    let names = V.fromList [name | (_, name, _) <- preparedOps]
        transaction = do
            Tx.statement names SQL.lockStreamsForMultiStmt
            results <-
                forM preparedOps $ \(_, _, params) ->
                    appendDispatchTx AnyVersion params
            if any isNothing results
                then Tx.condemn >> pure results
                else pure results
    result <-
        Pool.use (store ^. #pool) $
            TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write transaction
    case result of
        Left err -> error ("sequential appendMultiStream control failed: " <> show err)
        Right maybeResults -> do
            unless (all isJustAppend maybeResults) $
                error "sequential appendMultiStream control returned an empty append result"
            forceAppendResults [appendResult | Just appendResult <- maybeResults]

makeEvent :: Text -> EventData
makeEvent eventType =
    EventData
        { eventId = Nothing
        , eventType = EventType eventType
        , payload = Aeson.object [("workloadGate", Aeson.Bool True)]
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        }

isJustAppend :: Maybe AppendResult -> Bool
isJustAppend (Just _) = True
isJustAppend Nothing = False

forceStoreResults :: String -> Either StoreError [AppendResult] -> IO ()
forceStoreResults _ (Right results) = forceAppendResults results
forceStoreResults label (Left err) = error (label <> " failed: " <> show err)

forceAppendResults :: [AppendResult] -> IO ()
forceAppendResults =
    mapM_ $ \result ->
        (result ^. #streamId) `seq`
            (result ^. #streamVersion) `seq`
                (result ^. #globalPosition) `seq`
                    pure ()
