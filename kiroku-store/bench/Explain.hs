{-# LANGUAGE MultilineStrings #-}

{- | PostgreSQL-side append profiling harness.

Two modes:

  * default — boots a cached ephemeral PostgreSQL via 'Pg.withCached', runs
    the production @AnyVersion@ CTE under
    @EXPLAIN (ANALYZE, BUFFERS, TIMING, FORMAT TEXT)@ wrapped in
    @BEGIN ... ROLLBACK@, prints the result to stdout, then runs the same
    query under @FORMAT JSON@ and writes the result to
    @kiroku-store/bench/explain-results/anyversion-singleton.json@.

  * @--auto-explain@ — boots an ephemeral PostgreSQL with the @auto_explain@
    contrib loaded via 'Pg.autoExplainConfig', redirects the server's stderr
    to @kiroku-store/bench/explain-results/auto-explain.log@, opens a
    'KirokuStore' (which migrates the schema), runs a small workload (one
    @AnyVersion@ append, one @ExactVersion@ append against the same stream,
    one @ReadStreamForward@, one @ReadAllForward@), and exits. PostgreSQL
    flushes the @auto_explain@ output to the captured log on shutdown.

Belongs to ExecPlan
@docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md@.
-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.UUID (UUID)
import Data.UUID.V4 qualified as V4
import Data.Vector qualified as V
import EphemeralPg qualified as Pg
import EphemeralPg.Config qualified as PgC
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, unpreparable)
import Kiroku.Store
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory, listDirectory, removePathForcibly)
import System.Environment (getArgs)
import System.FilePath (takeDirectory, (</>))
import System.IO (BufferMode (..), hSetBuffering, stdout)

-- ---------------------------------------------------------------------------
-- Local copies of AppendParams + encoder + appendAnyVersionSQL
-- ---------------------------------------------------------------------------
-- Duplicated from Kiroku.Store.SQL (an other-modules module not exposed by
-- the kiroku-store library). EP-2 deliberately inlines these rather than
-- expose the SQL module; see the Decision Log of plan 26.
-- ---------------------------------------------------------------------------

data AppendParams = AppendParams
    { eventIds :: !(V.Vector UUID)
    , eventTypes :: !(V.Vector Text)
    , causationIds :: !(V.Vector (Maybe UUID))
    , correlationIds :: !(V.Vector (Maybe UUID))
    , payloads :: !(V.Vector Aeson.Value)
    , metadatas :: !(V.Vector (Maybe Aeson.Value))
    , createdAts :: !(V.Vector UTCTime)
    , streamName :: !Text
    }
    deriving stock (Generic)

