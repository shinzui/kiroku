-- Benchmark 6 — Reader component for mixed read/write benchmark
--
-- pgbench usage:
--   pgbench -n -f bench_mixed_read.sql -t 2000 -c 8 -j 8 kiroku

\set start_pos random(0, 99900)

SELECT e.event_id, e.event_type, e.data, e.created_at,
       se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
WHERE se.stream_id = 0
  AND se.stream_version > :start_pos
ORDER BY se.stream_version ASC
LIMIT 100;
