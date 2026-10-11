{-# LANGUAGE NoFieldSelectors #-}

-- | Open a store and serve its inspection surface without a Haskell host program.
module Kiroku.Metrics.Standalone (
    InspectOptions (..),
    inspectOptionsParser,
    inspectParserInfo,
    InspectRuntime (..),
    resolveInspectOptions,
    InspectHooks (..),
    runInspect,
    renderStartupBanner,
) where

import Control.Applicative (many, optional, (<|>))
import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative qualified as O

import Kiroku.Metrics.Capabilities
import Kiroku.Metrics.Collector
import Kiroku.Metrics.Config (defaultConfig)
import Kiroku.Metrics.Config qualified as Config
import Kiroku.Metrics.Cors
import Kiroku.Metrics.Health (postgresPing)
import Kiroku.Metrics.Server
import Kiroku.Store qualified as Store
import Kiroku.Store.Subscription.EventPublisher (EventPublisher (..), publisherPosition)

-- No Show instances: a database URL can contain credentials.
data InspectOptions = InspectOptions
    { databaseUrl :: !(Maybe Text)
    , schema :: !(Maybe Text)
    , poolSize :: !(Maybe Int)
    , port :: !(Maybe Int)
    , corsOrigins :: ![Text]
    , corsAllowCredentials :: !(Maybe Bool)
    , wsMaxConnections :: !(Maybe Int)
    }
    deriving stock (Eq)

data InspectRuntime = InspectRuntime
    { databaseUrl :: !Text
    , schema :: !Text
    , poolSize :: !Int
    , port :: !Int
    , cors :: !CorsPolicy
    , wsMaxConnections :: !Int
    }
    deriving stock (Eq)

data InspectHooks = InspectHooks
    { onListening :: !(Int -> Capabilities -> IO ())
    -- ^ Called once after successful binding, with the actual port and wiring.
    , waitForShutdown :: !(IO ())
    }

inspectOptionsParser :: O.Parser InspectOptions
inspectOptionsParser =
    InspectOptions
        <$> optional (textOption "database-url" "URL" "Database connection string (or DATABASE_URL)")
        <*> optional (textOption "schema" "NAME" "Migrated schema (default kiroku)")
        <*> optional (numberOption "pool-size" 1 intMaximum "Connection pool size (default 10)")
        <*> optional (numberOption "port" 0 65535 "Listen port (default 9091; 0 selects a free port)")
        <*> many (textOption "cors-origin" "ORIGIN" "Allowed HTTP(S) browser origin; repeatable")
        <*> optional
            ( O.flag' True (O.long "cors-allow-credentials" <> O.help "Allow credentials for explicit origins")
                <|> O.flag' False (O.long "no-cors-allow-credentials" <> O.help "Disable credentials, overriding the environment")
            )
        <*> optional (numberOption "ws-max-connections" 1 intMaximum "Maximum WebSocket connections (default 100)")
  where
    textOption name metavar help = O.strOption (O.long name <> O.metavar metavar <> O.help help)
    numberOption name lower upper help =
        O.option
            (O.eitherReader (either (Left . T.unpack) Right . boundedDecimal lower upper . T.pack))
            (O.long name <> O.metavar "N" <> O.help help)

inspectParserInfo :: O.ParserInfo InspectOptions
inspectParserInfo =
    O.info
        (inspectOptionsParser O.<**> O.helper)
        ( O.failureCode 2
            <> O.fullDesc
            <> O.header "kiroku-inspect - standalone inspection server"
            <> O.progDesc "Serve the read-only inspection API from a migrated Kiroku database. Runs no subscriptions."
        )

intMaximum :: Integer
intMaximum = toInteger (maxBound :: Int)

-- Parse into Integer and stop growing at the upper bound, before narrowing to Int.
boundedDecimal :: Integer -> Integer -> Text -> Either Text Int
boundedDecimal lower upper value
    | T.null value || not (T.all (\c -> c >= '0' && c <= '9') value) = Left "expected ASCII decimal digits"
    | otherwise = do
        n <- T.foldl' step (Right 0) value
        if n < lower then Left "value is below the allowed range" else Right (fromInteger n)
  where
    step result c = do
        n <- result
        let next = n * 10 + toInteger (fromEnum c - fromEnum '0')
        if next > upper then Left "value exceeds the allowed range" else Right next

resolveInspectOptions :: [(String, String)] -> InspectOptions -> Either Text InspectRuntime
resolveInspectOptions env opts = do
    url <- maybe (Left "kiroku-inspect: no database; pass --database-url or set DATABASE_URL (a libpq URI such as postgresql://user@host/db)") Right (opts.databaseUrl <|> variable "DATABASE_URL")
    nonempty "--database-url" url
    let schemaName = maybe "kiroku" id (opts.schema <|> variable "KIROKU_INSPECT_SCHEMA")
    nonempty "--schema" schemaName
    pool <- number opts.poolSize "KIROKU_INSPECT_POOL_SIZE" 1 intMaximum (Store.defaultConnectionSettings url).poolSize
    listenPort <- number opts.port "KIROKU_INSPECT_PORT" 0 65535 defaultConfig.port
    maxConnections <- number opts.wsMaxConnections "KIROKU_INSPECT_WS_MAX_CONNECTIONS" 1 intMaximum defaultConfig.wsMaxConnections
    credentials <- case opts.corsAllowCredentials of
        Just b -> Right b
        Nothing -> case variable "KIROKU_INSPECT_CORS_ALLOW_CREDENTIALS" of
            Nothing -> Right False
            Just "true" -> Right True
            Just "1" -> Right True
            Just "false" -> Right False
            Just "0" -> Right False
            Just _ -> Left "kiroku-inspect: KIROKU_INSPECT_CORS_ALLOW_CREDENTIALS must be true, false, 1 or 0"
    let originTexts = if null opts.corsOrigins then maybe [] (map T.strip . T.splitOn ",") (variable "KIROKU_INSPECT_CORS_ORIGINS") else opts.corsOrigins
    origins <-
        traverse
            ( \origin -> case allowedOrigin origin of
                Right o -> Right o
                Left WildcardOrigin -> Left "kiroku-inspect: wildcard '*' is not an allowed CORS origin"
                Left _ -> Left "kiroku-inspect: invalid CORS origin; use an explicit HTTP(S) origin"
            )
            originTexts
    let policy = if null origins then corsDisabled else (corsAllowOrigins origins){allowCredentials = credentials}
    pure (InspectRuntime url schemaName pool listenPort policy maxConnections)
  where
    variable name = case T.pack <$> lookup name env of
        Just value | not (T.null value) -> Just value
        _ -> Nothing
    nonempty name value = if T.null (T.strip value) then Left ("kiroku-inspect: " <> name <> " must not be empty") else Right ()
    number explicit name lower upper fallback = case explicit of
        Just value | toInteger value >= lower && toInteger value <= upper -> Right value
        Just _ -> Left ("kiroku-inspect: " <> T.pack name <> " flag is outside the allowed range")
        Nothing -> case variable name of
            Nothing -> Right fallback
            Just value -> either (\message -> Left ("kiroku-inspect: " <> T.pack name <> ": " <> message)) Right (boundedDecimal lower upper value)

runInspect :: InspectHooks -> InspectRuntime -> IO ()
runInspect hooks rt = do
    storeVar <- newTVarIO Nothing
    metrics <- newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)
    let settings =
            (Store.defaultConnectionSettings rt.databaseUrl)
                { Store.schema = rt.schema
                , Store.poolSize = rt.poolSize
                , Store.eventHandler = Just (metricsEventHandler metrics Nothing)
                , Store.observationHandler = Just (metricsObservationHandler metrics Nothing)
                }
        cfg = defaultConfig{Config.port = rt.port, Config.cors = rt.cors, Config.wsMaxConnections = rt.wsMaxConnections}
    Store.withStore settings $ \store -> do
        atomically (writeTVar storeVar (Just store))
        providers <- storeServerProviders cfg metrics store
        withMetricsServerWithProviders cfg metrics [postgresPing store] providers $ \server -> do
            hooks.onListening server.serverPort (capabilitiesFor cfg (providerPresence providers))
            hooks.waitForShutdown

