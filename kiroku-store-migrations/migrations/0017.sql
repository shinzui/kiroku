-- add store identity and event-compaction ledger

-- A schema-installed, immutable identity for this store. Generated once, on the
-- PostgreSQL side, the first time this migration runs. A restored clone shares
-- its source's identity by construction; that is intended, so a maintenance
-- manifest rehearsed on a clone still names the production store.
CREATE TABLE kiroku.store_identity (
    singleton  BOOLEAN     PRIMARY KEY DEFAULT TRUE,
    store_id   UUID        NOT NULL DEFAULT kiroku.uuidv7(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_store_identity_singleton CHECK (singleton)
);

INSERT INTO kiroku.store_identity (singleton)
VALUES (TRUE)
ON CONFLICT DO NOTHING;

-- Durable, append-only record of every applied selective compaction. Rows are
-- written only by kiroku-store's compaction apply transaction; the table ships
-- empty and its full contract is fixed here so the feature needs one schema
-- release. manifest_digest and report_digest are raw SHA-256 bytes.
CREATE TABLE kiroku.event_compactions (
    compaction_id            UUID        PRIMARY KEY DEFAULT kiroku.uuidv7(),
    manifest_digest          BYTEA       NOT NULL UNIQUE,
    report_digest            BYTEA       NOT NULL,
    store_id                 UUID        NOT NULL,
    operation                TEXT        NOT NULL,
    dead_letter_policy       TEXT        NOT NULL,
    causation_policy         TEXT        NOT NULL,
    selected_events          BIGINT      NOT NULL,
    home_memberships         BIGINT      NOT NULL,
    global_memberships       BIGINT      NOT NULL,
    link_memberships         BIGINT      NOT NULL,
    dead_letters_removed     BIGINT      NOT NULL,
    causation_dependents     BIGINT      NOT NULL,
    lowest_global_position   BIGINT      NOT NULL,
    highest_global_position  BIGINT      NOT NULL,
    affected_streams         JSONB       NOT NULL,
    applied_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    applied_by               TEXT        NOT NULL DEFAULT session_user,
    CONSTRAINT chk_event_compactions_manifest_digest_bytes
        CHECK (octet_length(manifest_digest) = 32),
    CONSTRAINT chk_event_compactions_report_digest_bytes
        CHECK (octet_length(report_digest) = 32),
    CONSTRAINT chk_event_compactions_operation_bytes
        CHECK (octet_length(operation) BETWEEN 1 AND 512),
    CONSTRAINT chk_event_compactions_policies
        CHECK (dead_letter_policy IN ('refuse', 'remove')
           AND causation_policy IN ('refuse', 'allow')),
    CONSTRAINT chk_event_compactions_counts
        CHECK (selected_events > 0
           AND home_memberships = selected_events
           AND global_memberships = selected_events
           AND link_memberships >= 0
           AND dead_letters_removed >= 0
           AND causation_dependents >= 0),
    CONSTRAINT chk_event_compactions_positions
        CHECK (0 < lowest_global_position
           AND lowest_global_position <= highest_global_position)
);

CREATE INDEX ix_event_compactions_applied_at
    ON kiroku.event_compactions (applied_at DESC, compaction_id);

-- Immutability and gated destruction, reusing the functions 0001 installed.
-- Nothing here touches events, stream_events, or streams.
CREATE TRIGGER no_update_store_identity
    BEFORE UPDATE ON kiroku.store_identity
    FOR EACH ROW EXECUTE FUNCTION kiroku.prevent_mutation();

CREATE TRIGGER no_delete_store_identity
    BEFORE DELETE ON kiroku.store_identity
    FOR EACH ROW EXECUTE FUNCTION kiroku.protect_deletion();

CREATE TRIGGER no_truncate_store_identity
    BEFORE TRUNCATE ON kiroku.store_identity
    FOR EACH STATEMENT EXECUTE FUNCTION kiroku.protect_truncation();

CREATE TRIGGER no_update_event_compactions
    BEFORE UPDATE ON kiroku.event_compactions
    FOR EACH ROW EXECUTE FUNCTION kiroku.prevent_mutation();

CREATE TRIGGER no_delete_event_compactions
    BEFORE DELETE ON kiroku.event_compactions
    FOR EACH ROW EXECUTE FUNCTION kiroku.protect_deletion();

CREATE TRIGGER no_truncate_event_compactions
    BEFORE TRUNCATE ON kiroku.event_compactions
    FOR EACH STATEMENT EXECUTE FUNCTION kiroku.protect_truncation();

COMMENT ON TABLE kiroku.store_identity IS
  'Single immutable row identifying this store; a restored clone shares its source identity.';
COMMENT ON COLUMN kiroku.store_identity.store_id IS
  'UUIDv7 generated once by migration 0017; never updated.';

COMMENT ON TABLE kiroku.event_compactions IS
  'Append-only ledger of applied selective compactions keyed by manifest digest; rows are audit evidence and are never updated.';
COMMENT ON COLUMN kiroku.event_compactions.manifest_digest IS
  'Raw SHA-256 of the canonical manifest encoding; unique so an exact manifest can be applied once.';
COMMENT ON COLUMN kiroku.event_compactions.report_digest IS
  'Raw SHA-256 of the canonical report encoding recorded at apply time.';
COMMENT ON COLUMN kiroku.event_compactions.affected_streams IS
  'JSON array of {"stream", "head_version"} objects sorted by stream name, recording the verified head of every affected stream.';
COMMENT ON COLUMN kiroku.event_compactions.applied_by IS
  'PostgreSQL session_user that applied the manifest; recorded by default, not supplied by the caller.';

COMMENT ON SCHEMA kiroku IS
  'Managed by pg-migrate component kiroku through 0017';
