-- Index dead_letters by event_id (MasterPlan 9 / EP-5, docs/plans/60-...).
--
-- dead_letters.event_id has a FK to kiroku.events. The UNIQUE key leads with
-- subscription_name, so every referential-integrity check triggered by a
-- DELETE on kiroku.events (the hard-delete path) was a sequential scan of
-- dead_letters, and the hard-delete transaction's own dead-letter pre-delete
-- (Kiroku.Store.SQL.deleteDeadLettersForOrphanedEventsStmt) needs the same
-- access path.
CREATE INDEX IF NOT EXISTS ix_dead_letters_event_id
    ON kiroku.dead_letters (event_id);
