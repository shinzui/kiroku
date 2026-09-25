-- denormalize category onto $all junction rows for category reads

-- Category reads (readCategoryForwardSQL and its consumer-group variant in
-- kiroku-store) used to start from every stream of the category and probe
-- stream_events once per stream, so a caught-up poll cost work proportional to
-- the number of streams ever written in the category (BUG-2). Carrying the
-- originating stream's category on each $all junction row lets both reads run
-- as one index range scan from (category, checkpoint) that stops at the limit.
--
-- The column is populated only on $all rows (stream_id = 0). Home rows and link
-- rows keep it NULL; nothing reads them by category. The CHECK below makes any
-- inserter that forgets the column fail loudly instead of writing rows that a
-- category read cannot see.
--
-- The whole file runs in one transaction. The backfill rewrites every $all row
-- and the index build blocks writes, so appends wait for the duration; apply it
-- in a maintenance window on a large store and VACUUM (ANALYZE)
-- kiroku.stream_events afterwards.

ALTER TABLE kiroku.stream_events
    ADD COLUMN category TEXT;

COMMENT ON COLUMN kiroku.stream_events.category IS
  'Originating stream''s category, present on $all rows (stream_id = 0) only; equals streams.category of original_stream_id.';

-- Backfill every existing $all row from its originating stream. The immutability
-- trigger rejects every UPDATE on this table, so it is suspended for this one
-- statement and re-enabled before the transaction ends. Runs as the table owner.
ALTER TABLE kiroku.stream_events DISABLE TRIGGER no_update_stream_events;

UPDATE kiroku.stream_events AS se
SET category = s.category
FROM kiroku.streams AS s
WHERE se.stream_id = 0
  AND s.stream_id = se.original_stream_id;

ALTER TABLE kiroku.stream_events ENABLE TRIGGER no_update_stream_events;

ALTER TABLE kiroku.stream_events
    ADD CONSTRAINT ck_stream_events_all_category
    CHECK (stream_id <> 0 OR category IS NOT NULL);

-- Category read path: rows of one category in global-position order. The
-- INCLUDE column lets the consumer-group hash predicate run on index tuples.
CREATE INDEX ix_stream_events_all_by_category
    ON kiroku.stream_events (category, stream_version)
    INCLUDE (original_stream_id)
    WHERE stream_id = 0;

COMMENT ON SCHEMA kiroku IS
  'Managed by pg-migrate component kiroku through 0012';