readPosition :: TVar (Maybe Store.KirokuStore) -> STM Store.GlobalPosition
readPosition storeVar = readTVar storeVar >>= maybe (pure (Store.GlobalPosition 0)) (publisherPosition . (.publisher))

readSubscribers :: TVar (Maybe Store.KirokuStore) -> STM Int
readSubscribers storeVar = readTVar storeVar >>= maybe (pure 0) (\store -> IntMap.size <$> readTVar (subscribers store.publisher))

-- | Never includes the database URL. The port is the actual bound port.
renderStartupBanner :: InspectRuntime -> Int -> Capabilities -> [Text]
renderStartupBanner rt boundPort caps =
    [ "kiroku-inspect: connected to schema " <> T.pack (show rt.schema) <> "; listening on port " <> T.pack (show boundPort)
    , "kiroku-inspect: routes browse="
        <> enabled caps.routes.browse
        <> " subscriptions_checkpoints="
        <> enabled caps.routes.subscriptionsCheckpoints
        <> " dead_letters="
        <> enabled caps.routes.deadLetters
        <> " subscriptions_live="
        <> enabled caps.routes.subscriptionsLive
        <> " websocket_events="
        <> enabled caps.routes.websocketEvents
        <> " cors="
        <> enabled caps.corsIsEnabled
    , "kiroku-inspect: this process runs no subscriptions; /subscriptions, /metrics, and /health reflect only this process"
    ]
  where
    enabled True = "on"
    enabled False = "off"
