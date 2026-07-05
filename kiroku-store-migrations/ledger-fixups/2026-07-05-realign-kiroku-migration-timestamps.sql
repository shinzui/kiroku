-- Ledger realignment for the kiroku migration-timestamp rename.
--
-- The kiroku-store migrations were renamed from hand-assigned sentinel
-- timestamps (…-00-00-00, …-00-00-01, …) to their real UTC authoring times
-- (commits dac1a0b and e1f6c02). codd decides whether a migration is already
-- applied by FILENAME (`SELECT … FROM codd_schema.sql_migrations WHERE name = ?`),
-- so a database that already applied the old names would otherwise treat every
-- renamed file as pending and re-run it.
--
-- This script rewrites the `name` and `migration_timestamp` columns of the
-- codd ledger from the old identity to the new one, so codd sees the renamed
-- migrations as already applied and skips them. It changes ONLY codd's
-- bookkeeping — never your schema.
--
-- WHEN TO RUN: once per long-lived database (staging/prod/persistent local),
-- BEFORE the next `codd up` / migrate that carries the renamed files. This
-- includes downstream databases that ran kiroku migrations bundled with a
-- consumer's own (e.g. keiro's combined kiroku<>keiro ledger). Ephemeral /
-- template-per-suite test databases do not need it — they apply from scratch.
--
-- SAFETY: the remap is 1:1 onto brand-new values, so neither UNIQUE(name) nor
-- UNIQUE(migration_timestamp) can be violated (the new timestamps also do not
-- collide with any keiro rows in a combined ledger); and it is idempotent — a
-- second run matches no rows. Wrapped in a transaction so it is all-or-nothing.
--
-- NOTE: this codd builds its ledger as `codd_schema.sql_migrations`. If your
-- codd version uses the `codd` schema instead, replace the schema qualifier
-- throughout (`codd.sql_migrations`).

BEGIN;

UPDATE codd_schema.sql_migrations SET name = '2026-05-16-12-17-14-kiroku-bootstrap.sql',                 migration_timestamp = '2026-05-16 12:17:14+00' WHERE name = '2026-05-16-00-00-00-kiroku-bootstrap.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-05-29-15-26-04-add-subscription-dead-letters.sql',    migration_timestamp = '2026-05-29 15:26:04+00' WHERE name = '2026-05-26-00-00-00-add-subscription-dead-letters.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-14-13-17-09-notify-trigger-append-guard.sql',      migration_timestamp = '2026-06-14 13:17:09+00' WHERE name = '2026-06-11-00-00-00-notify-trigger-append-guard.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-14-13-25-40-dead-letters-event-id-index.sql',      migration_timestamp = '2026-06-14 13:25:40+00' WHERE name = '2026-06-11-00-00-01-dead-letters-event-id-index.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-14-13-54-48-index-hygiene-and-streams-fillfactor.sql', migration_timestamp = '2026-06-14 13:54:48+00' WHERE name = '2026-06-11-00-00-02-index-hygiene-and-streams-fillfactor.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-14-14-01-17-stream-name-length-check.sql',         migration_timestamp = '2026-06-14 14:01:17+00' WHERE name = '2026-06-11-00-00-03-stream-name-length-check.sql';
UPDATE codd_schema.sql_migrations SET name = '2026-06-24-09-42-22-stream-truncate-before.sql',           migration_timestamp = '2026-06-24 09:42:22+00' WHERE name = '2026-06-24-00-00-00-stream-truncate-before.sql';

-- Sanity check: no stale sentinel-named kiroku rows should remain.
-- Expect zero rows.
--   SELECT name FROM codd_schema.sql_migrations
--   WHERE name LIKE '2026-%' AND substr(name, 12, 8) IN
--     ('00-00-00','00-00-01','00-00-02','00-00-03');

COMMIT;
