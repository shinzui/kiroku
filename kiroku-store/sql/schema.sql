-- Kiroku Store Schema
-- Requires PostgreSQL 18+ (for uuidv7())

-- Streams (including $all as stream_id = 0)
CREATE TABLE IF NOT EXISTS streams (
    stream_id    BIGSERIAL    PRIMARY KEY,
    stream_uuid  TEXT         NOT NULL,
    category     TEXT         GENERATED ALWAYS AS (split_part(stream_uuid, '-', 1)) STORED,
    stream_version BIGINT     NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    CONSTRAINT ix_streams_stream_uuid UNIQUE (stream_uuid)
);

-- Seed the $all stream
INSERT INTO streams (stream_id, stream_uuid, stream_version)
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

-- Triggers

-- NOTIFY on stream changes (fires once per append, not per event)
CREATE OR REPLACE FUNCTION notify_events() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        TG_TABLE_SCHEMA || '.events',
        NEW.stream_uuid || ',' || NEW.stream_id || ',' || NEW.stream_version
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
