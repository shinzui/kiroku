# Strategy E's real-world append ceiling, and the Marten-style migration path

- **Status:** Analysis — 2026-06-11
- **Motivation:** kiroku-bench numbers that justified Strategy E (`docs/DESIGN.md`
  "~0.2ms per lock cycle, ~5K batches/s, ~50K events/s") reproduce on a MacBook
  but degraded badly on a robust GCP benchmark. This document records (1) the
  validation of kiroku-bench, (2) the root-cause analysis of the divergence, and
  (3) the migration path to a Marten-style gappy-sequence schema that keeps the
  public API stable if/when Strategy E's ceiling becomes a real problem.
- **Related:** `docs/DESIGN.md` (Strategy E rationale), `docs/SCALING-ANALYSIS.md`
  (cites the ~50K events/s validation), `docs/plans/8-high-write-append-ordering-and-atomicity-audit.md`
  (contiguity audit), kiroku-bench repo (`../kiroku-bench`),
  `docs/architecture/marten-reference.md` (file-level study of Marten's sequence
  allocator, gap detector, and high-water-mark daemon — the migration target's
  mechanics), `docs/plans/63-decide-the-marten-style-global-position-migration-with-durable-fsync-benchmarks-and-option-preserving-contract-changes.md`
  (the benchmark-gated go/no-go decision plan).

## Part 1 — kiroku-bench validation

### Verdict

The benchmark harness itself has **no fatal flaw**. Payloads are pre-allocated
outside the timed region, latency is observed once per call with throughput
counted per event, errors are counted out-of-band, and the SIGTERM drain is
clean. The misleading Mac numbers are not a bench bug — they are an
**architecture × platform interaction** that any client-side benchmark would
reproduce identically.

### Root cause: the `$all` row lock is held across the WAL flush

Every append variant is a single CTE statement executed in autocommit mode
(`kiroku-store/src/Kiroku/Store/Effect.hs:138-146` — one
`Pool.use … Session.statement` per append). The CTE's `all_update` step
(`kiroku-store/src/Kiroku/Store/SQL.hs:191-228`) takes an exclusive row lock on
the `$all` row (`UPDATE streams … WHERE stream_id = 0`). PostgreSQL releases row
locks only at transaction end — which, for an autocommit statement, is the
implicit COMMIT, **including the synchronous WAL flush**.

Consequences:

1. **All appends, store-wide, serialize on full commit latency.** Writer B's
   `all_update` blocks until writer A's transaction has flushed WAL and
   committed. Adding writers, cores, or connections cannot raise throughput.
2. **Group commit cannot help.** PostgreSQL amortizes WAL flushes across
   concurrently-committing transactions, but appends here can never be
   concurrently committing — the next one cannot even reach its commit until
   the previous one releases the `$all` lock.
3. **The ceiling is exactly `batchSize / commit_latency`**, where
   `commit_latency` ≈ server-side CTE execution + WAL flush. Client–server RTT
   is *outside* the lock hold (single statement), so network latency is not the
   limiting factor once a handful of writers keep the pipeline full.

### Why the Mac flatters this architecture

The local bench Postgres (`kiroku-bench/db/db/postgresql.conf`) runs over a Unix
socket with stock settings — `fsync=on`, `synchronous_commit=on`, default
`wal_sync_method`. That looks honest, but **on macOS, `fsync()` does not flush
the drive's write cache** (Apple requires `fcntl(F_FULLFSYNC)`, which Postgres
only issues under `wal_sync_method=fsync_writethrough`). A "durable" commit on
the Mac therefore completes in ~50–200µs — which is precisely the "~0.2ms lock
cycle" DESIGN.md measured, and where "~5K batches/s" comes from.

On GCP the WAL flush is real: ~0.5–2ms on pd-ssd/pd-balanced, more if the
instance uses regional disks or Cloud SQL with synchronous HA replication. The
serialized ceiling drops accordingly:

