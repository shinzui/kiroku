-- Disposable index comparison; never used by the default MP12 workload.
module IndexResearch (Config (..), knobs, configuration, setup, streamName, snapshot, newBrowser, withBrowser) where

import Contravariant.Extras (contrazip2)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Monad (unless, when)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Json
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Kenshou.Core.Knob
import Kenshou.Measure.Recorder qualified as Recorder
import Kenshou.Measure.Session qualified as Measure
import Kiroku.Store (KirokuStore (..), StreamName (..))

-- These knobs are recorded in compatibility inputs. Both arms use one payload.
data Config = Config {layout :: !Text, catalog :: !Int, browseHz :: !Int}

knobs :: [KnobSpec]
knobs =
    [ KnobSpec (name "mp13.index-layout") "Disposable stream-index layout" KnobText (VText "unchanged") (OneOf (VText "unchanged" :| map VText ["category-only", "category-name"])) []
    , KnobSpec (name "mp13.catalog") "TypeID streams per fixture category" KnobInt (VInt 20000) (IntRange 1 200000) []
    , KnobSpec (name "mp13.browse-hz") "Category browse cycles per second; first, late and absent pages" KnobInt (VInt 0) (IntRange 0 10) []
    ]
  where
    name = either (error . show) id . mkKnobName

configuration :: ResolvedKnobs -> Maybe Config
configuration values
    | selected == "unchanged" = Nothing
    | otherwise = Just (Config selected (integer "mp13.catalog") (integer "mp13.browse-hz"))
  where
    name = either (error . show) id . mkKnobName
    selected = knobText values (name "mp13.index-layout")
    integer key = fromIntegral (knobInt values (name key))

setup :: Config -> KirokuStore -> IO Json.Value
setup config store = do
    -- The cell executor supplies an isolated, freshly migrated run database.
    -- Refuse a populated database instead of modifying a real store.
    initial <- scalarInt store "SELECT count(*) FROM kiroku.streams"
    events <- scalarInt store "SELECT count(*) FROM kiroku.events"
    subscriptions <- scalarInt store "SELECT count(*) FROM kiroku.subscriptions"
    unless (initial == 1 && events == 0 && subscriptions == 0) (fail "index research requires an empty isolated store")
    let ddl = case config.layout of
            "category-only" -> "" -- Original current schema; no replacement.
            "category-name" -> "CREATE INDEX ix_streams_category_name ON kiroku.streams(category,stream_name); DROP INDEX kiroku.ix_streams_category;"
            _ -> error "unvalidated layout"
    unless (Text.null ddl) $ session store (Session.script ddl)
    let names = [category <> "-" <> fixtureId n | category <- ["probe", "noise"], n <- [1 .. config.catalog]]
    session store $
        Session.statement names $
            preparable "INSERT INTO kiroku.streams(stream_name) SELECT unnest($1::text[])" (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text)))) D.noResult
    session store (Session.script "ANALYZE kiroku.streams")
    count <- scalarInt store "SELECT count(*) FROM kiroku.streams"
    unless (count == fromIntegral (2 * config.catalog + 1)) (fail "catalog fixture count differs")
    inventory <- snapshot store
    pure $ object ["layout" .= config.layout, "ddl" .= ddl, "catalog_per_category" .= config.catalog, "fixture" .= ("deterministic UUIDv7 TypeIDs; probe/noise categories" :: Text), "inventory" .= inventory]

-- Valid UUIDv7 version/variant and a sortable, deterministic 26-digit encoding.
-- Fixture timestamps are disjoint from append timestamps. This is not an ID API.
fixtureId :: Int -> Text
fixtureId serial =
    let value :: Integer
        value = ((1700000000000 + fromIntegral serial) `shiftL` 80) .|. (7 `shiftL` 76) .|. (2 `shiftL` 62) .|. fromIntegral serial
        alphabet = "0123456789abcdefghjkmnpqrstvwxyz"
     in "order_" <> Text.pack [alphabet !! fromIntegral ((value `shiftR` offset) .&. 31) | offset <- [125, 120 .. 0]]

streamName :: Int -> Int -> Int -> Bool -> StreamName
streamName writer slot iteration fresh =
    StreamName ("probe-" <> fixtureId (1000000 + (if fresh then iteration * 16 else 0) + writer * 4 + slot))

