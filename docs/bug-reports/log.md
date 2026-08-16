# Bundle Update Log

## 2026-08-16
* **Modification**: BUG-1 moves to `fixed` against `kiroku-store-migrations` 0.4.0.0. Migration `0010` now publishes `kiroku.uuidv7()` on every supported PostgreSQL major and defaults `lease_id` to that qualified name; the corrected payload changes `0010`'s checksum, so an already-applied database needs the new `ledger-fixups/2026-08-16-rebaseline-0010-checksum.sql` and forward migration `0011`. Confirmed and fixed against PostgreSQL 17.10.
* **Addition**: BUG-1 reports that migration `0010`'s unqualified `uuidv7()` default fails to parse on PostgreSQL 17 when applied to an already-bootstrapped database, because only `0001`'s in-session `SET search_path` makes the name resolvable. Reported by Kioku against `kiroku-store-migrations` 0.3.2.0.
* **Addition**: the bundle is created, on the `coordination.bugReports` profile from okf-profiles v0.10.0.
