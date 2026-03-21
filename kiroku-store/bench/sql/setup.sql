-- Benchmark data setup
-- Creates test streams and pre-populates data for read benchmarks

-- Clean up any previous benchmark data
BEGIN;
SET LOCAL kiroku.enable_hard_deletes = 'on';

DELETE FROM stream_events WHERE stream_id != 0;
DELETE FROM stream_events WHERE stream_id = 0;
DELETE FROM events;
DELETE FROM streams WHERE stream_id != 0;
UPDATE streams SET stream_version = 0 WHERE stream_id = 0;

COMMIT;

-- Reset the sequence past reserved stream_id=0
SELECT setval('streams_stream_id_seq', 1);

-- Create streams for sequential benchmarks (Benchmark 1 & 2)
INSERT INTO streams (stream_uuid) VALUES ('bench-sequential-single')
ON CONFLICT (stream_uuid) DO NOTHING;

INSERT INTO streams (stream_uuid) VALUES ('bench-sequential-batch-10')
ON CONFLICT (stream_uuid) DO NOTHING;

INSERT INTO streams (stream_uuid) VALUES ('bench-sequential-batch-100')
ON CONFLICT (stream_uuid) DO NOTHING;

INSERT INTO streams (stream_uuid) VALUES ('bench-sequential-batch-1000')
ON CONFLICT (stream_uuid) DO NOTHING;

-- Create streams for concurrent benchmarks (Benchmark 3 & 4)
INSERT INTO streams (stream_uuid)
SELECT 'bench-concurrent-' || i
FROM generate_series(0, 127) AS i
ON CONFLICT (stream_uuid) DO NOTHING;

-- Populate 100K events across 100 streams for read benchmarks (Benchmark 5 & 6)
DO $$
DECLARE
    v_stream_uuid TEXT;
    v_stream_id BIGINT;
    v_batch_size INT := 100;
    v_batches INT := 10;  -- 10 batches × 100 events × 100 streams = 100K events
    v_event_ids UUID[];
    v_event_types TEXT[];
    v_causation_ids UUID[];
    v_correlation_ids UUID[];
    v_data JSONB[];
    v_metadata JSONB[];
    v_created_at TIMESTAMPTZ[];
    v_stream_version BIGINT;
    v_all_version BIGINT;
BEGIN
    -- Create 100 read-bench streams across 10 categories
    FOR i IN 0..99 LOOP
        v_stream_uuid := 'benchcat' || (i / 10) || '-' || i;
        INSERT INTO streams (stream_uuid) VALUES (v_stream_uuid)
        ON CONFLICT (stream_uuid) DO NOTHING;
    END LOOP;

    -- Populate each stream with events
    FOR i IN 0..99 LOOP
        v_stream_uuid := 'benchcat' || (i / 10) || '-' || i;

        SELECT stream_id INTO v_stream_id FROM streams WHERE stream_uuid = v_stream_uuid;

        FOR batch IN 1..v_batches LOOP
            -- Build arrays for this batch
            SELECT
                array_agg(uuidv7()),
                array_agg('BenchmarkEvent'::text),
                array_agg(NULL::uuid),
                array_agg(NULL::uuid),
                array_agg(jsonb_build_object('stream', i, 'batch', batch, 'idx', g, 'value', md5(random()::text))),
                array_agg(NULL::jsonb),
                array_agg(now()::timestamptz)
            INTO v_event_ids, v_event_types, v_causation_ids, v_correlation_ids, v_data, v_metadata, v_created_at
            FROM generate_series(1, v_batch_size) AS g;

            -- Get current versions
            SELECT stream_version INTO v_stream_version FROM streams WHERE stream_id = v_stream_id;
            SELECT stream_version INTO v_all_version FROM streams WHERE stream_id = 0;

            -- Insert events
            INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
            SELECT unnest(v_event_ids), unnest(v_event_types), unnest(v_causation_ids),
                   unnest(v_correlation_ids), unnest(v_data), unnest(v_metadata), unnest(v_created_at);

            -- Link to source stream
            INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
            SELECT v_event_ids[g], v_stream_id, v_stream_version + g, v_stream_id, v_stream_version + g
            FROM generate_series(1, v_batch_size) AS g;

            -- Link to $all
            INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
            SELECT v_event_ids[g], 0, v_all_version + g, v_stream_id, v_stream_version + g
            FROM generate_series(1, v_batch_size) AS g;

            -- Update versions
            UPDATE streams SET stream_version = stream_version + v_batch_size WHERE stream_id = v_stream_id;
            UPDATE streams SET stream_version = stream_version + v_batch_size WHERE stream_id = 0;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'Setup complete: 100 streams × 1000 events = % total events',
        (SELECT stream_version FROM streams WHERE stream_id = 0);
END $$;

-- Verify setup
SELECT 'streams' AS entity, count(*) AS count FROM streams
UNION ALL
SELECT 'events', count(*) FROM events
UNION ALL
SELECT 'stream_events', count(*) FROM stream_events
UNION ALL
SELECT '$all version', stream_version FROM streams WHERE stream_id = 0;
