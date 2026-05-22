-- Reset benchmark data between runs
-- Deletes all events and resets stream versions without dropping schema

-- Kiroku objects live in the dedicated `kiroku` schema; resolve unqualified
-- names below for this psql session. (run_benchmarks.sh also exports PGOPTIONS,
-- but this keeps the file correct when run directly via `psql -f`.)
SET search_path TO kiroku, pg_catalog;

BEGIN;
SET LOCAL kiroku.enable_hard_deletes = 'on';

DELETE FROM stream_events;
DELETE FROM events;
DELETE FROM streams WHERE stream_id != 0;
UPDATE streams SET stream_version = 0 WHERE stream_id = 0;

COMMIT;

-- Reset the sequence
SELECT setval('streams_stream_id_seq', 1);
