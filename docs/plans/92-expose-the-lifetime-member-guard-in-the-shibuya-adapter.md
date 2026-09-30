---
id: 92
slug: expose-the-lifetime-member-guard-in-the-shibuya-adapter
title: "Expose the lifetime member guard in the Shibuya adapter"
kind: exec-plan
created_at: 2026-09-30T21:37:38Z
intention: "intention_01m3t40nqze459mqewtt1tz53e"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T21:37:38Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-30T22:19:31Z
      mode: "update"
      note: "Narrowed to IR-17 and renamed; store work moved to plan 93"
---

# Expose the lifetime member guard in the Shibuya adapter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku is a PostgreSQL event store written in Haskell. A *subscription* is a long-running worker
that reads events in order and hands each one to an application handler. A *consumer group*
splits one subscription into `size` *members*; each member processes the streams whose PostgreSQL
hash lands on its index and records its own progress (its *checkpoint*) under the key
`(subscription name, member)`. Exactly one live process must run each member; two processes on
one member both handle every event of that slice and both write the same checkpoint row.

`shibuya-kiroku-adapter` wraps a Kiroku subscription as a Shibuya `Adapter` so a Shibuya
processor can consume it. Its configuration record `KirokuAdapterConfig` exposes the consumer
group but not Kiroku's `consumerGroupGuard`, so a service using the adapter cannot ask Kiroku to
refuse a duplicate member. Plan 30 left the field off on purpose, because the store's guard was
then only a startup probe that could not see a running peer. The verification suite
`mori://shinzui/keiro-runtime-kenshou` measured the consequence: two adapter processes started as
member 0 of one subscription over 40 events produced 80 handler effects. Improvement request
IR-17 ([docs/improvement-requests/expose-the-lifetime-member-guard-in-the-shibuya-adapter.md](../improvement-requests/expose-the-lifetime-member-guard-in-the-shibuya-adapter.md),
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-17`) asks for the field once the
store guard is real.

The store side is delivered by plan 93,
[docs/plans/93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime.md](93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime.md)
(`mori://shinzui/kiroku/plans/93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime`),
which implements IR-15: with `consumerGroupGuard = True` the worker holds a session-level advisory
lock on a dedicated connection for its whole lifetime, refuses a duplicate with
`ConsumerGroupGuardConflict`, and stops with `ConsumerGroupGuardLost` if its guard connection was
lost and a peer took the member meanwhile. This plan is the dependent adapter surface: it adds an
opt-in `consumerGroupGuard` field to `KirokuAdapterConfig` and `KirokuConsumerGroupConfig`,
default `False`, forwards it to the store, documents exactly what a service gets, proves it with
two-store tests on PostgreSQL 17 and 18, and releases the adapter. It touches no `kiroku-store`
code, so the performance evidence plan 93 collects for the store stands; the adapter's own
overhead benchmark sets the guard off and is unchanged by construction.

After this plan, a service sets `consumerGroupGuard = True` on its adapter config, and a second
process that starts the same `(subscriptionName, member)` sees its adapter `source` terminate with
`ConsumerGroupGuardConflict` before any event reaches its handler; when the first process exits or
dies, a replacement starts and drains the backlog. With the field left at its default, nothing
changes, including the at-least-once two-process behavior kenshou reproduced.


## Progress

- [ ] Gate: plan 93 milestones 1 and 2 are implemented on this branch (`Kiroku.Store.Subscription.Types` exports `ConsumerGroupGuardLost`, and `kiroku-store/src/Kiroku/Store/Subscription/MemberGuard.hs` exists). Do not start milestone 1 before this holds.
- [ ] M1: add `consumerGroupGuard :: !Bool` to `KirokuAdapterConfig` and `KirokuConsumerGroupConfig`, default `False`; forward it in `kirokuAdapter` and `kirokuConsumerGroupProcessors`; re-export `ConsumerGroupGuardConflict (..)` and `ConsumerGroupGuardLost (..)`; write the Haddocks.
- [ ] M1: adapter tests: defaults are `False`; guard on across two stores refuses the second adapter before its handler runs and a replacement drains after shutdown; guard on within one in-process group opens one guard backend per member; guard off keeps the two-adapter duplicate-delivery behavior.
- [ ] M2: `docs/user/shibuya-adapter.md`, the adapter module Haddock, `docs/capabilities/shibuya-adapter.md` (CAP-19, logged and validated), and `shibuya-kiroku-adapter/CHANGELOG.md` `## Unreleased` updated; `cabal build all` green including the lifecycle fixture; `just test-matrix` green on PostgreSQL 17 and 18.
- [ ] M3: release `shibuya-kiroku-adapter` (PVP major) after explicit user confirmation, coordinated with plan 93's store release; clean-consumer check; IR-17 set to `completed` with release evidence; bundle log entry; Outcomes & Retrospective written; ADR distillation pass (expected: no new ADR, a pointer in ADR-11's consequences if plan 93's record does not already name the adapter).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: This plan covers IR-17 only. The store work (IR-15) that an earlier revision of this
  plan carried as milestones 1 and 2 is owned by plan 93, and this plan depends on it.
  Rationale: Plan 93 was authored concurrently as the IR-15 plan with a more complete store
  design (a closure-valued `acquireDedicatedConnection` field, a `MemberGuard` database phase and
  a `KirokuEventSubscriptionGuardReacquired` event, a `ConsumerGroupGuardLost` exception, a
  deterministic heartbeat tick seam, and two benchmark cells). Keeping two competing store designs
  in two plans would fork the work; one plan per request matches the way earlier requests were
  planned and lets each request complete on its own evidence. This plan's file was renamed from
  `92-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime-and-expose-it-in-the-shibuya-adapter.md`
  to match the narrowed scope; its id, intention, and provenance are unchanged.
  Date: 2026-09-30

- Decision: A guard refusal reaches the adapter user as the adapter's `source` terminating with
  the store's exception (`ConsumerGroupGuardConflict` at startup, `ConsumerGroupGuardLost` later),
  not as a synchronous exception from `kirokuAdapter`.
  Rationale: The store surfaces both through the worker thread and the subscription handle's
  `wait`, and the adapter's bridge (`subscriptionAckStream`) already turns a worker failure into
  a failing source; the existing adapter test for `FailIfMissing` proves the pattern. Making
  `kirokuAdapter` throw would require the store to change where it acquires the guard, which
  plan 93 decided against for ownership and cleanup reasons.
  Date: 2026-09-30

- Decision: The field is added to both `KirokuAdapterConfig` (one member) and
  `KirokuConsumerGroupConfig` (a whole in-process group), default `False` in both smart
  constructors, and forwarded unchanged to every member.
  Rationale: IR-17 asks for an opt-in with an unchanged default. Both records are the public
  ways to build members; a group helper that could not enable the guard would push users back to
  hand-built member configs.
  Date: 2026-09-30

- Decision: Re-export `ConsumerGroupGuardConflict (..)` and `ConsumerGroupGuardLost (..)` from
  `Shibuya.Adapter.Kiroku` next to the existing `kiroku-store` re-exports.
  Rationale: A service that enables the guard needs to recognize the two exceptions its source can
  end with; the module already re-exports the vocabulary a config needs so users do not import
  `kiroku-store` separately.
  Date: 2026-09-30

- Decision: The adapter release is a PVP major (proposed `0.6.0.0`) with its `kiroku-store` bound
  raised to the version plan 93 releases (proposed `^>=0.10.0.0`). If this plan is implemented
  before plan 93's release milestone has run, both releases go out as one confirmation-gated
  cohort and plan 93's bound-only adapter patch (`0.5.1.6`) is skipped; otherwise this plan
  releases the adapter on its own after plan 93's cohort.
  Rationale: Two new record-constructor fields are a breaking change under the PVP rules in
  `agents/skills/release/SKILL.md`; the raised bound stops an adapter with the field from being
  built against a store whose guard is still the probe. One cohort avoids two adapter releases in
  a day when the timing allows; two releases are still correct when it does not.
  Date: 2026-09-30

- Decision: No performance gate is re-run for the adapter change itself; the evidence is that the
  change is confined to `shibuya-kiroku-adapter` and forwards one boolean at construction.
  Rationale: ADR-5's gates protect `kiroku-store` statements and the append path, which this plan
  does not touch. The adapter overhead benchmark `kiroku-shibuya-overhead` builds its
  subscriptions with the guard off and is unchanged; `just perf-check` is still run once in
  milestone 2 as a cheap confirmation that the branch as a whole is green before release.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The adapter today

`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` is the whole public surface. It defines:

`KirokuAdapterConfig` with fields `subscriptionName`, `subscriptionTarget`, `batchSize`,
`bufferSize`, `queueCapacity`, `consumerGroup :: Maybe ConsumerGroup`,
`missingCheckpointPolicy`, `eventTypeFilter`, and `selector`, each with a Haddock;
`defaultKirokuAdapterConfig :: SubscriptionName -> SubscriptionTarget -> KirokuAdapterConfig`,
whose Haddock lists every default and tells users to prefer it over a record literal "so that any
field added to `KirokuAdapterConfig` later is inherited at its default automatically".

`kirokuAdapter :: (IOE :> es) => KirokuStore -> KirokuAdapterConfig -> Eff es (Adapter es
RecordedEvent)`, which pattern-matches every config field, builds the store's
`SubscriptionConfig` as `defaultSubscriptionConfig subName subTarget (\_ -> pure Continue)` with a
record update of the non-default fields (`Sub.batchSize`, `Sub.queueCapacity`,
`Sub.consumerGroup`, `Sub.missingCheckpointPolicy`, `Sub.eventTypeFilter`, `Sub.selector`), and
carries a comment saying the guard is "left `False` here". It then calls
`subscriptionAckStream store subConfig buf` from `kiroku-store`'s
`Kiroku.Store.Subscription.Stream`, lifts the stream into `Eff`, and returns an `Adapter` whose
`source` is that stream and whose `shutdown` cancels the subscription.

`KirokuConsumerGroupConfig` with the same fields plus `groupSize` and `memberConcurrency`;
`defaultConsumerGroupConfig :: SubscriptionName -> SubscriptionTarget -> Int32 ->
KirokuConsumerGroupConfig`; and `kirokuConsumerGroupProcessors`, whose local `mkMemberAdapter m`
builds a full `KirokuAdapterConfig` record literal per member (so a new field must be added there
or the package stops compiling) and hands the list to `kirokuConsumerGroupProcessorsWith`, which
validates the policy and acquires every member adapter under an ownership ledger.

The module re-exports `SubscriptionName (..)`, `SubscriptionTarget (..)`, `ConsumerGroup (..)`,
`EventTypeFilter (..)`, and `MissingCheckpointPolicy (..)` from `kiroku-store`. Its module
Haddock has a "Consumer-Group Example" section ending "Exactly one live process must own each
member index at a time."

How a worker failure reaches an adapter user: `subscriptionAckStream` (in
`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`) starts the subscription with `subscribe`
and a monitor thread that waits on the handle; when `wait` returns `Left e` for anything other
than cancellation, the bridge is closed as `BridgeCrashed e`, and the next read of the stream
rethrows `e`. So a startup refusal thrown inside the worker (the store's checkpoint refusal today,
the guard conflict after plan 93) ends the adapter's `source` with that exception before any
`Ingested` value is produced.

Tests are in `shibuya-kiroku-adapter/test/Main.hs`. The file's local `withTestStore` opens one
store on a fresh migrated database from `Kiroku.Test.Postgres.withMigratedTestDatabase`
(`kiroku-test-support`), and most cases run under `around withTestStore`. The
`describe "consumer groups"` block builds four member adapters with
`defaultKirokuAdapterConfig ... & #consumerGroup .~ Just (ConsumerGroup{member = m, size = 4})`,
runs them under `runApp`, waits on per-member counters, and asserts the union of delivered
positions is exactly `[1..40]`. The case "surfaces FailIfMissing without leaving a subscription
registered" shows how to observe a failing source: it wraps `Stream.fold Fold.drain sourceStream`
in `E.try` inside `runEff . runTracingNoop` and matches the exception with `E.fromException`.
`just test-matrix` runs every suite on PostgreSQL 17 and then 18 through the flake's
`postgresql17` and `postgresql18` shells.

Documentation: `docs/user/shibuya-adapter.md` has a `KirokuAdapterConfig` field table (one row per
field, columns Field, Default, Meaning) and a "Consumer Groups" section; the adapter's changelog is
`shibuya-kiroku-adapter/CHANGELOG.md`, most recent entry `0.5.1.5 — 2026-09-25`, and its cabal
file pins `kiroku-store ^>=0.9.0.1` in the library, the test suite, and the `lifecycle-live`
executable (an opt-in component enabled by the `+lifecycle-live` flag in `cabal.project`). The adapter's entry in the capability
catalog is `docs/capabilities/shibuya-adapter.md` (CAP-19), a profiled OKF bundle validated by
`just capabilities-validate` and logged with `okf log add`; milestone 2 updates it.

### What plan 93 delivers and this plan relies on

Plan 93 is checked in beside this file; read its Purpose and Interfaces sections. The parts this
plan depends on, restated so this file stands alone:

The store's `consumerGroupGuard :: Bool` on `SubscriptionConfigM`, when `True` and
`consumerGroup` is `Just`, makes the worker open one dedicated PostgreSQL connection outside the
pool, tagged `application_name = 'kiroku-member-guard'`, and take the session-level advisory lock
`pg_try_advisory_lock(hashtextextended('<name>:<member>', 0))` on it before the checkpoint is
read; the connection and lock are released when the worker exits by any route. A second worker
for the same key anywhere on the same database (any process, any store, any schema) fails at
startup with `ConsumerGroupGuardConflict { conflictName, conflictMember }`, delivered through the
worker thread and the handle's `wait`. A database error while establishing the guard fails
startup closed with a `Hasql.Pool.UsageError`. A heartbeat pings the dedicated connection every
thirty seconds; if the connection was lost, the worker re-takes the lock on a fresh connection
(emitting `KirokuEventSubscriptionGuardReacquired`) or, if another session now holds it, stops
with `ConsumerGroupGuardLost { lostName, lostMember }`. The guard is ignored when `consumerGroup`
is `Nothing`, costs one PostgreSQL connection per guarded member, requires a session-mode
connection (a transaction-pooling proxy cannot carry it, the same restriction as the listener),
and does not make delivery exactly-once. The key is stable and shared with applications that hold
it themselves; such an application must use the guard or its own lock, not both, because
PostgreSQL advisory locks are per session. Plan 93 releases these as `kiroku-store` `0.10.0.0`
(proposed; the release skill verifies).

### Improvement request and downstream evidence

IR-17 is the adapter request. Its evidence is kenshou's scenario
`shibuya/kiroku-adapter/concurrency/two-processes-one-member`, whose sealed runs on PostgreSQL 17
and 18 against adapter `0.5.1.2` and `0.5.1.3` each produced 80 effects for 40 events with no loss
and no checkpoint regression; the local finding is at project-relative
`docs/findings/16-shibuya-kiroku-same-member-duplicate-work.md` in
`mori://shinzui/keiro-runtime-kenshou` (artifact-level URI pending). Its acceptance: with the
option enabled, a second adapter process for one member fails startup with the store's conflict
error while the first is active, and a replacement drains after the first exits or is killed;
with it disabled, the at-least-once reproduction stays possible and the default configuration is
unchanged; both arms on PostgreSQL 17 and 18 with no loss or checkpoint regression. IR-17 is
`accepted` and names this plan; it becomes `completed` in milestone 3.

### Architecture decision records

ADR-2, [docs/adr/0002-static-hash-partitioned-consumer-groups.md](../adr/0002-static-hash-partitioned-consumer-groups.md),
records consumer groups as static hash-partitioned competing consumers with an optional advisory
lock guarding the one-live-process invariant, and lists the Shibuya adapter among the entry points
that expose the group descriptor. Plan 93 amends it and creates ADR-11 for the guard's mechanism.
This plan changes no durable decision: it forwards a store option through an adapter record, which
ADR-2 already anticipates. If ADR-11, once written, does not mention that the adapter forwards the
option, milestone 3's distillation pass adds one sentence to its consequences; no new ADR is
expected. ADR-9 (`kiroku-metrics` wire shapes) and ADR-5 (performance gates) are not affected.
Plan 30's Decision Log entry of 2026-05-20, which kept the field off the adapter, is superseded by
this plan once plan 93 lands; that plan file is historical and is not edited.


## Plan of Work

### Gate: plan 93's store guard is on the branch

Before editing, confirm the store surface this plan forwards exists:

```bash
grep -n "ConsumerGroupGuardLost" kiroku-store/src/Kiroku/Store/Subscription/Types.hs
test -f kiroku-store/src/Kiroku/Store/Subscription/MemberGuard.hs && echo "guard module present"
```

Both must print something. If not, implement plan 93 first; nothing in this plan can be verified
against the probe.

### Milestone 1: the field, its forwarding, and the tests

At the end of this milestone `defaultKirokuAdapterConfig` and `defaultConsumerGroupConfig` carry
`consumerGroupGuard = False`, setting it to `True` makes the store hold the lifetime guard for
that member, and the adapter suite proves both arms of IR-17's acceptance in one process using
two stores on one database (the same stand-in for two processes that plan 93 and IR-15 use).

In `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`:

Add to `KirokuAdapterConfig`, immediately after `consumerGroup`:

```haskell
    , consumerGroupGuard :: !Bool
    {- ^ When 'True' and 'consumerGroup' is @'Just' _@, the underlying Kiroku
    worker holds the store's member guard for its whole lifetime: a session-level
    PostgreSQL advisory lock keyed on @(subscriptionName, member)@, taken on a
    dedicated connection before the checkpoint is read and released when the
    worker exits by any route (see
    'Kiroku.Store.Subscription.Types.consumerGroupGuard'). A second adapter for
    the same @(subscriptionName, member)@ anywhere on the same database fails at
    startup: its 'source' terminates with
    'Kiroku.Store.Subscription.Types.ConsumerGroupGuardConflict' before any event
    reaches the handler. If this adapter's guard connection is lost while it runs
    and another process takes the member before the guard is re-taken, the
    'source' terminates with 'Kiroku.Store.Subscription.Types.ConsumerGroupGuardLost'.
    When this adapter shuts down or its worker exits, including by a crash, the
    lock is released with the connection, so a replacement needs no cleanup.

    The guard refuses duplicate ownership; it does not make delivery exactly-once
    (the at-least-once contract stands), does not assign members, and costs one
    PostgreSQL connection per guarded member outside the store pool. Ignored when
    'consumerGroup' is 'Nothing'. Default 'False'.
    -}
```

Set `consumerGroupGuard = False` in `defaultKirokuAdapterConfig` and add `consumerGroupGuard =
'False'` to its Haddock's list of defaults. In `kirokuAdapter`, bind the field in the pattern
(`consumerGroupGuard = guard`), add `Sub.consumerGroupGuard = guard` to the record update, and
replace the comment sentence that says the field is "left `False` here" with one saying the guard
is forwarded from the adapter config.

Add the same field to `KirokuConsumerGroupConfig` after `memberConcurrency`, with a Haddock
saying it is applied to every member, that a whole in-process group with the guard on holds one
guard connection per member, and pointing at the single-member field's Haddock for the semantics;
set it to `False` in `defaultConsumerGroupConfig` and list it in that Haddock; bind it in
`kirokuConsumerGroupProcessors`'s pattern and forward it in `mkMemberAdapter`'s record literal.

Extend the module's export list with `ConsumerGroupGuardConflict (..)` and
`ConsumerGroupGuardLost (..)` under the "Re-exports from kiroku-store" heading, and add both to
the `Kiroku.Store.Subscription.Types` import. In the module Haddock, after "Exactly one live
process must own each member index at a time.", add: "Set @consumerGroupGuard = True@ to have
Kiroku enforce this: the duplicate's 'source' fails with 'ConsumerGroupGuardConflict' instead of
double-processing."

Tests, in `shibuya-kiroku-adapter/test/Main.hs`. In the pure section near the existing
"consumer group policy" cases, add:

```haskell
    describe "consumer group guard defaults" $ do
        it "defaultKirokuAdapterConfig leaves the guard off" $
            (defaultKirokuAdapterConfig (SubscriptionName "d") AllStreams ^. #consumerGroupGuard)
                `shouldBe` False
        it "defaultConsumerGroupConfig leaves the guard off" $
            (defaultConsumerGroupConfig (SubscriptionName "d") AllStreams 2 ^. #consumerGroupGuard)
                `shouldBe` False
```

Add a top-level `describe "consumer group guard"` block that does not use `around withTestStore`
but opens its own database with `withMigratedTestDatabase $ \connStr -> ...` and two nested
`withStore (defaultConnectionSettings connStr)` scopes, `storeA` and `storeB`. A local helper
`memberConfig name guard = defaultKirokuAdapterConfig (SubscriptionName name) (Category
(CategoryName "guardcat")) & #consumerGroup .~ Just (ConsumerGroup{member = 0, size = 1}) &
#consumerGroupGuard .~ guard` keeps the cases short. Seed with the same shape the existing group
test uses: 20 streams `guardcat-1 .. guardcat-20`, 2 events each, global positions 1 to 40.

"guard on: a second adapter for the same member fails before its handler runs, and a replacement
drains after shutdown": build adapter A from `storeA` with the guard on; run it under `runApp`
with a handler that records `globalPosition` into an `IORef` and bumps a `TVar` counter,
returning `AckOk`; wait for the counter to reach 40 (reuse the file's `waitForTotal`). While A's
app is still running, build adapter B from `storeB` with the guard on and consume its `source`
directly:

```haskell
                result <-
                    E.try $
                        runEff . runTracingNoop $ do
                            adapterB <- kirokuAdapter storeB (memberConfig "guard-sub" True)
                            Stream.fold Fold.drain (source adapterB)
                case result of
                    Left exception
                        | Just (ConsumerGroupGuardConflict (SubscriptionName "guard-sub") 0) <- E.fromException exception ->
                            pure ()
                    other -> expectationFailure ("expected ConsumerGroupGuardConflict, got: " <> show other)
```

Assert A's counter is still 40 and A's app is still running (its handle's state query, as the
lifecycle tests in the file do). Stop A's app. Append 4 more events to two of the streams (positions
41 to 44). Build adapter C from `storeB` with the guard on, run it under `runApp` with a recording
handler, wait for its counter to reach 4, and assert its recorded positions are exactly
`[41, 42, 43, 44]` (A's checkpoint at 40 wins, so C does not replay). Stop C.

"guard on: an in-process group holds one guard connection per member": from `storeA`, call
`kirokuConsumerGroupProcessors` with `defaultConsumerGroupConfig (SubscriptionName "guard-group")
(Category (CategoryName "guardcat")) 3 & #consumerGroupGuard .~ True` and a handler returning
`AckOk`; run under `runApp`; wait until the three processors have acknowledged 40 in total; then
count `pg_stat_activity` rows with `application_name = 'kiroku-member-guard'` through `storeA`'s
pool with a small `preparable` statement (the store test helpers are in another package; write a
ten-line local helper) and assert 3; stop the app; poll up to five seconds until the count is 0.

"guard off: two adapters for the same member both deliver every event": adapters A (from `storeA`)
and B (from `storeB`) with the guard off, each under its own `runApp` with a recording handler;
wait until each counter is at least 40; assert each adapter's sorted set of distinct positions is
`[1..40]` (both processed the whole slice, which is IR-17's disabled arm and the behavior kenshou
reproduced); stop both apps. Because both write the same checkpoint row, a replay of a few
boundary events is possible; assert on distinct positions, not on counts.

Acceptance for milestone 1:

```bash
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter --test-show-details=direct --test-options='--match "consumer group guard"'
cabal test shibuya-kiroku-adapter --test-show-details=direct
```

all green, with the five new cases listed by name in the second command's output.

### Milestone 2: documentation, changelog, and the full matrix

At the end of this milestone a service author can learn the option from the user guide and the
Haddock alone, and the whole repository is green on both supported PostgreSQL majors.

In `docs/user/shibuya-adapter.md`, add a row to the `KirokuAdapterConfig` table after
`consumerGroup`:

```markdown
| `consumerGroupGuard :: Bool` | `False` | With a `consumerGroup`, hold Kiroku's lifetime member guard: a second adapter for the same `(subscriptionName, member)` anywhere on the database fails at startup (its `source` ends with `ConsumerGroupGuardConflict`), and the lock is released the moment this adapter's worker exits. Costs one extra PostgreSQL connection per member. See the consumer-groups guide. |
```

and in "Consumer Groups" add a short paragraph with the record-update form
`& #consumerGroupGuard .~ True`, what the second process observes, that a killed first process is
replaced without cleanup, that `ConsumerGroupGuardLost` can end a running adapter's source if its
guard connection was lost and a peer took over, and a link to `docs/user/consumer-groups.md` for
the store-level contract that plan 93 documents (key, connection budget, session-mode pooler
requirement). Extend the sentence listing the re-exported names with the two exceptions.

In `shibuya-kiroku-adapter/CHANGELOG.md`, add at the top:

```markdown
## Unreleased

### Breaking Changes

* `KirokuAdapterConfig` and `KirokuConsumerGroupConfig` gain `consumerGroupGuard :: Bool`.
  Record literals must add the field; `defaultKirokuAdapterConfig` and
  `defaultConsumerGroupConfig` inherit `False`, so configurations built from them are
  unchanged.
* Requires `kiroku-store ^>=0.10`, whose `consumerGroupGuard` holds a session-level advisory
  lock on a dedicated connection for the worker's lifetime.

### New Features

* Opt-in `consumerGroupGuard` (IR-17). With a consumer group and the guard on, a second adapter
  for the same `(subscriptionName, member)` fails at startup with
  `ConsumerGroupGuardConflict` on its `source` before any event reaches the handler, and a
  replacement starts as soon as the holder exits. `ConsumerGroupGuardConflict` and
  `ConsumerGroupGuardLost` are re-exported from `Shibuya.Adapter.Kiroku`.
```

In `docs/capabilities/shibuya-adapter.md` (CAP-19): extend the frontmatter `description` so it ends
"..., and forwarding Kiroku's opt-in lifetime member guard"; add one sentence to the body's first
paragraph saying that `consumerGroupGuard` forwards the store's lifetime member guard so a
duplicate member's `source` fails at startup with `ConsumerGroupGuardConflict`; extend the test
evidence's `proves` text with "duplicate-member refusal and replacement through the lifetime guard
across two stores"; bump `timestamp` if the profile carries one (compare with CAP-13's frontmatter
after plan 93 touches it). Then:

```bash
okf log add docs/capabilities --kind Update -m "CAP-19 now records the opt-in consumerGroupGuard forwarding and its two-store refusal evidence (plan 92)."
just capabilities-validate
```

Then run, from the repository root:

```bash
cabal build all
just perf-check
just test-matrix
```

`cabal build all` covers the `lifecycle-live` executable (the flag is on in `cabal.project`) and
every sister package; none constructs the adapter records by literal, so no other source changes.
`just perf-check` is the cheap whole-branch confirmation described in the Decision Log.
`just test-matrix` must print `== PostgreSQL 17.x ==` and `== PostgreSQL 18.x ==` each followed by
every suite passing. Record the matrix result (both version lines and the adapter suite's
example count) in Surprises & Discoveries.

### Milestone 3: release and complete IR-17

Only after the user explicitly confirms in the implementation session. Follow
`agents/skills/release/SKILL.md` for `shibuya-kiroku-adapter` with bump level `major`, after
re-checking Hackage and the upstream tags for the authoritative current versions of both the
adapter and `kiroku-store`. Set the adapter's `kiroku-store` bound (library, test suite, and
`lifecycle-live`) to the released store version that carries plan 93's guard, date the
`## Unreleased` section, and coordinate with plan 93 as its Decision Log entry says: one cohort if
both are unreleased, otherwise the adapter alone. After the Hackage index refreshes, verify from a
clean temporary Cabal project outside the working tree that the released adapter resolves and that
a small program building `defaultKirokuAdapterConfig ... & #consumerGroupGuard .~ True` compiles.
Record the Hackage URL, the tag and commit, and the clean-consumer output here.

