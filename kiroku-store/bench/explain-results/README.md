# PostgreSQL-side append profile artefacts

This directory holds the captured outputs of `kiroku-store-bench-explain`,
the PostgreSQL-side profiling harness for the production `AnyVersion` append
CTE. The harness lives at `kiroku-store/bench/Explain.hs` and is documented
in `docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md`.

## Files

- **`anyversion-singleton.txt`** — `EXPLAIN (ANALYZE, BUFFERS, TIMING, FORMAT TEXT)`
  output for one single-event `AnyVersion` append against a fresh stream
  name, wrapped in `BEGIN ... ROLLBACK` so it leaves no row behind. Lists
  each of the six CTE nodes (`new_events`, `stream_upsert`,
  `inserted_events`, `source_links`, `all_update`, `all_links`) with its
  own `actual time` and row count, plus per-trigger and per-buffer
  accounting and the bottom-line `Planning Time` / `Execution Time`.

- **`anyversion-singleton.json`** — the same EXPLAIN run with
  `FORMAT JSON`. Use this when programmatically comparing two runs (for
  example, to assert that a candidate optimization did not regress a
  specific CTE node). Each of the six CTEs is identifiable under
  `"Subplan Name": "CTE <name>"` rather than the `"CTE Name"` field that
  PostgreSQL uses only for CTEs separately referenced via a `CTE Scan`.

- **`auto-explain.csv`** — `auto_explain` log of a small workload
  (one `AnyVersion` append, one `ExactVersion` append against the same
  stream, one `readStreamForward`, one `readAllForward`), captured via
  PostgreSQL's `logging_collector` writing CSV records to disk. Each row's
  message column carries a full `duration: <N> ms plan: ...` block
  including the CTE breakdown. CSV is parseable with any standard CSV
  reader; the message column is column 14 (1-indexed).

- **`auto-explain.log`** — the small stderr stream that PostgreSQL emits
  before the logging collector takes over (typically just "ending log
  output to stderr" and the logger-shutdown DEBUG line). Useful for
  confirming the cluster started cleanly; not a substitute for the CSV.

## Reproduction

From the repository root (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`):

```bash
# Milestone 1: targeted EXPLAIN ANALYZE (text + JSON).
cabal bench kiroku-store-bench-explain

# Milestone 2: auto_explain capture of a small workload.
cabal bench kiroku-store-bench-explain --benchmark-options="--auto-explain"
```

The harness binary may also be invoked directly via `cabal list-bin`:

```bash
BENCH=$(cabal list-bin kiroku-store:kiroku-store-bench-explain)
"$BENCH"                 # Milestone 1
"$BENCH" --auto-explain  # Milestone 2
```

Both modes locate the output directory by walking up from the current
working directory until they find `cabal.project`, so they work whether
invoked from the repository root (`cabal run`, direct invocation) or
from the package directory `kiroku-store/` (`cabal bench`).

## Caveats discovered during EP-2 implementation

- **`ephemeral-pg` discards postgres's stderr.** The plan originally
  proposed overriding `Config.stderr` with a file handle to capture
  `auto_explain` output; that does not work because
  `EphemeralPg/Process/Postgres.hs` hardcodes `setStderr nullStream`
  for the postgres process. The harness routes around this by
  configuring PostgreSQL's own `logging_collector` to write a CSV log
  directly to disk.

- **`log_min_messages = 'log'` is required.** With the default
  `log_min_messages = 'warning'`, `auto_explain`'s `LOG`-level output
  did not appear in the CSV — empirically the CSV stayed at 0 bytes.
  Forcing `log_min_messages = 'log'` is what makes the captures
  reliable.

- **CSV instead of plain stderr.** The csvlog format is structured but
  multi-line message columns are quoted with embedded newlines, so a
  naive `grep` for `Insert on streams` and `duration:` will find them
  on different lines of the SAME CSV record. Use `grep -A N`, a CSV
  parser, or `pg_csvlog_to_sql` to read the message column cleanly.