appendParamsEncoder :: E.Params AppendParams
appendParamsEncoder =
    ((^. #eventIds) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        <> ((^. #eventTypes) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        <> ((^. #causationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((^. #correlationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((^. #payloads) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.jsonb))))
        <> ((^. #metadatas) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.jsonb))))
        <> ((^. #createdAts) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.timestamptz))))
        <> ((^. #streamName) >$< E.param (E.nonNullable E.text))

appendAnyVersionSQL :: Text
appendAnyVersionSQL =
    """
    WITH
      new_events AS (
        SELECT *
        FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
        WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
      ),
      stream_upsert AS (
        INSERT INTO streams (stream_name, stream_version)
        VALUES ($8, (SELECT count(*) FROM new_events))
        ON CONFLICT (stream_name)
        DO UPDATE SET stream_version = streams.stream_version + (SELECT count(*) FROM new_events)
          WHERE streams.deleted_at IS NULL
        RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
      ),
      inserted_events AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
        FROM new_events
        WHERE EXISTS (SELECT 1 FROM stream_upsert)
        ORDER BY idx
      ),
      source_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN stream_upsert su
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_id = 0
          AND EXISTS (SELECT 1 FROM stream_upsert)
        RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
      ),
      all_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN all_update au
        CROSS JOIN stream_upsert su
      )
    SELECT su.stream_id,
           su.initial_version + (SELECT count(*) FROM new_events),
           au.initial_global_version + (SELECT count(*) FROM new_events)
    FROM stream_upsert su
    CROSS JOIN all_update au
    """

-- ---------------------------------------------------------------------------
-- EXPLAIN wrappers + sample params
-- ---------------------------------------------------------------------------

{- | Wrap @appendAnyVersionSQL@ in @EXPLAIN (...) <CTE>@ with @FORMAT TEXT@.
Each row of the result is one indented plan line. Uses 'unpreparable'
because the EXPLAIN runs once and the statement-cache cost would be wasted.
-}
explainStatementText :: Statement AppendParams [Text]
explainStatementText =
    unpreparable
        sql
        appendParamsEncoder
        (D.rowList (D.column (D.nonNullable D.text)))
  where
    sql =
        "EXPLAIN (ANALYZE, BUFFERS, TIMING, FORMAT TEXT)\n"
            <> appendAnyVersionSQL

{- | Wrap @appendAnyVersionSQL@ in @EXPLAIN (...) <CTE>@ with @FORMAT JSON@.
PostgreSQL returns one row whose single column is of type @json@; we use
'D.jsonBytes' with an identity parser to preserve the original
byte-for-byte output.
-}
explainStatementJson :: Statement AppendParams BS.ByteString
explainStatementJson =
    unpreparable
        sql
        appendParamsEncoder
        (D.singleRow (D.column (D.nonNullable (D.jsonBytes Right))))
  where
    sql =
        "EXPLAIN (ANALYZE, BUFFERS, TIMING, FORMAT JSON)\n"
            <> appendAnyVersionSQL

{- | One-event 'AppendParams' for an @AnyVersion@ append against a fresh
stream name.
-}
mkSampleParams :: IO AppendParams
mkSampleParams = do
    eid <- V4.nextRandom
    now <- getCurrentTime
    let nowMicros = show now
    pure
        AppendParams
            { eventIds = V.singleton eid
            , eventTypes = V.singleton "ExplainEvent"
            , causationIds = V.singleton Nothing
            , correlationIds = V.singleton Nothing
            , payloads = V.singleton (Aeson.object ["explain" Aeson..= Aeson.String "anyversion"])
            , metadatas = V.singleton Nothing
            , createdAts = V.singleton now
            , streamName = T.pack ("explain-" <> nowMicros)
            }

{- | Run a single TEXT-format EXPLAIN session inside @BEGIN ... ROLLBACK@
so the inserted rows do not persist.
-}
explainSessionText :: AppendParams -> Session.Session [Text]
explainSessionText params = do
    Session.script "BEGIN"
    rows <- Session.statement params explainStatementText
    Session.script "ROLLBACK"
    pure rows

{- | JSON-format counterpart of 'explainSessionText'. The result is the
@json@ column's raw bytes.
-}
explainSessionJson :: AppendParams -> Session.Session BS.ByteString
explainSessionJson params = do
    Session.script "BEGIN"
    bs <- Session.statement params explainStatementJson
    Session.script "ROLLBACK"
    pure bs

-- ---------------------------------------------------------------------------
-- Output paths
-- ---------------------------------------------------------------------------

{- | Walk up from the current working directory until a @cabal.project@ file
is found, then return that directory. Falls back to the CWD if no marker
is found. This makes the harness work whether invoked from the repo root
('cabal run', direct binary invocation) or from the package directory
('cabal bench', which sets CWD to @kiroku-store\/@).
-}
locateRepoRoot :: IO FilePath
locateRepoRoot = do
    cwd <- getCurrentDirectory
    go cwd
  where
    go dir = do
        let marker = dir </> "cabal.project"
        present <- doesFileExist marker
        if present
            then pure dir
            else
                let parent = takeDirectory dir
                 in if parent == dir
                        then getCurrentDirectory
                        else go parent

explainResultsDir :: FilePath -> FilePath
explainResultsDir repoRoot = repoRoot </> "kiroku-store" </> "bench" </> "explain-results"

jsonOutputPath :: FilePath -> FilePath
jsonOutputPath repoRoot = explainResultsDir repoRoot </> "anyversion-singleton.json"

textOutputPath :: FilePath -> FilePath
textOutputPath repoRoot = explainResultsDir repoRoot </> "anyversion-singleton.txt"

autoExplainLogPath :: FilePath -> FilePath
autoExplainLogPath repoRoot = explainResultsDir repoRoot </> "auto-explain.log"

autoExplainCsvPath :: FilePath -> FilePath
autoExplainCsvPath repoRoot = explainResultsDir repoRoot </> "auto-explain.csv"

-- ---------------------------------------------------------------------------
-- Milestone 1: targeted EXPLAIN ANALYZE
-- ---------------------------------------------------------------------------

runExplainAnalyze :: IO ()
runExplainAnalyze = do
    repoRoot <- locateRepoRoot
    let dir = explainResultsDir repoRoot
        jsonPath = jsonOutputPath repoRoot
        textPath = textOutputPath repoRoot
    createDirectoryIfMissing True dir
    putStrLn ("=== Output directory: " <> dir <> " ===")
    putStrLn "=== Booting cached ephemeral PostgreSQL for EXPLAIN ANALYZE ==="
    result <- Pg.withCached $ \db -> do
        let settings = defaultConnectionSettings (Pg.connectionString db)
        withStore settings $ \store -> do
            paramsText <- mkSampleParams
            paramsJson <- mkSampleParams

            putStrLn ""
            putStrLn "=== EXPLAIN (ANALYZE, BUFFERS, TIMING, FORMAT TEXT) of appendAnyVersionSQL ==="
            putStrLn ""
            textRows <- runSession store (explainSessionText paramsText)
            let textOut = T.intercalate "\n" textRows
            TIO.putStrLn textOut
            TIO.writeFile textPath textOut

            putStrLn ""
            putStrLn ("=== Writing FORMAT JSON output to " <> jsonPath <> " ===")
            jsonBytes <- runSession store (explainSessionJson paramsJson)
            BS.writeFile jsonPath jsonBytes

            putStrLn ""
            putStrLn ("=== TEXT output also archived at " <> textPath <> " ===")
    case result of
        Left err ->
            error ("EphemeralPg failed to start: " <> show err)
        Right () ->
            pure ()

-- ---------------------------------------------------------------------------
-- Milestone 2: auto_explain capture of a small workload
-- ---------------------------------------------------------------------------

{- | A representative slice of the production read+write paths so the
@auto_explain@ log captures one of each kind. Kept tiny so the resulting
log is human-readable.
-}
runSmallWorkload :: KirokuStore -> IO ()
runSmallWorkload store = do
    let sn = StreamName "explain-auto"
    -- AnyVersion append: hits the appendAnyVersionSQL CTE.
    r1 <- runStoreIO store $ appendToStream sn AnyVersion [mkEvent "Created"]
    forceOk "AnyVersion" r1
    let Right res1 = r1
    -- ExactVersion append against the same stream: hits the
    -- appendExpectedVersionSQL CTE with a non-trivial conflict check.
    r2 <-
        runStoreIO store $
            appendToStream sn (ExactVersion (res1 ^. #streamVersion)) [mkEvent "Updated"]
    forceOk "ExactVersion" r2
    -- One read forward from the same stream (limit 100 events).
    r3 <- runStoreIO store $ readStreamForward sn (StreamVersion 0) 100
    forceOk "readStreamForward" r3
    -- One read forward from the $all stream (limit 100 events).
    r4 <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
    forceOk "readAllForward" r4
  where
    mkEvent :: Text -> EventData
    mkEvent ty =
        EventData
            Nothing
            (EventType ty)
            (Aeson.object ["t" Aeson..= ty])
            Nothing
            Nothing
            Nothing

    forceOk :: (Show a) => Text -> Either StoreError a -> IO ()
    forceOk label = \case
        Left e -> error (T.unpack label <> " failed: " <> show e)
        Right _ -> pure ()

runAutoExplain :: IO ()
runAutoExplain = do
    repoRoot <- locateRepoRoot
    let dir = explainResultsDir repoRoot
        logPath = autoExplainLogPath repoRoot
        csvPath = autoExplainCsvPath repoRoot
    createDirectoryIfMissing True dir
    putStrLn ("=== Output directory: " <> dir <> " ===")
    putStrLn "=== Booting ephemeral PostgreSQL with auto_explain enabled ==="
    -- ephemeral-pg unconditionally discards the postgres process's stderr
    -- (`setStderr nullStream` at EphemeralPg/Process/Postgres.hs:78), so
    -- plan 26's documented "override Config.stderr to a file handle"
    -- approach cannot work. Instead, configure PostgreSQL's own logging
    -- collector to write a CSV log directly to disk; auto_explain's output
    -- is captured as the message column of those CSV rows. See plan 26's
    -- Surprises & Discoveries for the full debrief.
    let logDir = dir </> "pglog"
        logFilename = "auto-explain.log"
    createDirectoryIfMissing True logDir
    let collectorSettings =
            [ ("logging_collector", "'on'")
            , ("log_destination", "'csvlog'")
            , ("log_directory", "'" <> T.pack logDir <> "'")
            , ("log_filename", "'" <> T.pack logFilename <> "'")
            , ("log_rotation_age", "'0'")
            , ("log_rotation_size", "'0'")
            , ("log_truncate_on_rotation", "'off'")
            , ("log_line_prefix", "'%t [%p] '")
            , -- Required to actually capture auto_explain output: empirical
              -- testing showed that with default log_min_messages (warning)
              -- the csvlog file stayed at 0 bytes, even though
              -- auto_explain.log_min_duration was 0. Forcing the threshold
              -- down to log_min_messages = 'log' lets the auto_explain
              -- ereport(LOG, ...) calls through. See plan 26's Surprises
              -- & Discoveries for the empirical evidence.
              ("log_min_messages", "'log'")
            ]
    let cfg =
            PgC.defaultConfig
                <> PgC.autoExplainConfig 0
                <> (mempty :: PgC.Config){PgC.postgresSettings = collectorSettings}
    result <- Pg.withConfig cfg $ \db -> do
        let settings = defaultConnectionSettings (Pg.connectionString db)
        withStore settings $ \store -> do
            putStrLn "=== Running small workload (1 AnyVersion + 1 ExactVersion + 2 reads) ==="
            runSmallWorkload store
            putStrLn "=== Waiting so the logging collector flushes ==="
            threadDelay 3_000_000 -- 3 seconds
    case result of
        Left err ->
            error ("EphemeralPg failed to start: " <> show err)
        Right () -> do
            files <- listDirectory logDir
            let collectorCsv = logDir </> "auto-explain.csv"
            let collectorStderrLog = logDir </> "auto-explain.log"
            hasCsv <- doesFileExist collectorCsv
            hasLog <- doesFileExist collectorStderrLog
            if hasCsv
                then do
                    contents <- BS.readFile collectorCsv
                    BS.writeFile csvPath contents
                    putStrLn ("=== auto_explain csvlog: " <> csvPath <> " (" <> show (BS.length contents) <> " bytes) ===")
                else putStrLn ("=== WARNING: missing " <> collectorCsv <> "; emitted: " <> show files <> " ===")
            if hasLog
                then do
                    contents <- BS.readFile collectorStderrLog
                    BS.writeFile logPath contents
                    putStrLn ("=== auto_explain stderr (small): " <> logPath <> " (" <> show (BS.length contents) <> " bytes) ===")
                else putStrLn ("=== NOTE: collector did not produce a stderr-format log (csvlog only) ===")
            -- Drop the intermediate pglog/ directory; we have copies in the
            -- documented output paths above.
            removePathForcibly logDir

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

{- | Run a Hasql 'Session' directly against the store's pool, surfacing
pool errors via 'error'. Used by the EXPLAIN harness which bypasses the
Store effect layer.
-}
runSession :: KirokuStore -> Session.Session a -> IO a
runSession store session = do
    r <- Pool.use (store ^. #pool) session
    case r of
        Left e -> error ("Hasql.Pool.use failed: " <> show e)
        Right a -> pure a

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    args <- getArgs
    if "--auto-explain" `elem` args
        then runAutoExplain
        else runExplainAnalyze
