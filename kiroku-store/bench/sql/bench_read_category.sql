-- Benchmark 5c: Category read only (for isolated measurement)
-- Uses LATERAL join to force the planner to use the partial index
-- ix_stream_events_all_by_origin per category stream, then merge+sort.
--
-- pgbench usage:
--   pgbench -n -f bench_read_category.sql -t 1000 -c 1 kiroku

\set category_num random(0, 9)
\set start_pos random(0, 99000)

SELECT e.event_id, e.event_type, e.data, e.created_at,
       se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version
FROM streams s
JOIN LATERAL (
    SELECT se.*
    FROM stream_events se
    WHERE se.stream_id = 0
      AND se.original_stream_id = s.stream_id
      AND se.stream_version > :start_pos
    ORDER BY se.stream_version ASC
    LIMIT 100
) se ON true
JOIN events e ON e.event_id = se.event_id
WHERE s.category = 'benchcat' || :category_num
ORDER BY se.stream_version ASC
LIMIT 100;
