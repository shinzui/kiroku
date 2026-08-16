-- Ledger re-baseline for the corrected payload of migration 0010 (BUG-1).
--
-- kiroku-store-migrations 0.3.2.0 and 0.3.2.1 shipped a payload of 0010 whose
-- history_retention_leases.lease_id default named uuidv7() unqualified. On
-- PostgreSQL 17 that name resolves only through search_path, which is set by
-- 0001 and by nothing else, so 0010 could not parse in any session that did not
-- also apply 0001 -- that is, in every ordinary upgrade. 0.4.0.0 corrects the
-- payload; there is no forward-migration alternative, because the withdrawn
-- payload fails at DDL parse time and nothing after it can run.
--
-- pg-migrate keys an applied migration by (component, migration) and verifies
-- the exact SHA-256 of its payload bytes. Correcting the payload therefore
-- changes 0010's checksum, and a database that already applied the withdrawn
-- payload will fail every subsequent `up` and `verify` with a
-- MigrationChecksumMismatch until its stored checksum is re-baselined. This
-- script performs that re-baseline and nothing else.
--
-- WHEN TO RUN: once per long-lived database that ALREADY APPLIED the withdrawn
-- 0010 -- PostgreSQL 18, or a fresh PostgreSQL 17 install performed by
-- 0.3.2.0/0.3.2.1 -- BEFORE the next migrate carrying 0.4.0.0. A database that
-- never reached 0010 (the PostgreSQL 17 upgrade path this bug broke) does not
-- need it: 0010 is still pending there and applies from the corrected payload.
-- Ephemeral test databases do not need it either; they apply from scratch.
--
-- WHAT IT DOES NOT DO: it does not touch your schema. The withdrawn and
-- corrected payloads differ in two schema-visible ways -- the corrected one
-- publishes kiroku.uuidv7() on PostgreSQL 18 and binds lease_id's default to
-- it. Forward migration 0011 applies both to an already-0010 database through
-- the ordinary runner, so run this script first and then migrate normally.
-- Verified on PostgreSQL 17.10 and 18.4: a database converged this way dumps
-- byte-for-byte identically to a fresh 0.4.0.0 install.
--
-- SAFETY: the UPDATE matches only a row still carrying the withdrawn checksum,
-- so it is idempotent -- a second run, or a run against a database that applied
-- the corrected payload, matches no rows. Wrapped in a transaction.
--
-- LEDGER LOCATION: pg-migrate's default ledger schema is `pgmigrate`. If your
-- application configured a different schema through `ledgerConfig`, change the
-- schema name in the to_regclass call below to match.

BEGIN;

DO $$
DECLARE
  ledger_table regclass;
  withdrawn_checksum bytea :=
    decode('257d94b8ea24156af0ee477196c5a6682cf5616cf8dfd0cfc527a49b5e7a97ac', 'hex');
  corrected_checksum bytea :=
    decode('debc19187d79cd263be66c6c85cd789c1176e508d562a27390095aaa70f650c4', 'hex');
  rebaselined integer;
BEGIN
  ledger_table := to_regclass('pgmigrate.migrations');

  IF ledger_table IS NULL THEN
    RAISE EXCEPTION
      'Could not find pgmigrate.migrations; edit this script if the ledger uses a different schema';
  END IF;

  EXECUTE format(
    'UPDATE %s SET checksum = $1
       WHERE component = ''kiroku'' AND migration = ''0010'' AND checksum = $2',
    ledger_table
  )
  USING corrected_checksum, withdrawn_checksum;

  GET DIAGNOSTICS rebaselined = ROW_COUNT;

  IF rebaselined = 0 THEN
    RAISE NOTICE
      'no kiroku/0010 row carried the withdrawn checksum; nothing to re-baseline';
  ELSE
    RAISE NOTICE 're-baselined the kiroku/0010 checksum';
  END IF;
END $$;

-- Sanity check: kiroku/0010 must now carry the corrected checksum, or be
-- absent because this database has not reached 0010 yet. Expect one row with
-- ok = true, or zero rows.
--   SELECT encode(checksum, 'hex') =
--          'debc19187d79cd263be66c6c85cd789c1176e508d562a27390095aaa70f650c4' AS ok
--   FROM pgmigrate.migrations WHERE component = 'kiroku' AND migration = '0010';

COMMIT;