Then set IR-17 to `completed`: frontmatter `status`, bumped `timestamp`, and a completion
paragraph naming the released adapter and store versions and the two-store tests as in-repository
evidence; add a `docs/improvement-requests/log.md` entry; validate the bundle. In the completion
paragraph, note for `mori://shinzui/keiro-runtime-kenshou` that its scenario
`shibuya/kiroku-adapter/concurrency/two-processes-one-member` can be rerun with the option
enabled against the released adapter to observe the second process failing startup, and with it
disabled to confirm the existing at-least-once run. Finish with the ADR distillation pass (expected
result: at most one sentence in ADR-11's consequences) and the Outcomes & Retrospective section.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`
in the development shell. The test suites start their own ephemeral PostgreSQL.

Gate:

```bash
grep -n "ConsumerGroupGuardLost" kiroku-store/src/Kiroku/Store/Subscription/Types.hs
test -f kiroku-store/src/Kiroku/Store/Subscription/MemberGuard.hs && echo "guard module present"
```

Milestone 1, after the edits:

```bash
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter --test-show-details=direct --test-options='--match "consumer group guard"'
```

Expected tail of a green run:

```text
consumer group guard defaults
  defaultKirokuAdapterConfig leaves the guard off [✔]
  defaultConsumerGroupConfig leaves the guard off [✔]
consumer group guard
  guard on: a second adapter for the same member fails before its handler runs, and a replacement drains after shutdown [✔]
  guard on: an in-process group holds one guard connection per member [✔]
  guard off: two adapters for the same member both deliver every event [✔]

Finished in 9.8 seconds
5 examples, 0 failures
```

Commit:

```text
feat(adapter): expose the lifetime member guard on the adapter configs

Add consumerGroupGuard (default False) to KirokuAdapterConfig and
KirokuConsumerGroupConfig and forward it to the store subscription, so a
second adapter for one (subscriptionName, member) fails at startup with
ConsumerGroupGuardConflict instead of double-processing. Re-export the
two guard exceptions.

ExecPlan: docs/plans/92-expose-the-lifetime-member-guard-in-the-shibuya-adapter.md
Intention: intention_01m3t40nqze459mqewtt1tz53e
```

Milestone 2, after the document, capability, and changelog edits:

```bash
just capabilities-validate
cabal build all
just perf-check
just test-matrix
```

Commit as `docs(adapter): document the opt-in lifetime member guard` with the same trailers.

Milestone 3, only after explicit confirmation: the release skill's own sequence, then the IR-17
update, then:

```bash
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce
```

which prints only the pre-existing "missing profile-recommended field: reviews" lines on a
clean tree (its exit code 1 is recommendation noise; judge by the absence of any other line).
Commit as `docs(improvement-requests): complete IR-17` with the trailers.


## Validation and Acceptance

IR-17's acceptance, as behavior:

With `consumerGroupGuard = True`, two adapters for member 0 of one subscription from two stores on
one database: the second's `source` ends with `ConsumerGroupGuardConflict` and its handler never
runs while the first's app is running; after the first app stops, a third adapter for the same
member starts and acknowledges exactly the events appended after the first's checkpoint. Proven by
the milestone 1 case "guard on: a second adapter ..." on PostgreSQL 17 and 18 through `just
test-matrix`. The "killed" variant of the holder (its process dies rather than shutting down) is
proven at the store level by plan 93's terminated-holder tests; the adapter adds no code between
the store's release of the lock and the replacement's acquisition.

With the field at its default, two adapters for the same member both deliver every event, and
`defaultKirokuAdapterConfig` and `defaultConsumerGroupConfig` set the field to `False`. Proven by
the two default cases and the "guard off" case.

An in-process group built by `kirokuConsumerGroupProcessors` with the guard on holds exactly one
`kiroku-member-guard` backend per member while running and none after `stopApp`. Proven by the
group case.

Performance: the diff touches only `shibuya-kiroku-adapter`; `just perf-check` passes on the
branch; the adapter overhead benchmark is unchanged by construction because it sets the guard off.

Documentation: `docs/user/shibuya-adapter.md` and the module Haddock describe the option, the two
exceptions, the connection cost, and the fact that delivery stays at-least-once; the changelog's `## Unreleased` section names the breaking field additions and the store bound; CAP-19
records the forwarding and `just capabilities-validate` exits 0.


## Idempotence and Recovery

Every edit is an ordinary source or document change that can be re-applied from this plan. The
tests create their own ephemeral databases, so an interrupted run leaves nothing behind. If the
two-store case proves timing-sensitive on a slow host (for example adapter B is built before
adapter A's worker has taken the lock), wait for A's counter to reach 40 before building B, as the
plan already says, and if that is not enough, wait additionally for a `kiroku-member-guard`
backend to appear through the local `pg_stat_activity` helper; record the change in the Decision
Log.

If plan 93 changes an interface this plan names (the exception names or the store version),
update the Context section and the changelog text here before implementing; do not implement
against an assumed interface.

Rollback for a service that enables the guard and wants the old behavior is
`consumerGroupGuard = False`, the default. Nothing in the database changes. Version and bound
edits happen only in milestone 3 after confirmation; the release skill's dependency order keeps a
partially published cohort consistent, and an interrupted release resumes with the next package.


## Interfaces and Dependencies

The adapter adds no dependency. It relies on `kiroku-store` at the version plan 93 releases,
which exports from `Kiroku.Store.Subscription.Types`: `consumerGroupGuard` on
`SubscriptionConfigM`, `ConsumerGroupGuardConflict (..)`, and `ConsumerGroupGuardLost (..)`, and
holds the guard as described in the Context section.

At the end of milestone 1 these must exist in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`:

```haskell
data KirokuAdapterConfig = KirokuAdapterConfig
    { subscriptionName :: !SubscriptionName
    , subscriptionTarget :: !SubscriptionTarget
    , batchSize :: !Int32
    , bufferSize :: !Natural
    , queueCapacity :: !Natural
    , consumerGroup :: !(Maybe ConsumerGroup)
    , consumerGroupGuard :: !Bool
    , missingCheckpointPolicy :: !MissingCheckpointPolicy
    , eventTypeFilter :: !EventTypeFilter
    , selector :: !(Maybe (RecordedEvent -> Bool))
    }

data KirokuConsumerGroupConfig = KirokuConsumerGroupConfig
    { subscriptionName :: !SubscriptionName
    , subscriptionTarget :: !SubscriptionTarget
    , groupSize :: !Int32
    , batchSize :: !Int32
    , bufferSize :: !Natural
    , queueCapacity :: !Natural
    , memberConcurrency :: !Concurrency
    , consumerGroupGuard :: !Bool
    , missingCheckpointPolicy :: !MissingCheckpointPolicy
    , eventTypeFilter :: !EventTypeFilter
    , selector :: !(Maybe (RecordedEvent -> Bool))
    }
```

with `defaultKirokuAdapterConfig` and `defaultConsumerGroupConfig` setting `consumerGroupGuard =
False`, `kirokuAdapter` forwarding it as `Sub.consumerGroupGuard`, `kirokuConsumerGroupProcessors`
forwarding it to every member, and the module exporting `ConsumerGroupGuardConflict (..)` and
`ConsumerGroupGuardLost (..)` alongside the existing re-exports. The signatures of `kirokuAdapter`,
`kirokuConsumerGroupProcessors`, and `kirokuConsumerGroupProcessorsWith` are unchanged.

Services: PostgreSQL 17 or 18 through `ephemeral-pg` for the tests, as the matrix already
requires.


## Revision Notes

- 2026-09-30: Scope narrowed to IR-17. The first version of this plan carried the IR-15 store work
  as its milestones 1 and 2; plan 93, authored concurrently as the dedicated IR-15 plan, owns that
  work with its own design, and this plan now depends on it and forwards its interfaces
  (`ConsumerGroupGuardConflict`, `ConsumerGroupGuardLost`, `kiroku-store` `0.10.0.0`). The file was
  renamed from `92-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime-and-expose-it-in-the-shibuya-adapter.md`;
  id, intention, and provenance are unchanged. IR-15's status paragraph now names plan 93 and
  IR-17's names this plan. Reason: one plan per request, and no forked store design.
