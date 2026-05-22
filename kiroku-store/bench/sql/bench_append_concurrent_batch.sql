-- Benchmark 4: Cross-stream concurrent batched appends (10 events per CTE)
--
-- pgbench usage (vary -c and -j for concurrency levels):
--   PGOPTIONS="-c search_path=kiroku,pg_catalog" pgbench -n -f bench_append_concurrent_batch.sql -t 1000 -c 4  -j 4  kiroku
--   PGOPTIONS="-c search_path=kiroku,pg_catalog" pgbench -n -f bench_append_concurrent_batch.sql -t 1000 -c 8  -j 8  kiroku
--   PGOPTIONS="-c search_path=kiroku,pg_catalog" pgbench -n -f bench_append_concurrent_batch.sql -t 1000 -c 16 -j 16 kiroku
--   PGOPTIONS="-c search_path=kiroku,pg_catalog" pgbench -n -f bench_append_concurrent_batch.sql -t 1000 -c 32 -j 32 kiroku
--
-- Each client writes 10 events to its own stream per iteration.
-- Target: > 30K events/s at 16 connections.

WITH
  new_events AS (
    SELECT
        uuidv7() AS event_id,
        'BenchmarkEvent' AS event_type,
        NULL::uuid AS causation_id,
        NULL::uuid AS correlation_id,
        jsonb_build_object('bench', 'concurrent_batch', 'idx', g) AS data,
        NULL::jsonb AS metadata,
        now() AS created_at,
        g AS idx
    FROM generate_series(1, 10) AS g
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
