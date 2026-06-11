---
id: 63
slug: decide-the-marten-style-global-position-migration-with-durable-fsync-benchmarks-and-option-preserving-contract-changes
title: "Decide the Marten-style global-position migration with durable-fsync benchmarks and option-preserving contract changes"
kind: exec-plan
created_at: 2026-06-11T15:14:23Z
intention: "intention_01ktvkqb9ee9j90wg64mgqd1mx"
---

# Decide the Marten-style global-position migration with durable-fsync benchmarks and option-preserving contract changes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

> **This plan is a decision instrument, not a migration.** Its product is a
> written verdict — **PROCEED NOW** or **NOT WORTH IT** — on undertaking the
> Marten-style global-position migration described in
> `docs/architecture/global-position-migration-path.md`, backed by throughput
> numbers measured on hardware with honest disk durability. The benchmark code it
> builds is a throwaway spike that never touches production modules. One milestone
> (M1, the contract changes) ships permanent changes regardless of the verdict;
> everything else is measurement. The decision thresholds are pre-registered in
> the Decision Log *before* any measurement runs, so the verdict is a falsifiable
> check rather than a sense-making exercise (per `docs/PERF-METHODOLOGY.md`).


## Purpose / Big Picture

Kiroku assigns every event a global position by incrementing a single counter row
(the `$all` row, `streams.stream_id = 0`) inside the append transaction. That row's
write lock is held until the transaction commits — and the commit includes the
synchronous WAL flush (the disk write that makes a transaction durable). So every
append in the entire store, regardless of which stream it targets, serializes on
the durable-commit latency of the storage device. On a MacBook this latency is
fake-cheap (~0.1–0.2 ms, because macOS `fsync()` does not actually flush the drive
cache), which produced the "~50K events/s" numbers in `docs/DESIGN.md`. On GCP with
honest fsync (~1 ms or worse) the same architecture measured drastically lower —
that discrepancy is what triggered this plan.

The alternative is the architecture Marten (the .NET event store this repo's
DESIGN.md calls "Strategy A") uses: assign positions from a PostgreSQL sequence,
let appends to different streams commit fully in parallel, and accept that
positions can have gaps and commit out of order — paying for it with a
"high-water-mark daemon" on the read side. Migrating to that is roughly a
masterplan-sized effort (8–10 ExecPlans; see
`docs/architecture/global-position-migration-path.md` for the full cost breakdown).
Nobody should start that effort on a hypothesis.

After this plan is implemented, the repository contains: (a) public documentation
that no longer promises position contiguity to consumers, so the migration option
stays open whatever we decide; (b) measured numbers, checked into
`docs/perf-experiment-log.md` and the architecture doc, answering "what % write
throughput would a Marten-style schema gain on durable-fsync hardware, at which
workload shapes"; and (c) a one-line verdict with pre-registered criteria:
**PROCEED NOW** or **NOT WORTH IT**.

**Expected-impact hypothesis** (required by `docs/PERF-METHODOLOGY.md` step 3).
The causal model says Strategy E's cross-stream throughput ceiling is
`batchSize / durable_commit_latency`, independent of writer count, because the
`$all` lock prevents commits from overlapping and therefore defeats PostgreSQL's
group commit (the mechanism by which many concurrently-committing transactions
share one WAL flush). The sequence-based arm restores group commit. Concretely
predicted, to be checked against measurement:

- Mac with `wal_sync_method=fsync_writethrough` (honest fsync): Strategy E
  append-only throughput at writers=32, batch=1 collapses by **≥ 3×** versus the
  default configuration. If this does not happen, the causal model is wrong and
  the plan stops at Milestone 3 with a "model falsified" outcome.
- GCP, writers=32, batch=1: sequence-based arm beats Strategy E by **5–15×**
  (group commit amortizes flushes across ~32 concurrent committers, less
  coordination overhead).
- GCP, writers=32, batch=10: ratio persists at roughly the same multiple (both
  arms scale linearly with batch size).
- Hot-stream (all writers on one stream): ratio ≈ **1×** — no gain, because
  same-stream appends serialize on the source-stream row lock in both designs.
  This cell is an honesty check on the whole experiment: if the sequence arm
  "wins" here, something is wrong with the setup.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be
documented here, even if it requires splitting a partially completed task into two
("done" vs. "remaining").

- [x] M1: reword `GlobalPosition` haddock in `kiroku-store/src/Kiroku/Store/Types.hs`
      (drop the gap-free promise from the public contract; state the
      no-arithmetic rule). (2026-06-11)
- [x] M1: reword `README.md` lines 29–32 (contiguity demoted to implementation
      detail). (2026-06-11)
- [x] M1: annotate `docs/DESIGN.md` Strategy E throughput claims (lines 17, 21,
      661) with a pointer to `docs/architecture/global-position-migration-path.md`
      and the Mac-artifact caveat. (2026-06-11)
- [x] M1: audit keiro (`/Users/shinzui/Keikaku/bokuno/keiro`) for position
      arithmetic or density assumptions; record findings in Surprises &
      Discoveries. (2026-06-11 — two density-assumption sites found; recorded.)
- [x] M1: mark `linkToStream` provisional in
      `kiroku-store/src/Kiroku/Store/Link.hs` (and any README mention); confirm
      keiro still has zero `linkToStream` usage at implementation time.
      (2026-06-11 — recheck returned zero usage.)