snapshot :: KirokuStore -> IO Json.Value
snapshot store =
    json store $
        "SELECT jsonb_build_object('stats_reset',(SELECT stats_reset FROM pg_stat_database WHERE datname=current_database()),"
            <> "'inserted',s.n_tup_ins,'updated',s.n_tup_upd,'hot_updated',s.n_tup_hot_upd,'newpage_updated',s.n_tup_newpage_upd,"
            <> "'stream_rows',(SELECT count(*) FROM kiroku.streams),'all_version',(SELECT stream_version FROM kiroku.streams WHERE stream_id=0),"
            <> "'table_bytes',pg_relation_size(s.relid),'indexes_bytes',pg_indexes_size(s.relid),"
            <> "'indexes',(SELECT jsonb_agg(jsonb_build_object('name',indexname,'definition',indexdef,'bytes',pg_relation_size((schemaname||'.'||indexname)::regclass)) ORDER BY indexname) FROM pg_indexes WHERE schemaname='kiroku' AND tablename='streams'),"
            <> "'append_statements',(SELECT COALESCE(jsonb_agg(jsonb_build_object('queryid',queryid::text,'query',query,'calls',calls,'exec_ms',total_exec_time,'wal_bytes',wal_bytes)), '[]'::jsonb) FROM public.pg_stat_statements WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database()) AND (query ILIKE '%UPDATE streams%' OR query ILIKE '%INSERT INTO streams%'))) "
            <> "FROM pg_stat_user_tables s WHERE schemaname='kiroku' AND relname='streams'"

-- Register once: raw sample paths cannot be reopened for each phase.
newBrowser :: Maybe Config -> Measure.Measurement -> IO (Maybe Recorder.WorkerRecorder)
newBrowser Nothing _ = pure Nothing
newBrowser (Just config) measurement
    | config.browseHz == 0 = pure Nothing
    | otherwise = Just <$> (Recorder.registerOp (Measure.measurementRecorder measurement) (Recorder.OpName "browse") >>= (`Recorder.newWorkerRecorder` 0))

withBrowser :: Maybe Config -> Maybe Recorder.WorkerRecorder -> KirokuStore -> IO a -> IO a
withBrowser (Just config) (Just recorder) store action = do
    begin <- getMonotonicTimeNSec
    Async.withAsync (loop begin 0) $ \reader -> Async.link reader >> action
  where
    late = "probe-" <> fixtureId (max 1 (config.catalog - 10))
    loop begin iteration = do
        let scheduled = begin + (iteration * 1000000000) `div` fromIntegral config.browseHz
        now <- getMonotonicTimeNSec
        when (scheduled > now) $ threadDelay (fromIntegral ((scheduled - now + 999) `div` 1000))
        forPages
        loop begin (iteration + 1)
    forPages = do
        page "probe" Nothing
        page "probe" (Just late)
        page "missing" Nothing
    page category cursor = do
        started <- getMonotonicTimeNSec
        rows <- case cursor of
            Nothing ->
                session store $
                    Session.statement category $
                        preparable "SELECT stream_name FROM kiroku.streams WHERE stream_id<>0 AND category=$1 ORDER BY stream_name LIMIT 11" (E.param (E.nonNullable E.text)) (D.rowList (D.column (D.nonNullable D.text)))
            Just after ->
                session store $
                    Session.statement (category, after) $
                        preparable
                            "SELECT stream_name FROM kiroku.streams WHERE stream_id<>0 AND category=$1 AND stream_name>$2 ORDER BY stream_name LIMIT 11"
                            (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)))
                            (D.rowList (D.column (D.nonNullable D.text)))
        finished <- getMonotonicTimeNSec
        unless (length rows <= 11 && all (Text.isPrefixOf (category <> "-")) rows) (fail "browse returned invalid category page")
        when (category == "missing") $ unless (null rows) (fail "absent category returned rows")
        Recorder.recordOp recorder started started finished (Recorder.OpOk (length rows))
withBrowser _ _ _ action = action

session :: KirokuStore -> Session.Session a -> IO a
session store request = Pool.use store.pool request >>= either (fail . show) pure

scalarInt :: KirokuStore -> Text -> IO Int64
scalarInt store sql = session store $ Session.statement () (preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))

json :: KirokuStore -> Text -> IO Json.Value
json store sql = session store $ Session.statement () (preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb))))
