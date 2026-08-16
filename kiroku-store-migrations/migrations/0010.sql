-- add replay history retention

-- Publish kiroku.uuidv7() as the component's version-independent, always
-- schema-qualified UUIDv7 generator.
--
-- PostgreSQL 18 provides pg_catalog.uuidv7(), so 0001 installed no fallback
-- and the name exists only in pg_catalog. PostgreSQL 17 has no builtin, so
-- 0001 installed the fallback into the Kiroku schema. Naming uuidv7()
-- unqualified therefore resolves only through search_path, which no migration
-- after 0001 may depend on. Establishing kiroku.uuidv7() on both versions lets
-- this migration -- and every migration after it -- name one generator that
-- resolves without session state on every PostgreSQL version the component
-- supports.
DO $$
BEGIN
    IF to_regprocedure('kiroku.uuidv7()') IS NOT NULL THEN
        -- PostgreSQL 17: 0001's fallback already occupies the name.
        RETURN;
    END IF;

    IF to_regprocedure('pg_catalog.uuidv7()') IS NULL THEN
        RAISE EXCEPTION
            'no uuidv7() generator: neither pg_catalog.uuidv7() nor kiroku.uuidv7() exists';
    END IF;

    -- PostgreSQL 18+: alias the builtin so the qualified name is available.
    EXECUTE $fn$
        CREATE FUNCTION kiroku.uuidv7()
        RETURNS uuid
        LANGUAGE sql
        VOLATILE
        AS 'SELECT pg_catalog.uuidv7()'
    $fn$;
END
$$;

-- A schema-local singleton row serializes lease lifecycle changes with every
-- destructive statement without adding work to append or ordinary read paths.
CREATE TABLE kiroku.history_retention_coordinator (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE,
    CONSTRAINT chk_history_retention_coordinator_singleton CHECK (singleton)
);

INSERT INTO kiroku.history_retention_coordinator (singleton)
VALUES (TRUE)
ON CONFLICT DO NOTHING;

-- Durable operational evidence for rebuilds that require the retained event
-- set to remain stable. Active state is derived from released_at and database
-- time; expiry needs no worker or cleanup mutation.
CREATE TABLE kiroku.history_retention_leases (
    lease_id          UUID        PRIMARY KEY DEFAULT kiroku.uuidv7(),
    owner             TEXT        NOT NULL,
    reason            TEXT        NOT NULL,
    protected_through BIGINT      NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL,
    renewed_at        TIMESTAMPTZ NOT NULL,
    expires_at        TIMESTAMPTZ NOT NULL,
    released_at       TIMESTAMPTZ,
    CONSTRAINT chk_history_retention_lease_owner_bytes
        CHECK (octet_length(owner) BETWEEN 1 AND 512),
    CONSTRAINT chk_history_retention_lease_reason_bytes
        CHECK (octet_length(reason) BETWEEN 1 AND 2048),
    CONSTRAINT chk_history_retention_lease_frontier
        CHECK (protected_through >= 0),
    CONSTRAINT chk_history_retention_lease_renewal_time
        CHECK (renewed_at >= created_at),
    CONSTRAINT chk_history_retention_lease_expiry
        CHECK (expires_at > created_at),
    CONSTRAINT chk_history_retention_lease_release_time
        CHECK (released_at IS NULL OR released_at >= created_at)
);

CREATE INDEX ix_history_retention_leases_unreleased_expiry
    ON kiroku.history_retention_leases (expires_at)
    WHERE released_at IS NULL;

-- This function is attached only to DELETE and TRUNCATE. TG_TABLE_SCHEMA is
-- quoted into each dynamic statement so a schema-qualified maintenance command
-- cannot be redirected to a coordinator selected through the caller's
-- search_path.
CREATE FUNCTION kiroku.protect_replay_history_from_destruction()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    active_count BIGINT;
BEGIN
    EXECUTE format(
        'SELECT singleton FROM %I.history_retention_coordinator WHERE singleton FOR UPDATE',
        TG_TABLE_SCHEMA
    );

    EXECUTE format(
        'SELECT count(*) FROM %I.history_retention_leases WHERE released_at IS NULL AND expires_at > clock_timestamp()',
        TG_TABLE_SCHEMA
    ) INTO active_count;

    IF active_count > 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = 'KR001',
            MESSAGE = format(
                'replay history is protected by %s active retention lease(s)',
                active_count
            );
    END IF;

    RETURN NULL;
END;
$$;

CREATE TRIGGER protect_replay_history_delete
    BEFORE DELETE ON kiroku.events
    FOR EACH STATEMENT
    EXECUTE FUNCTION kiroku.protect_replay_history_from_destruction();

CREATE TRIGGER protect_replay_history_truncate
    BEFORE TRUNCATE ON kiroku.events
    FOR EACH STATEMENT
    EXECUTE FUNCTION kiroku.protect_replay_history_from_destruction();

CREATE TRIGGER protect_replay_history_delete
    BEFORE DELETE ON kiroku.stream_events
    FOR EACH STATEMENT
    EXECUTE FUNCTION kiroku.protect_replay_history_from_destruction();

CREATE TRIGGER protect_replay_history_truncate
    BEFORE TRUNCATE ON kiroku.stream_events
    FOR EACH STATEMENT
    EXECUTE FUNCTION kiroku.protect_replay_history_from_destruction();

CREATE TRIGGER protect_replay_history_delete
    BEFORE DELETE ON kiroku.streams
    FOR EACH STATEMENT
    EXECUTE FUNCTION kiroku.protect_replay_history_from_destruction();

CREATE TRIGGER protect_replay_history_truncate
    BEFORE TRUNCATE ON kiroku.streams
    FOR EACH STATEMENT
    EXECUTE FUNCTION kiroku.protect_replay_history_from_destruction();

COMMENT ON TABLE kiroku.history_retention_leases IS
  'Durable, expiring replay-history retention leases; rows are operational evidence and remain until explicitly pruned.';

COMMENT ON SCHEMA kiroku IS
  'Managed by pg-migrate component kiroku through 0010';