- [x] M1: build haddocks, run kiroku test suite, commit. (2026-06-11 —
      `cabal haddock kiroku-store` OK; 189 examples, 0 failures.)
- [ ] M2: kiroku-bench fairness fixes — pool-size parity, monotonic clock,
      sub-millisecond histogram buckets; commit in kiroku-bench repo.
- [ ] M3: Mac falsification run A (default fsync) and run B
      (`wal_sync_method=fsync_writethrough`); record both in
      `docs/perf-experiment-log.md`; evaluate the M3 gate.
- [ ] M3: Mac inverse check (`synchronous_commit=off`); record.
- [ ] M4: write `seqproto` schema setup SQL and the `kiroku-bench-seqproto`
      executable (spike arm).
- [ ] M4: local smoke run of both arms; sanity-check invariants (positions
      strictly increasing per stream, stream versions contiguous).
- [ ] M4: GCP matrix — both arms × writers {8, 32} × batch {1, 10} × 3 trials,
      plus hot-stream cell; archive results under load-testing-infra
      `experiments/`.
- [ ] M4: gap-scan cost measurement on the populated prototype schema.
- [ ] M5: compute gain table, apply the pre-registered decision rule, write the
      verdict into `docs/architecture/global-position-migration-path.md`, append
      ledger rows, update this plan's Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**M1 keiro `GlobalPosition` audit (2026-06-11).** Grepped every `GlobalPosition`
use in `/Users/shinzui/Keikaku/bokuno/keiro` (`grep -rn "GlobalPosition"
--include='*.hs' . | grep -v dist-newstyle`). Most uses are construction from
`0`, persistence round-trips (`unGlobalPosition`/`GlobalPosition <$> int8`
decoders), and header (de)serialization — all contract-safe. Two sites assume
density and would behave incorrectly under a gappy sequence-based scheme:

1. `keiro/src/Keiro/Command.hs:638-661` `reconstructRecorded` reconstructs a
   just-appended batch's `RecordedEvent`s without reading them back, computing
   `firstGp = lastGp - count + 1` then `globalPosition = GlobalPosition
   (firstGp + i)` per event. This assumes the batch's events received
   *contiguous* positions. Under Strategy E that holds (one append claims a
   contiguous run); under a non-transactional sequence, concurrent appends can
   interleave `nextval()` calls, so a batch's positions may not be contiguous —
   this would assign wrong positions. **Correctness-affecting** if the migration
   proceeds; must be fixed (read the batch back, or have the append return the
   exact positions) as part of any PROCEED follow-up.
2. `keiro/src/Keiro/Projection.hs:151-153` `positionGap` computes
   `headP - checkP` as "the gap between log head and checkpoint, in events".
   Under gappy positions this overcounts actual events. **Observability-only**:
   it feeds `recordProjectionLag` (a metric), not a correctness path. Lower
   priority but should be noted as approximate.

Per the plan, keiro is not modified here; both are filed as PROCEED follow-up
work (and surfaced in the M5 verdict write-up). No site compares positions
across stores or does `pos + 1` existence checks.

**M1 `linkToStream` recheck (2026-06-11).** `grep -rn "linkToStream"
--include='*.hs' .` (excluding `dist-newstyle`) in keiro returned zero matches
(exit 1). The 2026-06-11 audit holds; marking the API provisional does not pull
it out from under a live consumer.

**M1 README link-feature note (2026-06-11).** `README.md`'s API enumeration
(line ~17) lists "link" among the kiroku-store APIs. Judged not worth a separate
provisional caveat there: it is a bare enumeration item, not a feature pitch,
and the authoritative contract surface (the `linkToStream` haddock) now carries
the provisional marker. The membership-through-links sentence (line ~30) was
reworded to frame links as the mechanism, not a promoted feature.


## Decision Log

- Decision: Decision thresholds are pre-registered before any measurement, as
  follows. Let `G(w,b)` be the ratio (seqproto events/s ÷ Strategy E events/s)
  for the append-only workload at writer count `w` and batch size `b` on the GCP
  reference setup, using the median of 3 trials per cell.
  **PROCEED NOW** requires all of: `G(32,1) ≥ 3.0`; `G(32,10) ≥ 2.0`; and the
  gap-scan viability check passes (the Marten-style gap-detection query
  completes in < 25 ms p95 against the prototype dataset at its post-run row
  count). **NOT WORTH IT** is declared when `G(32,1) < 2.0`. The band between
  (G(32,1) ≥ 2.0 but a PROCEED condition failing) is a judgment zone: the
  verdict must be decided against a written target workload (events/s the
  business actually needs) and recorded here with rationale.
  Rationale: the migration costs ~8–10 ExecPlans and adds a permanently more
  complex read side (high-water-mark daemon). A < 2× win never repays that —
  doubling batch size achieves 2× for free under Strategy E. A ≥ 3× win at the
  unbatched shape, holding ≥ 2× when batching (the cheap relief valve) is
  already applied, means the relief valves cannot close the gap and the
  architecture itself is the bottleneck.
  Date: 2026-06-11

