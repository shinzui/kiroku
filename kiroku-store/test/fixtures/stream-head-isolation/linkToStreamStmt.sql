WITH
  event_list AS (
    SELECT event_id, idx
    FROM unnest($1::uuid[]) WITH ORDINALITY AS t(event_id, idx)
  ),
  stream_upsert AS (
    INSERT INTO streams (stream_name, stream_version)
    VALUES ($2, (SELECT count(*) FROM event_list))
    ON CONFLICT (stream_name)
    DO UPDATE SET stream_version = streams.stream_version + (SELECT count(*) FROM event_list)
      WHERE streams.deleted_at IS NULL
    RETURNING stream_id, stream_version - (SELECT count(*) FROM event_list) AS initial_version
  ),
  link_inserts AS (
    -- LEFT JOIN LATERAL surfaces missing-event rows as NULLs for original_*; the
    -- NOT NULL constraint on stream_events.original_stream_id then aborts the
    -- entire CTE, rolling back the stream_upsert's version bump. Before the F3
    -- fix this was a plain JOIN LATERAL, which silently dropped missing-event
    -- rows while still bumping stream_version → silent gap in the link target.
    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT el.event_id, su.stream_id, su.initial_version + el.idx,
           orig.original_stream_id, orig.original_stream_version
    FROM event_list el
    CROSS JOIN stream_upsert su
    LEFT JOIN LATERAL (
      SELECT se.original_stream_id, se.original_stream_version
      FROM stream_events se
      WHERE se.event_id = el.event_id AND se.stream_id <> 0
      LIMIT 1
    ) orig ON true
  )
SELECT su.stream_id, su.initial_version + (SELECT count(*) FROM event_list)
FROM stream_upsert su