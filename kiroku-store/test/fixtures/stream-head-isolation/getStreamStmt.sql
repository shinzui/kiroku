SELECT stream_id, stream_name, stream_version, created_at, deleted_at, truncate_before
FROM streams
WHERE stream_name = $1