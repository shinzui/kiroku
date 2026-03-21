-- Benchmark 3: Cross-stream concurrent single-event appends ($all contention)
--
-- pgbench usage (vary -c and -j for concurrency levels):
--   pgbench -n -f bench_append_concurrent.sql -t 1000 -c 4  -j 4  kiroku
--   pgbench -n -f bench_append_concurrent.sql -t 1000 -c 8  -j 8  kiroku
--   pgbench -n -f bench_append_concurrent.sql -t 1000 -c 16 -j 16 kiroku
--   pgbench -n -f bench_append_concurrent.sql -t 1000 -c 32 -j 32 kiroku
--   pgbench -n -f bench_append_concurrent.sql -t 1000 -c 64 -j 64 kiroku
--
-- Each client writes to its own stream (bench-concurrent-N) to isolate
-- source stream contention. The $all row (stream_id=0) is the shared
-- contention point — this is the critical test for Strategy E.

WITH
  new_events AS (
    SELECT *
    FROM unnest(
        ARRAY[uuidv7()]::uuid[],
        ARRAY['BenchmarkEvent']::text[],
        ARRAY[NULL]::uuid[],
        ARRAY[NULL]::uuid[],
        ARRAY['{"bench": "concurrent_single"}']::jsonb[],
        ARRAY[NULL]::jsonb[],
        ARRAY[now()]::timestamptz[]
    ) WITH ORDINALITY AS t(
        event_id, event_type, causation_id, correlation_id,
        data, metadata, created_at, idx
    )
  ),

  stream_update AS (
    UPDATE streams
    SET stream_version = stream_version + (SELECT count(*) FROM new_events)
    WHERE stream_name = 'bench-concurrent-' || :client_id
    RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
  ),

  inserted_events AS (
    INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
    SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
    FROM new_events
    WHERE EXISTS (SELECT 1 FROM stream_update)
    ORDER BY idx
  ),

  source_links AS (
    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx
    FROM new_events ne
    CROSS JOIN stream_update su
  ),

  all_update AS (
    UPDATE streams
    SET stream_version = stream_version + (SELECT count(*) FROM new_events)
    WHERE stream_id = 0
      AND EXISTS (SELECT 1 FROM stream_update)
    RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
  ),

  all_links AS (
    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
    FROM new_events ne
    CROSS JOIN all_update au
    CROSS JOIN stream_update su
  )

SELECT
    su.stream_id,
    su.initial_version + (SELECT count(*) FROM new_events) AS stream_version,
    au.initial_global_version + (SELECT count(*) FROM new_events) AS global_position
FROM stream_update su
CROSS JOIN all_update au;
