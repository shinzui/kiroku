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
    RETURNING stream_id, category, stream_version - (SELECT count(*) FROM new_events) AS initial_version
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
    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version, category)
    SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx, su.category
    FROM new_events ne
    CROSS JOIN all_update au
    CROSS JOIN stream_upsert su
  )
SELECT su.stream_id,
       su.initial_version + (SELECT count(*) FROM new_events),
       au.initial_global_version + (SELECT count(*) FROM new_events)
FROM stream_upsert su
CROSS JOIN all_update au