| Environment | Effective commit latency | Strategy E ceiling (batch=1) | (batch=10) |
|---|---|---|---|
| macOS, default fsync (a lie) | ~0.1–0.2ms | ~5–10K events/s | ~50–100K events/s |
| GCP pd-ssd, honest fsync | ~1ms | ~1K events/s | ~10K events/s |
| Cloud SQL regional HA | ~2–5ms | ~200–500 events/s | ~2–5K events/s |

So "way worse on GCP" is the *expected* behavior of Strategy E on durable
storage, not a measurement error. The comparison baselines diverge for the same
reason: `kiroku-bench-rawpg` writers commit independently, so group commit lets
them share WAL flushes and scale with concurrency — the kiroku-vs-rawpg gap is
small on the Mac and explodes on GCP. That widening gap is the signature of the
`$all` lock defeating group commit.

### Decisive experiments (cheap, falsifiable)

1. **On the Mac:** set `wal_sync_method = fsync_writethrough` and rerun
   `append-only`. If the analysis is right, Mac throughput collapses to
   GCP-like numbers. This is the smoking gun, reproducible locally.
2. **On GCP:** set `synchronous_commit = off` and rerun. Throughput should jump
   back toward Mac numbers, confirming the WAL-flush-under-lock bottleneck
   (and incidentally measuring what an async-commit deployment would buy).
3. **During a GCP run:** sample `pg_stat_activity` wait events — expect writers
   stacked on `Lock:tuple`/`Lock:transactionid` against the `$all` row.

### Secondary bench issues (real, but not the explanation)

Worth fixing for fairness and precision; none of them changes the conclusion:

- **Pool asymmetry vs the baseline.** `kiroku-bench` defaults to `poolSize=10`
  with `writers=32` (`app/Main.hs:109`), while `kiroku-bench-rawpg` sizes its
  pool to `writers + 4` (`app/RawPg.hs:93-94`). The rawpg baseline gets full
  concurrency; kiroku is throttled to 10 in-flight ops. Strategy E serializes
  anyway, so this barely affects kiroku's number, but it muddies the
  "kiroku overhead vs raw postgres" attribution. Default both to the same rule.
- **Non-monotonic clock.** `timeIO` uses `getCurrentTime`
  (`src/Kiroku/Bench/Runtime.hs:46-51`) despite its haddock claiming monotonic
  timing. NTP steps can distort latency samples. Use `GHC.Clock.getMonotonicTime`.
- **Histogram floor too high for the Mac.** The lowest bucket boundary is 0.5ms
  (`src/Kiroku/Bench/Metrics.hs:91-97`), but Mac-local appends run ~150µs — all
  samples land in the first bucket, so local latency quantiles are
  unresolvable. Add 50/100/250µs buckets.
- **Default `batchSize=1`** while DESIGN.md's 50K events/s claim assumes
  batch=10 — easy to compare the wrong numbers across runs.
- **Compressible payload.** The constant `'B'`-fill payload
  (`src/Kiroku/Bench/Event.hs:27-32`) TOAST-compresses to almost nothing,
  understating I/O versus realistic payloads (affects both environments
  equally).

### What this changes in existing docs

`docs/DESIGN.md:17,21,661` and `docs/SCALING-ANALYSIS.md:9,275` state the ~50K
events/s ceiling as validated. It is validated **only on hardware where fsync
is free**. On cloud infrastructure with honest durability the ceiling is
`batchSize / durable_commit_latency` — typically 5–20× lower. The "throughput
ceiling is acceptable" judgment needs re-evaluation against actual GCP numbers.

## Part 2 — Migration path to a Marten-style schema with a stable public API

If the real ceiling is unacceptable, the escape is to stop serializing appends
on the `$all` row: assign global positions from a Postgres sequence
(Marten-style). Appends to different streams then commit concurrently and share
group-commit WAL flushes — but positions acquire **gaps** (rolled-back
transactions burn sequence values) and, more importantly, can become **visible
out of order** (position 101 can commit before 100). That forces a high-water-
mark ("safe horizon") mechanism on the read side — the complexity Marten's
async daemon carries, and the reason Strategy E was chosen.

The good news: the public API was designed defensively enough that this
migration does not break it.

