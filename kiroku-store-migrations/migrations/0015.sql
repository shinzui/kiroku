-- Stable byte-ordered stream catalog browsing (MasterPlan 13 / plan 88).
-- The original unique-name constraint and category index remain unchanged.
-- This one browse index also serves literal prefixes and exact-category ranges;
-- plan 54's bounded global-event windows require no separate prefix index.
-- PostgreSQL applies this transactional index build once. It blocks writes for
-- the build duration; schedule the upgrade in a maintenance window on large
-- stores. New-stream inserts and non-HOT application-stream updates pay its
-- maintenance cost. The reserved global stream is outside this partial index.
CREATE INDEX ix_streams_browse_name
    ON kiroku.streams (stream_name COLLATE "C")
    WHERE stream_id <> 0;

COMMENT ON INDEX kiroku.ix_streams_browse_name IS
    'Byte-ordered stream browsing and literal-prefix seeks; does not change unique-name or subscription event ordering.';
COMMENT ON SCHEMA kiroku IS
    'Managed by pg-migrate component kiroku through 0015';
