# Bundle Update Log

## 2026-09-25
* **Report**: BUG-3: publisher position thunk retains Hasql append results when no all-stream queue subscribers are registered; exact worker profiles and a strict-update comparison identify the cause.
* **Modification**: BUG-2 moves to `fixed` (unreleased; kiroku-store 0.9.0.0 with kiroku-store-migrations 0.6.0.0). Migration `0012` puts the category on `$all` junction rows with `ix_stream_events_all_by_category`, and both category statements range-scan it: a caught-up poll on 20,000 streams reads 6 buffers instead of 60,387. Recorded as ADR-10.
* **Modification**: BUG-2 moves to `confirmed`: a caught-up poll reads 613 buffers at 200 streams and 60,384 at 20,000 streams for the unpartitioned category read (298 and 29,958 for a group member of size 2), on PostgreSQL 18.4. The unpartitioned `readCategoryForwardSQL` shares the shape and the cost. Fix tracked in plan 91.
* **Report**: BUG-2: partitioned category reads visit every stream in the category on every poll (reported from mori://tan/notification-hub)

## 2026-08-16
* **Modification**: BUG-1 moves to `fixed` against `kiroku-store-migrations` 0.4.0.0. Migration `0010` now publishes `kiroku.uuidv7()` on every supported PostgreSQL major and defaults `lease_id` to that qualified name; the corrected payload changes `0010`'s checksum, so an already-applied database needs the new `ledger-fixups/2026-08-16-rebaseline-0010-checksum.sql` and forward migration `0011`. Confirmed and fixed against PostgreSQL 17.10.
* **Addition**: BUG-1 reports that migration `0010`'s unqualified `uuidv7()` default fails to parse on PostgreSQL 17 when applied to an already-bootstrapped database, because only `0001`'s in-session `SET search_path` makes the name resolvable. Reported by Kioku against `kiroku-store-migrations` 0.3.2.0.
* **Addition**: the bundle is created, on the `coordination.bugReports` profile from okf-profiles v0.10.0.