- Decision: The prototype arm keeps Kiroku's exact write shape — `events` insert
  plus *two* `stream_events` junction inserts per event (source stream and
  `$all`) plus the `streams` source-row update and NOTIFY trigger — changing
  exactly one variable: global positions come from `nextval()` on a sequence
  instead of the `$all` row counter, and the `$all` row is never updated.
  Rationale: the question is "what does removing the `$all` lock buy", not "what
  does a thinner schema buy". Keeping write amplification identical isolates the
  variable. (A real migration might also drop the `$all` junction rows in favor
  of a position column on `events` — Marten's shape — but that is a separate
  optimization to be measured separately if we proceed.)
  Date: 2026-06-11

- Decision: The `GlobalPosition` constructor stays exported. True opacity is
  impossible: consumers persist checkpoints as integers and must reconstruct
  positions, and the documented idiom `readAllForward (GlobalPosition 0)` needs
  the constructor. The contract change is documentation-level: construct only
  from zero or from a value previously obtained from the store; never compute
  positions by arithmetic; never assume density.
  Date: 2026-06-11

- Decision: This plan is standalone, not a child of MasterPlan 9. Its M1 is
  independent of all in-flight work, and its measurements compare two arms on
  identical code/schema state, so the *ratio* is robust to whichever of plans
  59/60 have landed. The absolute Strategy E numbers recorded in M4 must note
  the kiroku commit hash they were measured at. A PROCEED verdict must still
  respect MasterPlan 9 sequencing (the migration would rewrite the
  publisher/worker files plans 56–58 touch), and says "proceed" to *planning the
  migration masterplan*, not to starting it mid-flight of MasterPlan 9.
  Date: 2026-06-11

- Decision: The hot-stream cell is informational, not gating.
  Rationale: same-stream serialization is inherent to optimistic concurrency on
  a stream in both designs; no decision hinges on it. It serves as an
  experiment-validity check (expected ratio ≈ 1×).
  Date: 2026-06-11

- Decision: `linkToStream` is kept but demoted to provisional status as part of
  M1, and its fate is pre-registered: if the verdict is PROCEED, the migration
  masterplan must include an explicit phase-2 decision point that adopts the
  single-table event layout (global position as a column on `events`, junction
  table dropped) and removes `linkToStream` or rehomes it to a normally-empty
  side table (`stream_links`), with the write-amplification gain measured under
  the same benchmark-gated discipline as this plan.
  Rationale: a 2026-06-11 audit found zero `linkToStream` usage in keiro (the
  only downstream consumer) or anywhere outside kiroku's own tests and docs.
  The feature has no append-hot-path cost today, but it is the only feature
  that *requires* the `stream_events` junction shape — `$all` ordering,
  category reads, consumer groups, and causation queries all survive a
  single-table layout without it. Marking it provisional now prevents keiro
  from adopting it and converting a free removal option into a breaking change
  (the same calcification logic as the `GlobalPosition` contract change).
  Date: 2026-06-11


## Outcomes & Retrospective

(To be filled during and after implementation. Must end with the verdict line:
**PROCEED NOW** or **NOT WORTH IT**, the measured gain table, and the date.)


## Context and Orientation

This section is self-contained background. Read it fully before touching anything.

**The repositories involved.** Three sibling checkouts:

- `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` — the event store
  (this repo; all plan/doc edits and the M1 contract changes happen here).
- `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku-bench` — the load
  generator. A cabal project whose executables (`kiroku-bench`,
  `kiroku-bench-rawpg`, `kiroku-bench-hasql`, `kiroku-bench-store-api`) run
  configurable write/read workloads against a PostgreSQL instance named by
  `PG_CONNECTION_STRING` and expose throughput/latency as Prometheus metrics on
  `127.0.0.1:9570/metrics`. M2's fixes and M4's new spike executable land here.
- `/Users/shinzui/Keikaku/bokuno/load-testing-infra` — GCP automation for
  running kiroku-bench on real cloud hardware. Everything it does is pinned to
  GCP project `tan-nb-exp`, region `us-west1` (see its `CLAUDE.md` for the
  enforcement rules). Completed experiment runs are archived under its
  `experiments/` directory with names like
  `2026-05-19-ceiling-lite-w32-p256-b1-t1` (date, experiment, writers, payload,
  batch, trial). M4's GCP runs follow the same conventions.

There is also a read-only reference checkout of Marten (the .NET event store) at
`/Users/shinzui/Keikaku/hub/event-sourcing/marten`, used in M4 to crib the
gap-detection SQL. Never modify it.

**How Kiroku assigns global positions today (Strategy E).** Every append is one
SQL statement — a chain of CTEs (`WITH ... AS` subqueries) — executed in
autocommit mode via one `Pool.use … Session.statement` call
(`kiroku-store/src/Kiroku/Store/Effect.hs:138-146`). Inside the CTE
(`kiroku-store/src/Kiroku/Store/SQL.hs`, the four `append*SQL` templates around
lines 160–367), the statement: locks and bumps the source stream's row in
`streams` (this enforces the per-stream optimistic-concurrency check and keeps
per-stream versions contiguous); inserts the events into `events`; then runs

```sql
UPDATE streams
SET stream_version = stream_version + (SELECT count(*) FROM new_events)
WHERE stream_id = 0 AND EXISTS (SELECT 1 FROM stream_update)
RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
```

— taking an exclusive row lock on the `$all` counter row — and finally inserts
one `stream_events` junction row per event for the source stream and one for
`$all` (stream_id 0), the latter carrying the claimed global positions.
PostgreSQL releases row locks at transaction end, i.e. at the implicit COMMIT of
the autocommit statement, *after* the WAL flush. Therefore no two appends
anywhere in the store ever overlap their commits, group commit never amortizes
anything, and the store-wide ceiling is `batchSize / durable_commit_latency`.

