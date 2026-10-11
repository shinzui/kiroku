SELECT e.event_id, e.event_type,
       se.stream_version, 0::bigint AS global_position,
       se.original_stream_id, se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id,
       e.created_at
FROM stream_events se
JOIN events e  ON e.event_id  = se.event_id
JOIN streams s ON s.stream_id = se.stream_id
WHERE s.stream_name = $1
  AND s.deleted_at IS NULL
  AND se.stream_version > $2
  AND se.stream_version >= s.truncate_before
ORDER BY se.stream_version ASC
LIMIT $3