WITH
  new_events AS (
    SELECT *
    FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
    WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
  ),
  stream_insert AS (
    INSERT INTO streams (stream_name, stream_version)
    VALUES ($8, (SELECT count(*) FROM new_events))
    ON CONFLICT (stream_name) DO NOTHING
    RETURNING stream_id, category, 0::bigint AS initial_version
  ),
  inserted_events AS (
    INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
    SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
    FROM new_events
    WHERE EXISTS (SELECT 1 FROM stream_insert)
    ORDER BY idx
  ),
  source_links AS (
    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT ne.event_id, si.stream_id, si.initial_version + ne.idx, si.stream_id, si.initial_version + ne.idx
    FROM new_events ne
    CROSS JOIN stream_insert si
  ),
  all_update AS (
    UPDATE streams
    SET stream_version = stream_version + (SELECT count(*) FROM new_events)
    WHERE stream_id = 0
      AND EXISTS (SELECT 1 FROM stream_insert)
    RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
  ),
  all_links AS (
    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version, category)
    SELECT ne.event_id, 0, au.initial_global_version + ne.idx, si.stream_id, si.initial_version + ne.idx, si.category
    FROM new_events ne
    CROSS JOIN all_update au
    CROSS JOIN stream_insert si
  )
SELECT si.stream_id,
       si.initial_version + (SELECT count(*) FROM new_events),
       au.initial_global_version + (SELECT count(*) FROM new_events)
FROM stream_insert si
CROSS JOIN all_update au