**Why the Mac numbers misled.** On macOS, `fsync()` returns after pushing data to
the drive's volatile write cache; it does not issue the flush command that makes
data durable (Apple requires `fcntl(F_FULLFSYNC)` for that). PostgreSQL only
issues F_FULLFSYNC when `wal_sync_method = fsync_writethrough`. The benchmark's
local database (`kiroku-bench/db/db/postgresql.conf`) uses defaults, so a "durable"
commit costs ~0.1–0.2 ms on the Mac versus ~1 ms+ on GCP persistent disk. Full
analysis: `docs/architecture/global-position-migration-path.md`.

**How Marten does it (the migration target's shape).** Facts verified against the
local checkout, with paths for deeper reading:

- Positions come from a plain sequence, `mt_events_sequence`. The append
  function (`src/Marten/Events/Schema/QuickAppendEventFunction.cs`, the
  generated `mt_quick_append_events` PL/pgSQL function) calls
  `seq := nextval('<schema>.mt_events_sequence')` per event while inserting.
  There is no store-wide lock of any kind; appends to different streams commit
  fully in parallel and share WAL flushes via group commit. Same-stream appends
  are still effectively serialized by the unique `(stream_id, version)` index.
- Because sequences are non-transactional, a rolled-back append burns its
  values, leaving permanent gaps; and a slow transaction can commit position
  100 *after* position 101 is already visible. Marten therefore never lets
  consumers read to the raw head. A "high-water-mark" (HWM) daemon maintains
  the highest position below which everything is settled, persisted in the
  `mt_event_progression` table. Projections read
  `WHERE seq_id > <checkpoint> AND seq_id <= <high water mark>`
  (`src/Marten/Events/Daemon/Internals/EventLoader.cs:41-64`).
- The gap detector (`src/Marten/Events/Daemon/HighWater/GapDetector.cs:23-34`)
  finds the first hole after the last mark with a window function:

  ```sql
  select seq_id
  from   (select seq_id,
                 lead(seq_id) over (order by seq_id) as no
          from <schema>.mt_events where seq_id >= :start) ct
  where  no is not null and no - seq_id > 1
  limit 1;
  ```

  A gap that persists beyond a configurable `StaleSequenceThreshold` is deemed a
  rollback (not an in-flight transaction) and skipped: the HWM jumps to
  `highest_sequence - 32`, the 32 being a hardcoded safe-harbor buffer against
  advancing into writes that are mid-flight
  (`src/Marten/Events/Daemon/HighWater/HighWaterDetector.cs:86-104`). Failed
  appends additionally write "tombstone" events recording burned sequence
  numbers so most gaps are explained without waiting out the timeout.

This daemon is the complexity Kiroku's Strategy E avoids, and the read-side cost
a PROCEED verdict accepts. The gap-scan viability check in M4 measures its main
recurring query against Kiroku-shaped data.

**The bench harness, briefly.** `kiroku-bench`'s `append-only` mode runs N writer
threads, each appending batches to its own stream (`bench-stream-<wid>`) through
the full kiroku-store API in a loop, counting events on the Prometheus counter
`bench_workload_ops_total{op="append"}` and observing per-call latency on
`bench_workload_op_seconds`. `hot-stream-append` is identical but all writers
share one stream. Knobs are environment variables (`KIROKU_BENCH_WRITERS`,
`KIROKU_BENCH_BATCH_SIZE`, `KIROKU_BENCH_PAYLOAD_BYTES`, `KIROKU_BENCH_POOL_SIZE`,
`KIROKU_BENCH_MODE`). Throughput for a run is computed as the delta of the ops
counter over the measurement window (the load-testing-infra tooling does this
from Prometheus scrapes; locally you can curl the endpoint twice and divide).

**Known harness defects M2 fixes (found during the 2026-06-11 validation).**
(1) `kiroku-bench` defaults its kiroku-store pool to 10 connections regardless of
writer count (`kiroku-bench/app/Main.hs:109`), while the rawpg baseline sizes its
pool to `writers + 4` (`kiroku-bench/app/RawPg.hs:93-94`) — cross-binary
comparisons at writers > 10 are unfair. (2) `timeIO` in
`kiroku-bench/src/Kiroku/Bench/Runtime.hs:46-51` uses `getCurrentTime` (wall
clock, NTP-steppable) while claiming monotonicity. (3) The latency histogram's
lowest bucket boundary is 0.5 ms (`kiroku-bench/src/Kiroku/Bench/Metrics.hs:91-97`),
so sub-millisecond appends — the entire Mac regime — are unresolvable.


## Plan of Work

### Milestone 1 — Option-preserving contract changes (permanent; ships regardless of verdict)

Scope: stop promising position contiguity in public documentation, so consumers
(today: keiro, the sister framework at `/Users/shinzui/Keikaku/bokuno/keiro`,
which pins kiroku-store by git SHA) never grow code that breaks under a future
gappy-position schema. At the end of this milestone the public contract reads
"strictly increasing, opaque; do not assume density", haddocks build clean, the
kiroku test suite passes, and a keiro audit is on record.

In `kiroku-store/src/Kiroku/Store/Types.hs`, replace the `GlobalPosition` haddock
(currently at lines 85–88) with wording to this effect (adjust freely for house
style, but the three promises/prohibitions must all appear):

```haskell
{- | Global position of an event in the @$all@ ordering, shared across all
streams. __Contract:__ strictly increasing per successful append, and totally
ordered — nothing more. Treat values as opaque cursors: construct a
'GlobalPosition' only from @0@ (the beginning of the store) or from a value
previously returned by this store; never derive one by arithmetic, and never
assume positions are dense (@pos + 1@ may not exist). The current
implementation happens to assign contiguous positions (see EP-1's audit), but
contiguity is an implementation detail, not an API guarantee, and is the part
that would change under a sequence-based allocation scheme — see
docs/architecture/global-position-migration-path.md.
-}
```

In `README.md` (lines 29–32), replace the sentence pair "maintains a contiguous
`$all` stream … claim gap-free global positions in the same transaction that
appends events" with wording that promises a *totally ordered* `$all` stream and
relegates the atomic-counter/gap-free mechanism to a "current implementation"
clause pointing at `docs/architecture/global-position-migration-path.md`.

In `docs/DESIGN.md`, at the three places that state the ceiling or sell
contiguity as a guarantee (lines 17 and 21 in the Strategy E comparison, line 661
in the decisions table), add a bracketed caveat: the ~50K events/s figure was
measured on macOS where fsync does not flush (see
`docs/architecture/global-position-migration-path.md`); durable-fsync ceilings
are `batchSize / commit_latency`. Do not rewrite the design narrative — annotate
it; this plan's M4/M5 produce the replacement numbers.

Mark `linkToStream` provisional. In `kiroku-store/src/Kiroku/Store/Link.hs`,
prepend a paragraph to the `linkToStream` haddock to this effect: __Provisional
API.__ No known consumer uses this function (audited 2026-06-11: zero usage in
keiro). It is the only public feature that requires the `stream_events`
junction-table layout, which a future global-position migration may replace
with a single-table event layout; in that case this function will be removed or
redesigned (e.g., rehomed to a dedicated links side table). If you have a real
use case, surface it before depending on this. If `README.md` mentions
stream-event links as a feature, add the same one-line caveat there. Before
committing, re-run the usage check
(`grep -rn linkToStream /Users/shinzui/Keikaku/bokuno/keiro --include='*.hs'`,
excluding `dist-newstyle`) and record the result in Surprises & Discoveries —
if usage has appeared since 2026-06-11, stop and renegotiate the Decision Log
entry instead of marking the API provisional out from under a consumer.

Audit keiro: from `/Users/shinzui/Keikaku/bokuno/keiro`, grep every use of
`GlobalPosition` (files include `keiro-core/src/Keiro/Integration/Event.hs`,
`keiro/src/Keiro/Projection.hs`, `keiro/src/Keiro/Outbox.hs`,
`keiro/src/Keiro/ReadModel.hs`, and tests) and verify none performs arithmetic on
the wrapped `Int64`, compares positions across stores, or assumes `pos + 1`
exists. Record the result (clean, or each offending site) in Surprises &
Discoveries. Do not change keiro in this plan; if offenders exist, file them as
follow-up work in the verdict write-up.

Acceptance: `cabal haddock kiroku-store` succeeds; `grep -rn "gap-free"
kiroku-store/src README.md` shows no occurrence presented as an API guarantee;
the kiroku-store test suite passes unchanged (the edits are comments and prose
only); the keiro audit note exists. Commit (in kiroku) with trailers
`ExecPlan: docs/plans/63-...md` and `Intention: intention_01ktvkqb9ee9j90wg64mgqd1mx`.

### Milestone 2 — Bench harness fairness fixes (kiroku-bench repo)

Scope: make cross-binary throughput comparisons fair and sub-millisecond
latencies visible, so M3/M4 numbers are trustworthy. All three changes are in
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku-bench`.

First, pool parity: in `kiroku-bench/app/Main.hs`, change the
`KIROKU_BENCH_POOL_SIZE` default from the literal `10` to `writers' + 4`,
matching `app/RawPg.hs`. Keep the env var as an explicit override. Note in the
commit message that historical runs used pool=10, so absolute numbers before and
after this commit are not directly comparable at writers > 10 (the
load-testing-infra `experiments/2026-05-18-followup-pool*` series characterized
this confound).

Second, monotonic timing: in `kiroku-bench/src/Kiroku/Bench/Runtime.hs`, rewrite
`timeIO` to use `GHC.Clock.getMonotonicTimeNSec` (base ships it; no new
dependency), converting to seconds as `Double`. The haddock already claims
monotonicity; make it true.

Third, histogram resolution: in `kiroku-bench/src/Kiroku/Bench/Metrics.hs`,
extend `latencyBuckets` downward with `0.00005, 0.0001, 0.00025` (50 µs, 100 µs,
250 µs) ahead of the existing `0.0005` head.

Acceptance: `cabal build all` succeeds in kiroku-bench; a 30-second local
`append-only` smoke run shows latency observations distributed across the new
sub-millisecond buckets (on the Mac they currently all pile into the first
bucket). Commit in kiroku-bench with the same two trailers (the ExecPlan trailer
names this file by its kiroku-repo path; that is the convention for cross-repo
work driven by a kiroku plan).

### Milestone 3 — Mac falsification runs (prototyping; throwaway configuration, no code)

Scope: cheaply confirm or refute the causal model on the machine where the
misleading numbers were produced, before spending GCP time. Three runs of the
same workload — `append-only`, writers=32, batch=1, payload=256, ≥ 60 s steady
state — against the local kiroku-bench Postgres, differing only in durability
configuration:

- **Run A (baseline):** default configuration as checked in.
- **Run B (honest fsync):** `ALTER SYSTEM SET wal_sync_method = 'fsync_writethrough';`
  then restart Postgres. This makes macOS commits actually flush the drive
  cache, emulating GCP-like durable-commit latency on local hardware.
- **Run C (no commit wait):** revert B, then
  `ALTER SYSTEM SET synchronous_commit = 'off';` and restart. This removes the
  WAL-flush wait from the commit path entirely.

The model predicts throughput(B) ≪ throughput(A) ≤ throughput(C), with B at
least 3× below A. **Gate:** if Run B does *not* drop throughput by ≥ 3×, the
WAL-flush-under-lock model is wrong; stop after recording the numbers, mark the
plan outcome "model falsified — re-investigate the GCP discrepancy before any
verdict", and do not run M4 (its experiment design depends on the model).

After the runs, remove the overrides (`ALTER SYSTEM RESET wal_sync_method;
ALTER SYSTEM RESET synchronous_commit;`, restart) and verify
`SHOW wal_sync_method;` is back to default. Record all three throughput numbers
in `docs/perf-experiment-log.md` (kiroku repo) as a new ledger row group dated
with the run date, hypothesis "Strategy E ceiling = batch/commit-latency;
Mac fsync is not durable", outcome, and lesson.

### Milestone 4 — Sequence-based prototype arm and GCP matrix (prototyping; spike code)

Scope: build the one-variable-changed comparison arm, validate it locally, run
the matrix on GCP, and measure the gap-scan cost. At the end, a gain table with
medians over 3 trials exists for every cell.

**The prototype schema** lives in a new file
`kiroku-bench/kiroku-bench/sql/seqproto-setup.sql` and is created in a dedicated
schema named `seqproto` so it can never collide with a real kiroku schema. It is
a faithful copy of kiroku's bootstrap shape
(`kiroku/kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`):
the `streams` table (without the `$all` seed row), the `events` table, the
`stream_events` junction table with the same indexes, and the same
`AFTER INSERT OR UPDATE ON streams` NOTIFY trigger — plus one addition:

```sql
CREATE SEQUENCE seqproto.global_position_seq;
```

The file must start with `DROP SCHEMA IF EXISTS seqproto CASCADE; CREATE SCHEMA
seqproto;` so re-running it is always safe (idempotent by reconstruction). One
known asymmetry to record in the plan's Surprises section when measuring: kiroku's
trigger fires twice per append (source stream + `$all` row update) while the
prototype's fires once (no `$all` update exists); NOTIFY cost is microseconds
against millisecond-scale commits, so this is noise, but it is a real asymmetry
and must be written down.

**The append statement** is kiroku's `appendAnyVersionSQL` (copy it verbatim from
`kiroku/kiroku-store/src/Kiroku/Store/SQL.hs` as the starting point, table names
re-qualified to `seqproto.*`) with exactly two edits: delete the `all_update` CTE
entirely, and change the `$all` link CTE to claim positions from the sequence:

```sql
all_links AS (
    INSERT INTO seqproto.stream_events
        (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT ne.event_id,
           0,
           nextval('seqproto.global_position_seq'),
           su.stream_id,
           su.initial_version + ne.idx
    FROM (SELECT * FROM new_events ORDER BY idx) ne
    CROSS JOIN stream_update su
)
```

(`stream_id = 0` rows no longer reference a `streams` row; drop or relax the
junction table's foreign key for stream 0 in the setup SQL — the simplest
faithful choice is to keep a dummy `$all` row in `seqproto.streams` that is
never UPDATEd, so the FK holds and reads stay shape-identical. Note whichever
choice you make in the Decision Log.) Intra-batch position order follows the
`ORDER BY idx`; cross-batch interleaving is exactly the gappy/out-of-order
behavior the real migration would have.

**The driver** is a new executable `kiroku-bench-seqproto` in the kiroku-bench
cabal file, written by copying `app/RawPg.hs` (it already has the right shape:
raw hasql, per-writer loop, `op="append"` metric labels, pool sized
`writers + 4`) and swapping the single INSERT for the prototype append statement
with the same parameter encoding kiroku uses (the implementer can crib the
encoder from kiroku's `SQL.hs` `appendParamsEncoder` or simplify to per-event
parameters — batch sizes here are 1 and 10, and both arms pay their own encoding,
which is part of what's being measured only on the kiroku arm; keep the
prototype encoding dumb-but-not-pathological and note it). It owns mode knobs
`KIROKU_BENCH_WRITERS`, `KIROKU_BENCH_BATCH_SIZE`, `KIROKU_BENCH_PAYLOAD_BYTES`,
plus `KIROKU_BENCH_SEQPROTO_HOT=1` to make every writer target one shared stream
(the hot-stream cell). On startup it applies `sql/seqproto-setup.sql`.

