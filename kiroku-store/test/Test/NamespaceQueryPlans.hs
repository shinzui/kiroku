module Test.NamespaceQueryPlans (spec) where

import Control.Lens ((^.))
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import System.Environment (lookupEnv)
import Test.Helpers (withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "namespace production query bounds" $
  forM_ [1000, 20000 :: Int] $ \total ->
    it ("bounds generic/custom scans and payload probes on " <> show total <> " rows") $
      withTestStore $ \store -> do
        run store (Session.script (fixture total))
        forM_ ["force_custom_plan", "force_generic_plan"] $ \mode ->
          forM_ [32, 1024 :: Int] $ \width ->
            forM_ ["pm", "pm:sparse", "absent"] $ \namespace ->
              forM_ [0, total - 100] $ \cursor ->
                forM_ [False, True] $ \grouped -> do
                  let query = if grouped then Statement.toSql SQL.readNamespaceGroupWindowStmt else Statement.toSql SQL.readNamespaceWindowStmt
                      types = if grouped then "int8,int8,text,int4,int4,int4" else "int8,int8,text,int4"
                      args = T.intercalate "," [t cursor, t total, "'" <> namespace <> "'", t width] <> if grouped then ",0,3" else ""
                  bytes <- run store $ do
                    Session.script ("SET plan_cache_mode=" <> mode <> "; PREPARE namespace_probe(" <> types <> ") AS " <> query)
                    bytes <- Session.statement () (Statement.unpreparable ("EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,FORMAT JSON) EXECUTE namespace_probe(" <> args <> ")") E.noParams (D.singleRow (D.column (D.nonNullable (D.jsonBytes Right)))))
                    Session.script "DEALLOCATE namespace_probe; RESET plan_cache_mode"
                    pure bytes
                  plan <- either fail pure (Aeson.eitherDecodeStrict' bytes)
                  evidence <- lookupEnv "EP54_PLAN_EVIDENCE"
                  forM_ evidence $ \path ->
                    LBS.appendFile
                      path
                      ( Aeson.encode
                          ( Aeson.object
                              [ "rows" Aeson..= total,
                                "mode" Aeson..= mode,
                                "width" Aeson..= width,
                                "namespace" Aeson..= namespace,
                                "cursor" Aeson..= cursor,
                                "grouped" Aeson..= grouped,
                                "explain" Aeson..= plan
                              ]
                          )
                          <> "\n"
                      )
                  let scans = nodes plan
                      relation name = filter (\obj -> KM.lookup "Relation Name" obj == Just (String name)) scans
                      countRows name = sum [num "Actual Loops" obj * (num "Actual Rows" obj + num "Rows Removed by Filter" obj) | obj <- relation name]
                      payloads = sum [num "Actual Loops" obj * num "Actual Rows" obj | obj <- relation "events"]
                      caseLabel = T.unpack (mode <> "/" <> namespace <> "/W=" <> t width <> "/cursor=" <> t cursor <> "/group=" <> T.pack (show grouped))
                  let verify condition = unless condition (expectationFailure (caseLabel <> "\n" <> show [(KM.lookup "Relation Name" obj, KM.lookup "Node Type" obj, KM.lookup "Index Name" obj, num "Actual Rows" obj, num "Actual Loops" obj, num "Rows Removed by Filter" obj) | obj <- scans, KM.member "Relation Name" obj]))
                  verify (null (relation "streams"))
                  verify (countRows "stream_events" <= fromIntegral width)
                  verify ([index | obj <- relation "stream_events", Just (String index) <- [KM.lookup "Index Name" obj]] == ["ux_stream_events_stream_version"])
                  verify (payloads <= fromIntegral (min width (total - cursor)))
                  if namespace == "absent" then verify (payloads == 0) else pure ()
                  forM_ (relation "events") $ \obj ->
                    verify (num "Actual Loops" obj == 0 || KM.lookup "Node Type" obj == Just (String "Index Scan"))

fixture :: Int -> Text
fixture count =
  T.unlines
    [ "WITH source AS (INSERT INTO streams(stream_name,stream_version) SELECT (CASE WHEN n % 100 = 0 THEN 'pm:sparse-' ELSE 'pm:dense-' END) || n,1 FROM generate_series(1," <> t count <> ") n RETURNING stream_id),",
      "f AS MATERIALIZED (SELECT stream_id, row_number() OVER (ORDER BY stream_id) AS pos, uuidv7() AS id FROM source),",
      "e AS (INSERT INTO events(event_id,event_type,data) SELECT id,'Fixture','{}' FROM f RETURNING event_id),",
      "se AS (INSERT INTO stream_events(event_id,stream_id,stream_version,original_stream_id,original_stream_version) SELECT id,stream_id,1,stream_id,1 FROM f JOIN e ON event_id=id RETURNING event_id)",
      "INSERT INTO stream_events(event_id,stream_id,stream_version,original_stream_id,original_stream_version,category) SELECT id,0,pos,stream_id,1, CASE WHEN pos % 100 = 0 THEN 'pm:sparse' ELSE 'pm:dense' END FROM f JOIN se ON event_id=id;",
      "UPDATE streams SET stream_version=" <> t count <> " WHERE stream_id=0; ANALYZE streams; ANALYZE stream_events; ANALYZE events;"
    ]

nodes :: Value -> [Aeson.Object]
nodes (Object fields) = fields : concatMap nodes (KM.elems fields)
nodes (Array values) = concatMap nodes (V.toList values)
nodes _ = []

num :: Aeson.Key -> Aeson.Object -> Double
num key obj = case KM.lookup key obj of Just (Number n) -> realToFrac n; _ -> 0

t :: (Show a) => a -> Text
t = T.pack . show

run :: KirokuStore -> Session.Session a -> IO a
run store action = Pool.use (store ^. #pool) action >>= either (fail . show) pure
