-- Ensure benchmark streams exist for write benchmarks
-- Called by run_benchmarks.sh before each write benchmark

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
