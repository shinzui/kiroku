# Bundle Update Log

## 2026-08-16
* **Addition**: BUG-1 reports that migration `0010`'s unqualified `uuidv7()` default fails to parse on PostgreSQL 17 when applied to an already-bootstrapped database, because only `0001`'s in-session `SET search_path` makes the name resolvable. Reported by Kioku against `kiroku-store-migrations` 0.3.2.0.
* **Addition**: the bundle is created, on the `coordination.bugReports` profile from okf-profiles v0.10.0.
