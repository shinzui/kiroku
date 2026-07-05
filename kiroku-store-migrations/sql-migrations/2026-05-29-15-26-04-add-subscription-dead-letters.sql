-- Add the kiroku.dead_letters table (MasterPlan 6 / EP-2, docs/plans/40-...).
--
-- Forward, additive migration: codd applies this file once, records it, and
-- skips it on later runs. It does not edit the bootstrap migration and does not
-- mutate existing event data.
--
-- A dead-letter row records one event that a subscription handler asked to
-- "dead-letter" (return DeadLetter, or exhaust its bounded retry budget). The
-- event itself stays immutable in kiroku.events; this table references it by
-- event_id and global_position rather than copying the payload. The
-- consumer_group_member column (default 0, matching kiroku.subscriptions)
-- attributes the row to the member that produced it, so a consumer group's dead
-- letters are per-member. The worker writes a row and advances the member's
-- checkpoint in one atomic statement (see SQL.insertDeadLetterAndCheckpointStmt).

CREATE TABLE IF NOT EXISTS kiroku.dead_letters (
    dead_letter_id        BIGSERIAL    PRIMARY KEY,
    subscription_name     TEXT         NOT NULL,
    consumer_group_member INT          NOT NULL DEFAULT 0,
    global_position       BIGINT       NOT NULL,
    event_id              UUID         NOT NULL REFERENCES kiroku.events(event_id),
    reason                JSONB        NOT NULL,
    reason_summary        TEXT         NOT NULL,
    attempt_count         INT          NOT NULL,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (subscription_name, consumer_group_member, global_position, event_id)
);

-- Operator read path: list a subscription member's dead letters by recency.
CREATE INDEX IF NOT EXISTS ix_dead_letters_subscription_created_at
    ON kiroku.dead_letters (subscription_name, consumer_group_member, created_at);
