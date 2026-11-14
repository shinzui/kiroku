---
type: Review
title: Kiroku 0.13.0.2 and adapter 0.8.0.0 trace correlation cohort
description: The kiroku-store 0.13.0.2 and shibuya-kiroku-adapter 0.8.0.0 cohort changes no kiroku-store library code, threads the new strict telemetry field correctly through both adapter construction paths with a LinkOnly default that PostgreSQL-backed tests prove for both policies, fan-out, consumer groups and events without traceparent, and adds per-event cost only inside shibuya-core, whose same-process allocation gate shows LinkOnly cheaper than the previous parent-child path; it is approved, with a missing consumer upgrade edge for the adapter break and a shibuya-core lower bound that still admits 0.13.0.0 recorded as follow-ups.
generated:
  by: process:claude-code
  at: "2026-11-14T16:24:43Z"
reviewId: REV-5
subject: mori://shinzui/kiroku
subjectKind: project
reviewedSha: 3f0fd44ecbc65556b6ca3080c40e5f692499df1e
coverage: incremental
baseSha: aa2c6abf44faf8ed6fe27fc201625d8b965cf6b4
previousReview: REV-4
reviewedAt: "2026-11-14T16:24:43Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-opus-5-5
effort: low
outcome: approved
dimensions:
  - correctness
  - performance
  - test-coverage
  - documentation
  - operability
context: >-
  Reviewed the three commits between the kiroku-cli 0.3.0.1 release commit
  and the release commit that published kiroku-store 0.13.0.2 and
  shibuya-kiroku-adapter 0.8.0.0: f7969f6 (IR-21, documentation only),
  39f6565 (the adapter change) and 3f0fd44 (versions and changelogs). The
  adapter source diff, the kiroku-store benchmark diff and both changelogs
  were read in full. The shibuya-core side of the change was judged from
  mori://shinzui/shibuya/plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing,
  mori://shinzui/shibuya/plans/59-adopt-trace-correlation-in-the-kiroku-adapter-with-a-link-only-default
  and the shibuya-core 0.13.0.1 changelog, not by re-running its gates. The
  window from REV-4's commit 084fd835 to this base has no review record; see
  Limits. Repository HEAD equals the reviewed commit.
---

# Kiroku 0.13.0.2 and adapter 0.8.0.0 trace correlation cohort

## Verdict

Approved. The adapter does what its changelog says. Both configuration
records get a strict `telemetry :: AdapterTelemetry` field. Both defaults use
`kirokuDefaultTelemetry` (`LinkOnly`). The value reaches every `Adapter` the
package builds: the single adapter and each consumer-group member. kiroku-store
0.13.0.2 changes no library code. Its only change is that the shipped
`kiroku-shibuya-overhead` benchmark now needs `shibuya-core >=0.13 && <0.14`,
which keeps the sdist buildable next to the new adapter. Two follow-ups are
recorded below. Neither blocks the release.

## What changed

| File | Change |
| --- | --- |
| `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` | Adds the `telemetry` field to `KirokuAdapterConfig` and `KirokuConsumerGroupConfig` and the `kirokuDefaultTelemetry` value. Re-exports `AdapterTelemetry (traceCorrelation)`, `defaultAdapterTelemetry` and `TraceCorrelation (..)`. The field is passed through `kirokuAdapter` and `kirokuConsumerGroupProcessors`, and the module header gains a trace-correlation section. |
| `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` | Version 0.8.0.0. Every stanza requires `shibuya-core >=0.13 && <0.14`. The test suite adds `CorrelationSpec` and `hs-opentelemetry-exporter-in-memory`. |
| `shibuya-kiroku-adapter/test/CorrelationSpec.hs` | New PostgreSQL-backed suite with eight examples. |
| `kiroku-store/kiroku-store.cabal`, `kiroku-store/bench/ShibuyaOverhead.hs` | Version 0.13.0.2. The benchmark's `shibuya-core` bound changes and its direct `Adapter` literal sets `telemetry = defaultAdapterTelemetry`. |
| ADR-24, `docs/capabilities/*` | Record the default and why it was chosen. |

## Correctness

- `defaultKirokuAdapterConfig` and `defaultConsumerGroupConfig` both use
  `kirokuDefaultTelemetry`, defined once as `defaultAdapterTelemetry
  {traceCorrelation = LinkOnly}`. Because it is built by record update,
  options that later shibuya-core 0.13.x releases add to `AdapterTelemetry`
  keep their core defaults.
- `kirokuConsumerGroupProcessors` copies the group's `tel` into each
  member's `KirokuAdapterConfig`, and `kirokuAdapter` copies it into the
  `Adapter`. No path builds an `Adapter` without it. Since the field is
  strict and has no default in a record literal, the compiler rejects any
  path that was missed.
- The default makes sense for an event store. Replays, catch-up and several
  subscriptions reading one event would otherwise attach every subscriber's
  processing to the writer's trace, with no time limit. Under `LinkOnly`,
  each processed event gets its own trace, which links back to the span that
  appended the event. `defaultAdapterTelemetry` (`ParentAndLink`) restores the
  earlier shape and adds the link.
