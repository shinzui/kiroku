-- Reset benchmark data between runs
-- Deletes all events and resets stream versions without dropping schema

BEGIN;
SET LOCAL kiroku.enable_hard_deletes = 'on';

DELETE FROM stream_events;
DELETE FROM events;
DELETE FROM streams WHERE stream_id != 0;
UPDATE streams SET stream_version = 0 WHERE stream_id = 0;

COMMIT;

-- Reset the sequence
SELECT setval('streams_stream_id_seq', 1);
