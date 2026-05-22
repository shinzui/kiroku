-- Benchmark 1: Single-stream sequential append (1 event per CTE)
--
-- pgbench usage:
--   PGOPTIONS="-c search_path=kiroku,pg_catalog" pgbench -n -f bench_append_single.sql -t 10000 -c 1 kiroku
--
-- This uses append_any_version semantics to avoid version tracking in pgbench.
-- Each iteration creates a fresh stream to avoid version conflicts.

WITH
  new_events AS (
    SELECT *
    FROM unnest(
        ARRAY[uuidv7()]::uuid[],
        ARRAY['BenchmarkEvent']::text[],
        ARRAY[NULL]::uuid[],
        ARRAY[NULL]::uuid[],
        ARRAY['{"bench": "single_append", "iter": 1}']::jsonb[],
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
    WHERE stream_name = 'bench-single-' || :client_id
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