**Local smoke + invariant check.** Run both arms 30 s locally. Then verify on the
prototype data: per-stream versions are contiguous
(`SELECT stream_id FROM seqproto.stream_events WHERE stream_id <> 0 GROUP BY stream_id, ... HAVING max-min+1 <> count`)
and global positions are strictly increasing but possibly gappy
(`SELECT count(*), max(stream_version) FROM seqproto.stream_events WHERE stream_id = 0` —
max ≥ count, equality only if no transaction ever rolled back). Both arms must
also produce error-free runs (`bench_workload_op_errors_total` stays 0).

**GCP matrix.** Using load-testing-infra (GCP project `tan-nb-exp`, `us-west1`;
follow that repo's experiment runbook and its preflight project assertion —
its `experiments/2026-05-19-ceiling-lite-*` series is the closest template,
including the 3-trial variance convention): for each arm
(`kiroku-bench` append-only as the Strategy E arm; `kiroku-bench-seqproto` as
the sequence arm) run writers ∈ {8, 32} × batch ∈ {1, 10}, payload 256, 3 trials
each, ≥ 120 s steady state per trial, both arms against the same Postgres
instance type and disk as the earlier GCP runs that exposed the discrepancy.
Add one hot-stream cell per arm at writers=32, batch=1. Record the kiroku and
kiroku-bench commit hashes in each experiment directory. Seventeen runs per arm
total (12 matrix + 3 hot-stream… adjust trial counts to match; the matrix is
4 cells × 3 trials + 1 hot cell × 3 trials = 15 per arm).

