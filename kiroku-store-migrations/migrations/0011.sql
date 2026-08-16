-- converge databases that applied the withdrawn 0.3.2.x payload of 0010

-- kiroku-store-migrations 0.3.2.0 and 0.3.2.1 shipped a payload of 0010 whose
-- lease_id default named uuidv7() unqualified. That payload could not parse on
-- PostgreSQL 17 outside the bootstrap session (BUG-1), and where it did apply
-- -- PostgreSQL 18, or a fresh PostgreSQL 17 install -- it left the schema in a
-- state the corrected 0010 does not produce: no kiroku.uuidv7(), and a lease_id
-- default bound to whichever uuidv7() the applying session happened to resolve.
--
-- The corrected 0010 cannot reach those databases: its ledger row is already
-- present, and re-baselining that row (see ledger-fixups/) restores the
-- checksum without replaying the SQL. This migration is what makes both
-- populations converge, and it is a no-op on any database that applied the
-- corrected 0010.

-- 1. kiroku.uuidv7() exists on every supported major version. Identical to the
--    header of the corrected 0010, and skipped there because 0010 ran first.
DO $$
BEGIN
    IF to_regprocedure('kiroku.uuidv7()') IS NOT NULL THEN
        -- PostgreSQL 17, or a database that applied the corrected 0010.
        RETURN;
    END IF;

    IF to_regprocedure('pg_catalog.uuidv7()') IS NULL THEN
        RAISE EXCEPTION
            'no uuidv7() generator: neither pg_catalog.uuidv7() nor kiroku.uuidv7() exists';
    END IF;

    EXECUTE $fn$
        CREATE FUNCTION kiroku.uuidv7()
        RETURNS uuid
        LANGUAGE sql
        VOLATILE
        AS 'SELECT pg_catalog.uuidv7()'
    $fn$;
END
$$;

-- 2. Bind lease_id's default to the qualified generator. A column default is
--    stored as a resolved function OID, so a database that applied the
--    withdrawn payload on PostgreSQL 18 holds pg_catalog.uuidv7() here. Both
--    generators produce the same values; this only makes the stored default
--    match what the corrected 0010 installs, so a dumped schema is identical
--    whichever payload the database applied. Existing lease rows are untouched
--    and no table is rewritten.
ALTER TABLE kiroku.history_retention_leases
    ALTER COLUMN lease_id SET DEFAULT kiroku.uuidv7();

COMMENT ON SCHEMA kiroku IS
  'Managed by pg-migrate component kiroku through 0011';
