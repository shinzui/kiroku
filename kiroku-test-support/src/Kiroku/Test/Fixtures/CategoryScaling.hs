{- | A seeded store shape for measuring how category reads scale with the
number of streams in a category.

The fixture writes junction rows directly, in the shape the append
statements produce, so tens of thousands of streams load in well under a
second. It seeds three categories, each occupying a contiguous range of
global positions:

* @performance@: 200 streams with 100 events each, positions 1 to 20,000.
* @idle@: 20,000 streams with one event each, positions 20,001 to 40,000.
* @noise@: 100 streams with 400 events each, positions 40,001 to 80,000.

The @$all@ stream's version is advanced to 'categoryScalingHead', so a read
at that cursor is a caught-up poll: it returns nothing, and its cost is the
fixed cost of asking.

Run it against a freshly migrated database through a connection whose
@search_path@ reaches the @kiroku@ schema (every 'Kiroku.Store' pool does).
-}
module Kiroku.Test.Fixtures.CategoryScaling (
    categoryScalingFixtureSql,
    categoryScalingHead,
) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T

-- | The global head position after 'categoryScalingFixtureSql' runs.
categoryScalingHead :: Int64
categoryScalingHead = 80_000

-- | Seed the three categories in one transaction, then @ANALYZE@ the tables.
categoryScalingFixtureSql :: Text
categoryScalingFixtureSql =
    T.unlines
        [ "BEGIN;"
        , seedCategory "performance" 200 100 0
        , seedCategory "idle" 20_000 1 20_000
        , seedCategory "noise" 100 400 40_000
        , "UPDATE streams SET stream_version = " <> showT categoryScalingHead <> " WHERE stream_id = 0;"
        , "COMMIT;"
        , "ANALYZE streams;"
        , "ANALYZE events;"
        , "ANALYZE stream_events;"
        ]

{- | One statement that creates @streamCount@ streams named @category-N@,
@eventsPerStream@ events in each, and the home and @$all@ junction rows for
every event. Global positions start after @positionOffset@ and interleave the
streams round-robin, the order concurrent writers would produce.
-}
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
        , "  SELECT event_id, 'CategoryScalingFixture', '{}'::jsonb"
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
