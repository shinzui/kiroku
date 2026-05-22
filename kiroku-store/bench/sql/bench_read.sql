-- Benchmark 5: Combined read throughput (cycles through read types)
--
-- NOTE: pgbench \if doesn't support variable comparison well.
-- Use the individual scripts (bench_read_stream.sql, bench_read_all.sql,
-- bench_read_category.sql) for isolated measurements.
--
-- This script does a $all read as the default combined benchmark,
-- since it's the most representative read path.
--
-- pgbench usage:
--   PGOPTIONS="-c search_path=kiroku,pg_catalog" pgbench -n -f bench_read.sql -t 5000 -c 1 kiroku

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