**Gap-scan viability check.** Against the populated prototype schema after the
GCP runs (or a local population of ≥ 5M junction rows if more convenient),
time Marten's gap-detection query shape adapted to the prototype layout,
starting from a mark ~10K positions behind head:

```sql
SELECT stream_version
FROM (SELECT stream_version,
             lead(stream_version) OVER (ORDER BY stream_version) AS nxt
      FROM seqproto.stream_events WHERE stream_id = 0 AND stream_version >= $1) t
WHERE nxt IS NOT NULL AND nxt - stream_version > 1
LIMIT 1;
```

Run it 100 times via `EXPLAIN (ANALYZE)` or `\timing`; record p50/p95. The
PROCEED gate requires p95 < 25 ms (this query is the HWM daemon's steady-state
poll; at 25 ms it supports sub-100ms-latency live tailing with margin).

### Milestone 5 — Verdict and documentation

Scope: turn the numbers into the decision and make the repo's documentation
truthful. Compute the gain table (per cell: Strategy E median, seqproto median,
ratio). Apply the pre-registered rule from the Decision Log mechanically. Then:

- Append a "Measured verdict (2026-MM-DD)" section to
  `docs/architecture/global-position-migration-path.md` containing the gain
  table, the GCP environment description, the verdict line, and — if PROCEED —
  the instruction that the next step is drafting the migration masterplan
  sequenced after MasterPlan 9, which must include the pre-registered phase-2
  decision point on the single-table event layout and `linkToStream`'s removal
  or side-table redesign (see the Decision Log); if NOT WORTH IT — which relief
  valve(s) the numbers indicate instead (batching, sharding) and at what
  projected ceiling.
- Replace `docs/DESIGN.md`'s annotated ceiling claims with the measured
  durable-fsync numbers for Strategy E (keep the history visible: "originally
  benchmarked at ~50K events/s on macOS; measured at N events/s on GCP pd-ssd,
  2026-MM-DD").
- Append ledger rows to `docs/perf-experiment-log.md` for the M3 and M4
  experiments (hypothesis, predicted ratio from the Purpose section, observed
  ratio, lesson — explicitly compare predicted 5–15× against observed).
- Fill this plan's Outcomes & Retrospective with the verdict line and the
  prediction-vs-observation deltas.

Acceptance: a reader opening `docs/architecture/global-position-migration-path.md`
sees the verdict and the numbers; the ledger has the rows; this plan's Outcomes
section ends with **PROCEED NOW** or **NOT WORTH IT**.


## Concrete Steps

All kiroku commands run from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`;
all kiroku-bench commands from
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku-bench` (enter its dev shell
with `nix develop` or direnv first).

M1 verification:

```bash
cabal haddock kiroku-store
grep -rn "gap-free" kiroku-store/src README.md   # expect: only implementation-note phrasing, no API promise
cabal test kiroku-store                           # expect: all suites PASS
cd /Users/shinzui/Keikaku/bokuno/keiro && grep -rn "GlobalPosition" --include='*.hs' . | grep -v dist-newstyle
```

M2 verification (kiroku-bench):

```bash
cabal build all
# smoke: start the local db (process-compose up), create schema, then:
KIROKU_BENCH_MODE=append-only KIROKU_BENCH_WRITERS=32 PG_CONNECTION_STRING="$PG" \
  cabal run kiroku-bench &  sleep 30
curl -s 127.0.0.1:9570/metrics | grep 'bench_workload_op_seconds_bucket{op="append",le="0.0001"}'
# expect: a nonzero cumulative count in the 100µs bucket on the Mac
kill %1
```

M3 runs (local db; `$PGDATA` is `kiroku-bench/db/db`):

```bash
# Run A: as-is, 60s, record events/s:
curl -s 127.0.0.1:9570/metrics | grep '^bench_workload_ops_total{op="append"}'   # at t0 and t0+60s; rate = delta/60
# Run B:
psql "$PG" -c "ALTER SYSTEM SET wal_sync_method = 'fsync_writethrough'"; pg_ctl restart -D db/db
psql "$PG" -c "SHOW wal_sync_method"          # expect: fsync_writethrough
# ... rerun the workload, record ...
# Run C:
psql "$PG" -c "ALTER SYSTEM RESET wal_sync_method"
psql "$PG" -c "ALTER SYSTEM SET synchronous_commit = 'off'"; pg_ctl restart -D db/db
# ... rerun, record, then:
psql "$PG" -c "ALTER SYSTEM RESET synchronous_commit"; pg_ctl restart -D db/db
```

Expected M3 transcript shape (numbers illustrative):

```text
Run A (default):              ~6,800 events/s
Run B (fsync_writethrough):   ~900 events/s     # >=3x collapse => model confirmed, proceed to M4
Run C (synchronous_commit=off): ~7,500 events/s
```

M4: see Milestone 4 prose; GCP runs follow load-testing-infra's runbook from
that repo's checkout (its `.envrc` pins the project; run `direnv allow` there
once). Archive each run directory under `experiments/` with the established
naming, e.g. `2026-06-XX-seqproto-w32-p256-b1-t1`.

