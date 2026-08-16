---
type: Improvement Request
title: Order multi-stream append locks ahead of the $all row
description: >-
  Establish every source-stream row lock before any $all row lock in appendMultiStream, including
  for streams that do not exist yet, so a multi-stream append can no longer deadlock against a
  concurrent single-stream append to one of its still-fresh streams.
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-16T00:00:00Z"
timestamp: "2026-08-16T00:00:00Z"
requestId: IR-7
status: proposed
origin: mori://shinzui/kiroku
---

# Improvement Request: Order Multi-Stream Append Locks Ahead of the `$all` Row

## Why this is a request and not a defect

`appendMultiStream` publishes one deadlock-avoidance claim, in the Haddock on
`Kiroku.Store.Append.appendMultiStream`: the interpreter pre-locks the named streams in
deterministic `stream_id` order "to avoid deadlocks when two concurrent multi-stream calls touch
overlapping streams in different user orders". That claim is about multi-versus-multi contention
on streams that exist, and it holds.

Nothing in the published API claims a multi-stream append cannot deadlock against a
*single-stream* append. `mori://shinzui/kiroku/plans/1-schema-cte-and-concurrency-correctness-audit`
classified F4 as should-fix rather than must-fix on exactly this reasoning — "PostgreSQL handles
the safety side" — and the F4 fix (`8edfbee`) narrowed the window without claiming to close it.
Nothing is silently wrong: PostgreSQL detects the cycle, aborts one transaction with `40P01`, and
nothing is committed. `kiroku-store` retries the append once and, since 0.8.0.0, surfaces a
repeated conflict as `Kiroku.Store.Error.TransientTransactionFailure`, documented retryable.

So this asks for behavior the library never provided — deadlock-free multi-versus-single append —
rather than reporting behavior it promised and does not deliver. One claim *was* broken: an
internal comment on `lockStreamsForMultiStmt` asserted that multi-versus-single deadlocks "are
avoided". That comment was corrected in the same change that introduced
`TransientTransactionFailure`; it was an implementation note, not a consumer-facing contract.

## The cycle

`lockStreamsForMultiStmt` pre-locks with `WHERE stream_name = ANY($1)`, which matches only rows
that already exist. A stream being created by this very append is not matched, so it is not
pre-locked, and the intended source-before-`$all` ordering is not established for it. Each
per-stream CTE then takes its source row lock and the `$all` row lock in that order, so across a
multi-stream transaction the real acquisition sequence interleaves them:

- multi-stream append over `[A, B]` where `B` is fresh: lock `A` → lock `$all` (both inside `A`'s
  CTE) → lock `B` (in `B`'s CTE).
- concurrent single-stream append to the still-fresh `B`: lock `B` → lock `$all`.

Each holds what the other wants. Reproduced deterministically against the real schema with two
sessions on PostgreSQL 18.4:

```
ERROR:  40P01: deadlock detected
CONTEXT:  while inserting index tuple (0,4) in relation "streams"
```

The `CONTEXT` names the fresh-stream unique index on `stream_name` — the exact acquisition the
pre-lock cannot cover.

Observed rate in `Test.Concurrency`'s `single-stream append retry does not leak transient
SQLSTATEs`, which drives 25 rounds of this shape: 0 occurrences in 30 unloaded runs, 1 occurrence
in 24 runs under eight-way CPU contention.

## Why the benchmarks never showed it

`kiroku-store`'s benchmark suite cannot produce this cycle, and that is a property of what
benchmarks are for rather than an oversight:

- The concurrent workloads (`runConcurrentWriters`, the B9 pool-saturation loop) call only
  `appendToStream`, and give every thread its own unique stream name. The only contended row is
  `$all`, and a single shared lock cannot form a cycle.
- The `appendMultiStream` workloads (`runAppendMultiStream`, the regression gate's
  `runProductionMultiAppend`) run single-threaded in the tasty-bench iteration loop, and their
  target streams are pre-seeded during setup — which is precisely the condition under which the
  pre-lock works.

Partitioned streams, warm fixtures, and no contention noise are what make a throughput benchmark
trustworthy, and they are the same properties that make this defect unreachable. A benchmark
measures cost under a chosen workload; it is not a concurrency-correctness probe.

## What is requested

Establish every source-stream row lock before any `$all` row lock in the multi-stream path,
including for streams that do not exist yet. The obvious shape — materialize the missing stream
rows in the pre-pass, then lock all of them in `stream_id` order — collides with how freshness is
currently detected: `appendNoStream` learns that a stream did not exist from
`INSERT ... ON CONFLICT DO NOTHING RETURNING` returning a row. Pre-creating the row destroys that
signal, so the `NoStream` decision has to move into the pre-pass and be threaded into the
per-stream statements.

Two constraints on any implementation:

1. **`NoStream` semantics must not change.** A `NoStream` operation against a stream that already
   existed before the call must still be rejected with `StreamAlreadyExists`, and the rejection
   must still roll the whole batch back.
2. **Append throughput must not regress.** `$all` row-lock hold time is the append throughput
   ceiling for this store, so any change that lengthens it — in particular a global `$all`-first
   ordering, which would fix this class outright — has to be measured, not assumed. Evaluate
   against `just bench-regression` and the workload gate before adopting.

## What is deliberately not requested

Global `$all`-first lock ordering across both append paths. It would eliminate this and every
related cycle, but it moves the serialization point to the start of every append and lengthens the
hold across the whole statement. Prior work
(`mori://shinzui/kiroku/plans/21`, `22`, `23`) settled comparable append-shape questions on
benchmark evidence rather than reasoning, and the same bar applies here. It stays on the table only
if measurement clears it.

## Acceptance

- A concurrent multi-stream append over `[A, B]` with `B` fresh, racing a single-stream append to
  `B`, completes without a `40P01` on either side, asserted over enough rounds and under enough
  contention to have caught the current behavior.
- `NoStream` rejection semantics are unchanged, proven by the existing append precondition suite.
- `just bench-regression` and `just perf-workload-gate` pass against the recorded baseline, with
  the multi-stream append figures reported in the change.
- `just test-matrix` passes on PostgreSQL 17 and 18.
