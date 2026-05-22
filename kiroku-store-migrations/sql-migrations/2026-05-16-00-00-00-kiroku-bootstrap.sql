-- Kiroku Store bootstrap migration (codd)
-- Supports PostgreSQL 17+.
--
-- This file is the production-migration projection of
-- `kiroku-store/sql/schema.sql` with that file's `__KIROKU_SCHEMA__` token
-- resolved to the literal `kiroku`. codd applies it verbatim, so unlike the
-- development bootstrap there is no runtime sentinel substitution. Keep the two
-- files in sync: when `schema.sql` changes, regenerate this file with
--   sed 's/__KIROKU_SCHEMA__/kiroku/g' kiroku-store/sql/schema.sql
-- and restore this header.
--
-- All Kiroku-owned objects live in the dedicated `kiroku` schema, leaving
-- `public` free for application objects. Creating the schema and setting
-- search_path first means every unqualified object name in the rest of this
-- file resolves into the Kiroku schema.
CREATE SCHEMA IF NOT EXISTS kiroku;
SET search_path TO kiroku, pg_catalog;

-- PostgreSQL 18 provides pg_catalog.uuidv7(); PostgreSQL 17 needs this
-- Kiroku-schema fallback before events.event_id DEFAULT uuidv7() is parsed.
-- With search_path set above, the unqualified CREATE FUNCTION lands in the
-- Kiroku schema, and to_regprocedure('uuidv7()') resolves through search_path
-- (pg_catalog first for the built-in, then the Kiroku schema for the fallback).
DO $$
BEGIN
    IF to_regprocedure('pg_catalog.uuidv7()') IS NULL
       AND to_regprocedure('uuidv7()') IS NULL THEN
        EXECUTE $fn$
            CREATE FUNCTION uuidv7()
            RETURNS uuid
            AS $body$
            DECLARE
                unix_ts_ms bytea;
                uuid_bytes bytea;
            BEGIN
                unix_ts_ms = substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3);
                uuid_bytes = uuid_send(gen_random_uuid());
                uuid_bytes = overlay(uuid_bytes placing unix_ts_ms from 1 for 6);
                uuid_bytes = set_byte(uuid_bytes, 6, (b'0111' || get_byte(uuid_bytes, 6)::bit(4))::bit(8)::int);
                RETURN encode(uuid_bytes, 'hex')::uuid;
            END
            $body$
            LANGUAGE plpgsql
            VOLATILE
        $fn$;
    END IF;
END
$$;

-- Streams (including $all as stream_id = 0)
CREATE TABLE IF NOT EXISTS streams (
    stream_id    BIGSERIAL    PRIMARY KEY,
    stream_name  TEXT         NOT NULL,
    category     TEXT         GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED,
    stream_version BIGINT     NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    CONSTRAINT ix_streams_stream_name UNIQUE (stream_name)
);

-- Seed the $all stream
INSERT INTO streams (stream_id, stream_name, stream_version)
VALUES (0, '$all', 0)
ON CONFLICT DO NOTHING;

-- Reset sequence past the reserved stream_id=0
SELECT setval('streams_stream_id_seq', GREATEST((SELECT MAX(stream_id) FROM streams), 1));