- The corrected 0.5.0.0 changelog note is right: `kiroku-otel`'s native
  subscription spans are separate roots. They correlate with Shibuya's
  processing spans through the `kiroku.*` attributes, not through a shared
  trace.

## Hot-path performance

The changed per-event work is inside shibuya-core. The adapter only passes
a value through once, when it is built. kiroku-store's library has no source
change since 0.13.0.1, so its ADR-5 structural and workload gates cannot see
this cohort. I ran `just perf-structure` at the reviewed commit as a check
(52 examples, 0 failures) and did not run `just perf-workload-gate`: it would
only measure unchanged code.

The relevant evidence comes from shibuya-core's same-process gate for plan 55.
Allocation there is deterministic. Adding the link costs 1,151 bytes per
message on the enabled-with-headers path, compared with 1,360 bytes for the
same delta before the change. `LinkOnly` allocates about 135 bytes per
message less than `ParentAndLink` because it builds no parent context. Kiroku's
new default is therefore the cheaper policy. I took these numbers from the
plan and did not rerun them.

Plan 59's before/after `kiroku-shibuya-overhead` runs, two interleaved runs
per side, show overlapping throughput at 100, 1,000 and 5,000 events. Each
side is a different build, so this is telemetry, not a same-process gate,
and this review does not rely on it. Plan 59's 200,000-event catch-up heap
check found no retained memory from the link. The slope of about 2.2 bytes
per event that it found is the same with tracing off and on the pre-change
tree, so it predates this cohort. Plan 59 hands that slope to Kiroku to
investigate separately.

## Test coverage

`CorrelationSpec` runs against PostgreSQL with an in-memory exporter. It
covers:

- the default policy on both configuration records;
- a `ParentAndLink` override showing up on a built adapter;
- the policy on every consumer-group member;
- a `LinkOnly` processing span as a linked root;
- a `ParentAndLink` processing span as the writer's child with one link;
- two subscriptions to one event producing two traces that link the same
  writer span;
- no link under either policy when the event has no `traceparent`.

Before the release commit, `shibuya-kiroku-adapter-test` passed 53 examples
with 0 failures and `kiroku-store-test` passed 632 with 0 failures.
`nix flake check` and `cabal check` passed for both packages; the adapter
showed only its long-standing advisory `-O2` warning.

## Documentation and downstream

- The adapter changelog lists every break: the trace shape, the new strict
  field, and the span rename in core 0.13 from `<processor> process` to
  `process <processor>`. It also tells users how to restore the old shape.
- The four first-party consumers found through mori, keiei, kioku, mori
  and rei, all pin `shibuya-kiroku-adapter ^>=0.7` and build no
  `KirokuAdapterConfig` or `KirokuConsumerGroupConfig` record literals. They
  are unaffected until they choose to upgrade, and upgrading is then
  source-compatible for them apart from the shibuya-core 0.13 migration.

## Follow-ups

1. **No upgrade edge for the adapter break.**
   `blueprints/kiroku-upgrade` identifies its edges by the `kiroku-store`
   version, which only moved by a patch here. The adapter's 0.7 → 0.8 break
   needs judgement from each of the four consumers: shibuya-core 0.13's new
   `Adapter` field for adapters they build themselves, renamed span names in
   saved trace queries, and the new trace shape. Only the changelog covers
   it today. Add an edge, or an adapter-version probe, before those
   consumers upgrade.
2. **The shibuya-core lower bound admits 0.13.0.0.** That release
   allocates 20–30% more per run for `Async` runners whose handlers wait.
   0.13.0.1 fixes this, and its changelog says those runners now allocate
   less than 0.12.0.0 did. Consumer-group members must be `Serial` and are
   not affected. A single adapter run under `Async n` could still resolve to
   0.13.0.0. Time was unchanged, so this is not a correctness issue.
   Consider `>=0.13.0.1` at the next adapter release.

## Limits

- **Unreviewed window.** No review record covers the releases between
  REV-4's commit `084fd835` and this base: kiroku-store 0.12.0.0, 0.13.0.0
  and 0.13.0.1; kiroku-store-migrations 0.7.2.0 and 0.7.3.0; kiroku-otel
  0.3.0.0 and 0.3.0.1; kiroku-cli 0.2.0.11, 0.3.0.0 and 0.3.0.1;
  kiroku-metrics 0.4.0.0 and 0.4.0.1; shibuya-kiroku-adapter 0.7.0.0 and
  0.7.0.1. This record does not vouch for any of them.
- The shibuya-core gate numbers are quoted from its plans and were not
  rerun. No remote cell or timing experiment was run for this review.
- The `kiroku-shibuya-overhead` benchmark builds its `Adapter` directly with
  `ParentAndLink`, so it does not exercise the adapter's new `LinkOnly`
  default.
