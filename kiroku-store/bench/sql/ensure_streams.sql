-- Ensure benchmark streams exist for write benchmarks
-- Called by run_benchmarks.sh before each write benchmark

-- Kiroku objects live in the dedicated `kiroku` schema; resolve unqualified
-- names below for this psql session. (run_benchmarks.sh also exports PGOPTIONS,
-- but this keeps the file correct when run directly via `psql -f`.)
SET search_path TO kiroku, pg_catalog;

-- Streams for Benchmark 1 (single append)
INSERT INTO streams (stream_name)
SELECT 'bench-single-' || i FROM generate_series(0, 127) AS i
ON CONFLICT (stream_name) DO NOTHING;

-- Streams for Benchmark 2 (batch appends)
INSERT INTO streams (stream_name)
SELECT 'bench-batch10-' || i FROM generate_series(0, 127) AS i
ON CONFLICT (stream_name) DO NOTHING;

INSERT INTO streams (stream_name)
SELECT 'bench-batch100-' || i FROM generate_series(0, 127) AS i
ON CONFLICT (stream_name) DO NOTHING;

INSERT INTO streams (stream_name)
SELECT 'bench-batch1000-' || i FROM generate_series(0, 127) AS i
ON CONFLICT (stream_name) DO NOTHING;

-- Streams for Benchmark 3 & 4 (concurrent appends)
INSERT INTO streams (stream_name)
SELECT 'bench-concurrent-' || i FROM generate_series(0, 127) AS i
ON CONFLICT (stream_name) DO NOTHING;

-- Streams for Benchmark 6 (mixed write)
INSERT INTO streams (stream_name)
SELECT 'bench-mixed-writer-' || i FROM generate_series(0, 31) AS i
ON CONFLICT (stream_name) DO NOTHING;
