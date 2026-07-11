-- Index hygiene and $all hot-row tuning (MasterPlan 9 / EP-5, docs/plans/60-...).

-- 1. ix_events_event_type is referenced by no statement in kiroku-store; it is
--    pure write amplification on every append. Server-side event-type pushdown
--    (see the EventTypeFilter haddock in kiroku-store) should re-add a
--    fit-for-purpose index when it ships.
DROP INDEX IF EXISTS kiroku.ix_events_event_type;

-- 2. Stream versions are unique per stream by construction (assigned under the
--    stream row lock; $all versions are the global position). Enforce it so a
--    version-assignment bug surfaces as a loud 23505 instead of silent
--    duplicates. Built as a new unique index, then the old non-unique index is
--    dropped (an index cannot be altered to unique in place).
CREATE UNIQUE INDEX IF NOT EXISTS ux_stream_events_stream_version
    ON kiroku.stream_events (stream_id, stream_version);
DROP INDEX IF EXISTS kiroku.ix_stream_events_stream_version;

-- 3. readDeadLetters orders by (global_position DESC, dead_letter_id DESC) --
--    the store's canonical, deterministic "newest first". Re-key the read
--    index to match so the read is index-ordered instead of sorting each time.
CREATE INDEX IF NOT EXISTS ix_dead_letters_subscription_position
    ON kiroku.dead_letters
       (subscription_name, consumer_group_member,
        global_position DESC, dead_letter_id DESC);
DROP INDEX IF EXISTS kiroku.ix_dead_letters_subscription_created_at;

-- 4. The $all row (stream_id 0) is updated by every append in the database.
--    Its updated column (stream_version) is not indexed, so updates are
--    HOT-eligible when the page has free space; fillfactor 50 reserves that
--    space on newly written pages. Existing pages converge through normal
--    update/prune activity (VACUUM cannot run inside this migration's
--    transaction). Autovacuum tuning for this table is left to operators.
ALTER TABLE kiroku.streams SET (fillfactor = 50);
