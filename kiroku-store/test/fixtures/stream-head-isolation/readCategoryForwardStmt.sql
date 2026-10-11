SELECT e.event_id, e.event_type,
       se.stream_version, se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id,
       e.created_at
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
WHERE se.stream_id = 0
  AND se.category = $2
  AND se.stream_version > $1
ORDER BY se.stream_version ASC
LIMIT $3