### Why the API surface survives

| API element | Current contract | Gap/out-of-order tolerant? |
|---|---|---|
| `GlobalPosition` (`Types.hs:90`) | Abstract newtype, no exported constructor, only `Eq`/`Ord`, no arithmetic | **Yes** — consumers can only echo back positions the store produced |
| Read pagination (`Read.hs`) | Exclusive cursor (`> startPos`), "advance to last event's position" | **Yes** — works identically for dense or sparse positions, forward and backward |
| Checkpoints (`subscriptions.last_seen`) | `BIGINT`, advanced via `GREATEST` upsert; stores "last delivered", not "next expected" | **Yes** — existing checkpoint rows stay valid across the migration |
| Delivery contract (`Subscription.hs:58-81`) | At-least-once, per-batch checkpoint, handlers must be idempotent | **Yes** — gap-daemon redeliveries fit inside the existing contract |
| `Store` effect / interpreter split (`Effect.hs` → `SQL.hs`) | SQL is an implementation detail behind the effect | **Yes** — the swap is an interpreter change; both strategies could coexist behind a settings flag |

Historical data migrates trivially: the existing contiguous positions are a
valid instance of a sparse sequence. Keep them verbatim and start the new
sequence above `max(position)` — no renumbering, no client-visible event.

### What actually breaks (the honest costs)

1. **The documented contract.** The `GlobalPosition` haddock promises "gap-free"
   (`Types.hs:85-88`), README promises a "contiguous `$all` stream", and
   DESIGN.md sells Strategy E on contiguity. These are promises consumers
   (keiro) are entitled to lean on — e.g., computing event counts as position
   differences. API stability is threatened by *documentation*, not types.
2. **Read-your-own-writes on `$all`.** `Append.hs:32-36` guarantees an appended
   event is immediately visible to reads on the same handle. With out-of-order
   commits, `readAllForward` must clamp to the safe horizon, so your own append
   may lag in `$all` reads. Per-stream reads are unaffected (stream versions
   stay contiguous via the source-stream row lock regardless). The guarantee
   must be re-scoped to per-stream reads.
3. **The daemon complexity arrives.** The high-water-mark tracker — wait for
   in-flight transactions, time out genuine gaps, only then advance the
   publishable horizon — must live inside `EventPublisher`/`Worker` and
   `readAllForward`. All behind the API, but live-tail latency gains a
   gap-timeout stall mode under rollback-heavy load. (Plan 61's websocket
   gap-handling work is early groundwork.)
4. **Metrics semantics.** `global_position − checkpoint` lag in kiroku-metrics
   becomes an upper bound on undelivered events rather than an exact count.

### Option-preserving actions now (cheap)

1. **Freeze `GlobalPosition` opacity** — never export the constructor or add
   `Num`/`Enum`/arithmetic instances.
2. **Reword the public contract** from "contiguous, gap-free" to "strictly
   increasing, opaque cursor — do not assume density", demoting contiguity to
   an implementation note in DESIGN.md. Do this before keiro grows code that
   subtracts positions to count events.
3. **Don't build features that lean on density** — no replay buffers or caches
   indexed by position arithmetic.
4. **Keep checkpoint semantics "last delivered"**, never "next expected = last + 1".

### Relief valves before a schema migration

The Part 1 findings *shrink* this list compared to DESIGN.md's framing, but the
ordering still holds — try these before the Marten migration:

- **Bigger batches.** The ceiling scales linearly with `batchSize`; the
  serialized cost is per-commit, not per-event.
- **`synchronous_commit = off`** (or per-transaction via `SET LOCAL`). Buys
  back most of the Mac-vs-GCP gap as a pure configuration change — but it is a
  sharp trade for an event store, not a free one. It is *not* `fsync=off` (no
  corruption; recovery is consistent, losing at most ~3×`wal_writer_delay` of
  acked commits), but three hazards compound: (1) acknowledged appends can
  vanish after a crash; (2) commit visibility precedes the WAL flush, so
  subscribers can deliver events that are then lost — external projections end
  up holding phantom events; (3) on recovery the `$all` counter rolls back with
  the lost events, so new, different events **reuse the vanished global
  positions** — external checkpoints silently skip them and position/event-id
  dedup conflates phantom with real. Internal checkpoints roll back
  consistently (same database); external consumers do not. Defensible for
  re-derivable streams via per-transaction opt-in; not a blanket production
  setting for a system-of-record store with external subscribers. Note the
  Marten-style schema below gets its throughput from group commit *with* full
  durability — it does not need this trade.
