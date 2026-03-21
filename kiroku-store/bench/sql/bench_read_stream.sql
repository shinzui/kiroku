-- Benchmark 5a: Stream read only (for isolated measurement)
--
-- pgbench usage:
--   pgbench -n -f bench_read_stream.sql -t 5000 -c 1 kiroku

\set stream_num random(0, 99)
\set start_version random(0, 900)

SELECT e.event_id, e.event_type, e.data, e.created_at,
       se.stream_version, se.original_stream_id, se.original_stream_version
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
JOIN streams s ON s.stream_id = se.stream_id
WHERE s.stream_uuid = 'benchcat' || (:stream_num / 10) || '-' || :stream_num
  AND se.stream_version > :start_version
ORDER BY se.stream_version ASC
LIMIT 100;