Commit messages throughout follow Conventional Commits and carry both trailers:

```text
docs(kiroku-store): weaken GlobalPosition contract to opaque strictly-increasing cursor

ExecPlan: docs/plans/63-decide-the-marten-style-global-position-migration-with-durable-fsync-benchmarks-and-option-preserving-contract-changes.md
Intention: intention_01ktvkqb9ee9j90wg64mgqd1mx
```


## Validation and Acceptance

The plan as a whole is accepted when: (1) the M1 contract edits are merged and
the keiro audit recorded; (2) `docs/perf-experiment-log.md` contains the M3 rows
showing whether the fsync model held, with the ≥ 3× collapse gate explicitly
evaluated; (3) either the plan stopped at the M3 gate with a "model falsified"
outcome, or the M4 gain table exists with 3-trial medians for all cells of both
arms plus the gap-scan p95; and (4) the verdict — **PROCEED NOW** or
**NOT WORTH IT**, derived mechanically from the pre-registered thresholds —
appears in `docs/architecture/global-position-migration-path.md`, in this plan's
Outcomes & Retrospective, and in the final report to the user. A novice must be
able to recompute the verdict from the archived experiment directories and the
Decision Log thresholds alone.


## Idempotence and Recovery

Everything here is safe to repeat. M1 edits are prose; re-running greps is free.
M3's `ALTER SYSTEM` changes are reverted with `ALTER SYSTEM RESET …` plus a
restart, and touch only the throwaway bench database under `kiroku-bench/db` —
verify reversion with `SHOW wal_sync_method` / `SHOW synchronous_commit` before
recording any subsequent run. The `seqproto` schema setup begins with
`DROP SCHEMA IF EXISTS seqproto CASCADE`, so every run reconstructs from
scratch; it must only ever be pointed at bench databases (the schema name is the
guard — production kiroku schemas are named differently, and nothing in the
spike reads or writes outside `seqproto.*`). GCP runs are independent; a failed
trial is discarded and re-run, never averaged in. If a GCP instance dies
mid-matrix, completed cells stand (each trial directory is self-contained) and
only missing cells are re-run — record any such recovery in Progress.


## Interfaces and Dependencies

No new Haskell dependencies in kiroku. In kiroku-bench: `GHC.Clock`
(`base`) for `timeIO`; the new `kiroku-bench-seqproto` executable depends on the
already-used `hasql`, `hasql-pool`, `prometheus-client`, `async`, `text`,
`bytestring` — mirror the `kiroku-bench-rawpg` stanza in
`kiroku-bench/kiroku-bench/kiroku-bench.cabal`. At the end of M4 the kiroku-bench
package must expose: executable `kiroku-bench-seqproto` honoring
`PG_CONNECTION_STRING`, `KIROKU_BENCH_WRITERS`, `KIROKU_BENCH_BATCH_SIZE`,
`KIROKU_BENCH_PAYLOAD_BYTES`, `KIROKU_BENCH_SEQPROTO_HOT`, and emitting the
standard `bench_workload_ops_total{op="append"}` /
`bench_workload_op_seconds{op="append"}` metric shape on `127.0.0.1:9570`; and
the file `kiroku-bench/kiroku-bench/sql/seqproto-setup.sql`. No kiroku-store
module changes anywhere in this plan beyond haddock text in
`kiroku-store/src/Kiroku/Store/Types.hs` and
`kiroku-store/src/Kiroku/Store/Link.hs`. External services: the local
process-compose Postgres for M2/M3, and GCP project `tan-nb-exp` (`us-west1`)
via load-testing-infra for M4 — respect that repo's project-isolation preflight
in every script invocation.


## Revision Notes

- 2026-06-11: Added the `linkToStream` provisional-status work to M1 (new
  Decision Log entry, Progress item, M1 instructions, M5 verdict instruction,
  Interfaces constraint). Reason: a usage audit found `linkToStream` has zero
  consumers, yet it is the sole feature requiring the `stream_events` junction
  layout — the layout a PROCEED verdict's phase-2 single-table optimization
  would want to drop. Marking it provisional now preserves that option, exactly
  parallel to the `GlobalPosition` contract change this plan already ships.
