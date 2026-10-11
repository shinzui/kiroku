-- | Disposable 200,000-event fixture for stream-head query and runner costs.
module Kiroku.Test.Fixtures.StreamHead (streamHeadFixtureSql) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T

{- | 1,000 interleaved 100-event streams and one 100,000-event stream.
Vacuum separately, outside the transaction, before measuring.
-}
streamHeadFixtureSql :: Text
streamHeadFixtureSql =
    T.unlines
        [ "BEGIN;"
        , seedCategory "bench" 1000 100 0
        , seedCategory "long" 1 100000 100000
        , "UPDATE streams SET stream_version = 200000 WHERE stream_id = 0;"
        , "INSERT INTO streams(stream_name) VALUES ('empty-1');"
        , "COMMIT;"
        , "ANALYZE streams; ANALYZE events; ANALYZE stream_events;"
        ]

seedCategory :: Text -> Int -> Int -> Int64 -> Text
seedCategory category streamCount eventsPerStream positionOffset =
    T.unlines
        [ "WITH new_streams AS ("
        , "  INSERT INTO streams (stream_name, stream_version)"
        , "  SELECT '" <> category <> "-' || n::text, " <> showT eventsPerStream
        , "  FROM generate_series(1, " <> showT streamCount <> ") AS n"
        , "  RETURNING stream_id, category"
        , "), fixture_events AS MATERIALIZED ("
        , "  SELECT uuidv7() AS event_id,"
        , "         s.stream_id,"
        , "         s.category,"
        , "         per_stream_position::bigint AS stream_version,"
        , "         " <> showT positionOffset <> " + row_number() OVER (ORDER BY per_stream_position, s.stream_id)::bigint AS global_position"
        , "  FROM new_streams AS s"
        , "  CROSS JOIN generate_series(1, " <> showT eventsPerStream <> ") AS per_stream_position"
        , "), inserted_events AS ("
        , "  INSERT INTO events (event_id, event_type, data)"
        , "  SELECT event_id, 'StreamHeadFixture', '{}'::jsonb"
        , "  FROM fixture_events"
        , "  RETURNING event_id"
        , "), source_links AS ("
        , "  INSERT INTO stream_events"
        , "    (event_id, stream_id, stream_version, original_stream_id, original_stream_version)"
        , "  SELECT f.event_id, f.stream_id, f.stream_version, f.stream_id, f.stream_version"
        , "  FROM fixture_events AS f"
        , "  JOIN inserted_events USING (event_id)"
        , "  RETURNING event_id"
        , "), all_links AS ("
        , "  INSERT INTO stream_events"
        , "    (event_id, stream_id, stream_version, original_stream_id, original_stream_version, category)"
        , "  SELECT f.event_id, 0, f.global_position, f.stream_id, f.stream_version, f.category"
        , "  FROM fixture_events AS f"
        , "  JOIN inserted_events USING (event_id)"
        , "  RETURNING event_id"
        , ")"
        , "SELECT (SELECT count(*) FROM source_links), (SELECT count(*) FROM all_links);"
        ]

showT :: (Show a) => a -> Text
showT = T.pack . show