-- Events (flat table — stream membership tracked in stream_events)
CREATE TABLE IF NOT EXISTS events (
    event_id       UUID         PRIMARY KEY DEFAULT uuidv7(),
    event_type     TEXT         NOT NULL,
    causation_id   UUID,
    correlation_id UUID,
    data           JSONB        NOT NULL,
    metadata       JSONB,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Stream-event junction (each event gets 2+ rows: source stream + $all + any links)
CREATE TABLE IF NOT EXISTS stream_events (
    event_id                UUID   NOT NULL REFERENCES events(event_id),
    stream_id               BIGINT NOT NULL REFERENCES streams(stream_id),
    stream_version          BIGINT NOT NULL,
    original_stream_id      BIGINT NOT NULL,
    original_stream_version BIGINT NOT NULL,
    PRIMARY KEY (event_id, stream_id)
);

-- Indexes

-- Primary read path: fetch events from a stream in order
CREATE INDEX IF NOT EXISTS ix_stream_events_stream_version
    ON stream_events (stream_id, stream_version);

-- Event type filtering (for server-side subscription filtering)
CREATE INDEX IF NOT EXISTS ix_events_event_type
    ON events (event_type);

-- Correlation tracing
CREATE INDEX IF NOT EXISTS ix_events_correlation_id
    ON events (correlation_id) WHERE correlation_id IS NOT NULL;

-- Causation tracing
CREATE INDEX IF NOT EXISTS ix_events_causation_id
    ON events (causation_id) WHERE causation_id IS NOT NULL;

-- Category filtering (for readCategory — uses generated column, not LIKE)
CREATE INDEX IF NOT EXISTS ix_streams_category
    ON streams (category);

-- Category read path: find $all entries by originating stream, ordered by global position
-- Enables efficient category reads by allowing the planner to: look up category stream_ids →
-- index scan $all for each → merge ordered by stream_version
CREATE INDEX IF NOT EXISTS ix_stream_events_all_by_origin
    ON stream_events (original_stream_id, stream_version)
    WHERE stream_id = 0;

-- Subscriptions (checkpoint persistence for subscription positions).
-- consumer_group_member / consumer_group_size carry static consumer-group
-- topology (ExecPlan 28 / EP-1). Non-group subscriptions are member 0, size 1.
-- The unique key is composite (subscription_name, consumer_group_member) so each
-- group member persists its own checkpoint under one shared subscription name.
CREATE TABLE IF NOT EXISTS subscriptions (
    subscription_id       BIGSERIAL    PRIMARY KEY,
    subscription_name     TEXT         NOT NULL,
    stream_name           TEXT         NOT NULL DEFAULT '$all',
    last_seen             BIGINT       NOT NULL DEFAULT 0,
    consumer_group_member INT          NOT NULL DEFAULT 0,
    consumer_group_size   INT          NOT NULL DEFAULT 1,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Idempotent convergence for databases created before EP-1: add the columns if
-- missing, drop the old auto-named single-column unique constraint if present,
-- and install the composite unique index. All guarded so re-running schema.sql
-- (which initializeSchema does on every store open) is a safe no-op.
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS consumer_group_member INT NOT NULL DEFAULT 0;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS consumer_group_size   INT NOT NULL DEFAULT 1;
ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS subscriptions_subscription_name_key;
CREATE UNIQUE INDEX IF NOT EXISTS ix_subscriptions_name_member
    ON subscriptions (subscription_name, consumer_group_member);

-- Triggers

-- NOTIFY on stream changes (fires once per append, not per event)
CREATE OR REPLACE FUNCTION notify_events() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        TG_TABLE_SCHEMA || '.events',
        NEW.stream_name || ',' || NEW.stream_id || ',' || NEW.stream_version
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS stream_events_notify ON streams;
CREATE TRIGGER stream_events_notify
    AFTER INSERT OR UPDATE ON streams
    FOR EACH ROW EXECUTE FUNCTION notify_events();

-- Immutability: prevent event mutation
CREATE OR REPLACE FUNCTION prevent_mutation() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Immutable table: % cannot be updated', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS no_update_events ON events;
CREATE TRIGGER no_update_events
    BEFORE UPDATE ON events
    FOR EACH ROW EXECUTE FUNCTION prevent_mutation();

DROP TRIGGER IF EXISTS no_update_stream_events ON stream_events;
CREATE TRIGGER no_update_stream_events
    BEFORE UPDATE ON stream_events
    FOR EACH ROW EXECUTE FUNCTION prevent_mutation();

-- Gated hard deletes (for maintenance/GDPR only)
CREATE OR REPLACE FUNCTION protect_deletion() RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('kiroku.enable_hard_deletes', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Hard deletes require: SET LOCAL kiroku.enable_hard_deletes = ''on''';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS no_delete_events ON events;
CREATE TRIGGER no_delete_events
    BEFORE DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION protect_deletion();

DROP TRIGGER IF EXISTS no_delete_stream_events ON stream_events;
CREATE TRIGGER no_delete_stream_events
    BEFORE DELETE ON stream_events
    FOR EACH ROW EXECUTE FUNCTION protect_deletion();

DROP TRIGGER IF EXISTS no_delete_streams ON streams;
CREATE TRIGGER no_delete_streams
    BEFORE DELETE ON streams
    FOR EACH ROW EXECUTE FUNCTION protect_deletion();

-- TRUNCATE bypasses row-level triggers, so the BEFORE DELETE triggers above
-- do not protect against an operator running TRUNCATE on these tables. Add
-- statement-level BEFORE TRUNCATE triggers gated by the same GUC so the
-- protection is symmetric. See EP-1 F6.
CREATE OR REPLACE FUNCTION protect_truncation() RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('kiroku.enable_hard_deletes', true) = 'on' THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'TRUNCATE requires: SET LOCAL kiroku.enable_hard_deletes = ''on''';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS no_truncate_events ON events;
CREATE TRIGGER no_truncate_events
    BEFORE TRUNCATE ON events
    FOR EACH STATEMENT EXECUTE FUNCTION protect_truncation();

DROP TRIGGER IF EXISTS no_truncate_stream_events ON stream_events;
CREATE TRIGGER no_truncate_stream_events
    BEFORE TRUNCATE ON stream_events
    FOR EACH STATEMENT EXECUTE FUNCTION protect_truncation();

DROP TRIGGER IF EXISTS no_truncate_streams ON streams;
CREATE TRIGGER no_truncate_streams
    BEFORE TRUNCATE ON streams
    FOR EACH STATEMENT EXECUTE FUNCTION protect_truncation();