- **Faster commit storage** (local SSD with controlled durability, write-back
  battery-backed setups) — moves `commit_latency` directly.
- **Tenant/schema-level sharding** into multiple stores — multiplies the
  ceiling by shard count; positions were never comparable across stores anyway.
- **Strategy D (Hindsight xid8)** remains the other escape hatch named in
  DESIGN.md; it shares the same API-survival analysis as Marten-style (sparse,
  visibility-managed positions) with different operational trade-offs
  (MVCC-horizon stalls instead of gap timeouts).

### Bottom line

The Marten-style migration is real, mechanically clean, and API-stable —
provided the documented contract is weakened to "opaque, strictly increasing"
*before* downstream consumers calcify on contiguity. The benchmark divergence
does not reveal a broken bench; it reveals that Strategy E's headline numbers
were measured on hardware where the one thing the strategy serializes — the
durable commit — was free.

## Part 3 — Measured GCP verdict (2026-06-11)

Part 1 predicted the `$all` lock collapses durable throughput; Part 2 *assumed*
the Marten migration recovers it via group commit. ExecPlan 63 M4 measured both
arms on GCP to test that second assumption. **The lock is a real serialization
point — but the group-commit payoff Part 2 counted on does not materialize on
durable cloud storage.**

### How it was measured

- **Strategy E arm** — the production `kiroku-store` append path
  (`kiroku-bench` append-only, kiroku `786282e`).
- **seqproto arm** — a faithful one-variable-changed prototype: kiroku's
  `appendAnyVersionSQL` re-qualified to a throwaway `seqproto` schema, with the
  `$all` `all_update` CTE removed and `$all` positions claimed from
  `nextval('seqproto.global_position_seq')`. Every other write (event insert,
  *both* junction inserts, source-stream upsert, NOTIFY trigger) is byte-for-byte
  identical (`kiroku-bench-seqproto`, kiroku-bench `260e93a`).
- Cross-stream workload (each writer on its own stream), writers=32,
  payload=256 B, 180 s steady state, **fresh postgres VM + disk per trial**, 3
  trials/cell, median reported. Full durability (`synchronous_commit=on`,
  default `wal_sync_method`), PostgreSQL 17.9, GCP `tan-nb-exp`/`us-west1`,
  pd-ssd. load-testing-infra `bf60458`.

### The numbers

| cell (w32, durable, median of 3) | Strategy E | seqproto | ratio |
|---|---|---|---|
| **batch=1 (single-event)** | **687 ev/s** | **1,499 ev/s** | **2.18×** |
| batch=10 | 4,364 ev/s | (not measured) | — |

The ratio is not a harness artifact. In identical 180 s windows seqproto
completed **294,549** appends vs Strategy E **122,711** (a *direct count* of work
done, independent of any rate computation); database growth was +218 MiB vs
+117 MiB; and both arms ran at **~40–44 % postgres CPU, 100 % cache-hit, disk
unsaturated** — i.e. both are **durable-commit-bound, not CPU/IO/lock/read-bound**
(Grafana host + postgres panels archived per run). Strategy E p95 latency
**165 ms** (the 32-writer `$all`-lock queue) vs seqproto **45 ms** isolates the
lock as the difference.

### The decisive finding: removing the lock does not buy *scaling*

Part 2's premise was group-commit amplification (predicted 5–15× at 32 writers).
It does not appear: **seqproto throughput is flat in writer count** —
w8 **1,559 ev/s** → w32 **1,499 ev/s** (slightly *down*). If group commit were
amortizing concurrent WAL flushes, 32 committers would beat 8; they don't. On
this pd-ssd, durable commits effectively serialize *regardless of the lock*, so
removing the `$all` lock yields a one-time **2.18×** (the lock's own overhead)
and then hits a second wall — the durable-commit path itself — at **~1,500
single-event commits/s**. This is the M3 Mac result (`F_FULLFSYNC` serialized
commits, flat in writers) reproduced on the cloud hardware that was expected to
behave differently. Part 2's sentence "appends … share group-commit WAL flushes"
is the assumption this measurement falsifies for the unbatched single-event path.

### Verdict against the target workload

Pre-registered rule: `G(32,1)=2.18×` is in the **judgment zone** (`≥2.0` but
`<3.0`; PROCEED requires `≥3.0`), to be decided against a written target. Target
recorded 2026-06-11: **a few thousand ev/s of latency-sensitive single-event
cross-stream appends that cannot batch.**

- Strategy E single-event ceiling: **~687 ev/s**, flat in writers — short of target.
- seqproto single-event ceiling: **~1,499 ev/s**, *also* flat in writers — **also
  short of target.**
- **Neither single-store design reaches "a few thousand" single-event durable
  appends/s.** The rewrite improves it 2.18× and then stalls at ~1,500.
- The remaining gap is closed by levers that do **not** require the core rewrite:
  **sharding** (tenant/schema-level stores — positions were never cross-store
  comparable) multiplies *either* ceiling linearly: ~5 Strategy-E shards
  (5×687 ≈ 3,400 ev/s) or ~2 seqproto shards reach a few thousand; **faster
  commit storage** lowers `commit_latency` for both; **`commit_delay` tuning** is
  the one untested lever that *could* let group commit amortize on the sequence
  arm — but the flat w8→w32 scaling argues it won't.

> **Verdict: NOT WORTH IT.** An 8–10 ExecPlan core rewrite plus a permanent
> high-water-mark daemon buys a flat **2.18×** that still falls short of the
> latency-sensitive target, while **sharding the current architecture reaches
> the target with linear, operationally-routine scaling** and no read-side
> complexity. The rewrite would only cut shard count ~2.2× for a given target —
> not worth the permanent complexity tax (gap timeouts, safe-horizon daemon,
> re-scoped read-your-writes).

**What would overturn this:** a cheap `commit_delay`/group-commit probe (or
faster-fsync storage) showing the sequence arm scaling *past* ~1,500 single-event
durable commits/s on one store while Strategy E stays lock-capped at ~687. The
current flat writer-scaling argues against it, but it is the one unmeasured
lever — revisit the verdict if a single such probe contradicts the flat-scaling
evidence.

### Caveats (examined; none changes the verdict)

- **Eventlog asymmetry:** seqproto ran with the GHC eventlog *on* (~2 % overhead),
  Strategy E *off*; correcting *widens* G to ~2.2× — still judgment-zone.
  `G(32,10)` was not measured (seqproto w32/b10 was not run) because
  `G(32,1)=2.18 < 3.0` already precludes PROCEED regardless of the b10 ratio.
- **Harness asymmetry:** seqproto is a raw-hasql driver, Strategy E the full
  `kiroku-store` API — but both issue one statement / one commit per append with
  near-identical SQL, and both are DB-side commit-bound, so client-side
  differences are negligible (the measured latency gap *is* the `$all`-lock queue,
  not client overhead).
- **Separate discovery (not part of this decision):** current kiroku `786282e`
  measured ~687 ev/s at w32/b1 — ~30 % below May's `c672d58` ~972 ev/s on the
  *same* PostgreSQL 17.9. Possible append-path regression over those two weeks,
  worth investigating independently. The verdict is unaffected: it rests on the
  same-environment ratio, where both arms ran on `786282e`-era infrastructure.
- **Read side was never the blocker:** the gap-detection query (the HWM daemon's
  steady-state poll) ran p95 2.41 ms ≪ 25 ms gate on 5M rows. The migration's
  cost is justified by throughput, and the throughput payoff is the ~1.5× short
  of need.
