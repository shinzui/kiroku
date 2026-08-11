---
id: 70
slug: make-subscription-checkpoint-initialization-and-reset-semantics-explicit
title: "Make subscription checkpoint initialization and reset semantics explicit"
kind: exec-plan
created_at: 2026-08-09T17:50:15Z
intention: intention_01kzrntjkgehjtahtfxzyjbap2
---

# Make subscription checkpoint initialization and reset semantics explicit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, every Kiroku subscription has a deliberate answer to one dangerous startup
question: what should happen when its `(subscription name, consumer-group member)` checkpoint does
not exist? A caller can choose to begin at position zero, atomically seed the current store head,
or fail before the handler runs. A future-only side-effect worker can therefore join a populated
store without replaying old effects, while a replayable projection retains from-beginning behavior
explicitly.

Kiroku also exposes the supported transactional rewind operation needed by a coordinating library.
Keiro can reset all persisted members of declared subscription names inside the same transaction as
its projection fence and target preparation, receive an exact missing-name report, and stop writing
Kiroku's `subscriptions` table through private SQL. Tests demonstrate the three startup policies,
concurrent initialization, member isolation, transactional rollback, and the continued monotonicity
of normal checkpoint saves.

This plan implements
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-3`. It prepares the next breaking
`kiroku-store` source cohort but does not publish it. Publication remains deferred until the
downstream Keiro plans coordinated by
`mori://shinzui/keiro/masterplans/33-make-subscription-checkpoint-lifecycle-explicit-before-the-next-release`
are complete.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-11T15:15:42Z) Milestone 1: added the closed policy/result vocabulary, atomic
  initialization SQL, public `Store` operation, and eight passing focused database/mock examples.
- [x] (2026-08-11T15:26:11Z) Milestone 2: routed every worker entry point through policy resolution
  before delivery and added lifecycle telemetry plus consumer-group, adapter, and race coverage.
- [x] (2026-08-11T15:32:40Z) Milestone 3: added the explicit transactional reset API, exact
  affected/missing report, and passing rollback/monotonicity coverage.
- [x] (2026-08-11T15:41:42Z) Milestone 4: updated adapters, Haddocks, guides, capability evidence,
  changelogs, ADR/IR records, and passed full-repository validation without publishing packages.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The released `kiroku-store` 0.4.0.0 inventory intentionally exposes no mutation. Its completed
  request says reset, rewind, deletion, and synthetic row creation need separate safety semantics;
  this plan supplies that separate contract rather than widening the inventory silently.
- `loadCheckpoint` currently maps only `Right Nothing` to `GlobalPosition 0`; database failures
  already fail the worker. The new semantic failure can reuse the terminal startup path but must
  remain distinguishable from a pool error.
- Ordinary checkpoint saving uses `GREATEST(last_seen, excluded.last_seen)`. A rewind cannot reuse
  that statement and must be an explicitly named transaction operation.
- Consumer-group topology is not authoritative in each row. The reset API can reset every existing
  member for a name and report a missing name, but must not manufacture members from a group size.
- PostgreSQL's `ON CONFLICT DO NOTHING` can wait for a concurrent winner whose row is not visible to
  the original statement snapshot. The initialization session therefore performs the prescribed
  insert-plus-final-read statement first and, only when an initializing policy loses that race,
  performs one fresh-snapshot read. Evidence: twenty concurrent initializers converged on one row
  and exactly one `InitializedCheckpoint` in the focused suite.
- Plain IO, bracketed IO, the higher-order Effectful interpreter, and the Streamly bridge all
  preserve `SubscriptionConfigM` by record update or direct forwarding; Shibuya is the only layer
  that owns a separate configuration record and therefore needed an explicit policy field. The
  affected-package run passed 260 store, 30 adapter, 20 metrics, and 17 OTel examples.
- The repository has no root `CHANGELOG.md`; release notes are owned by the individual package
  changelogs. The final milestone updated every package whose source contract or exhaustive event
  matching changed: `kiroku-store`, `shibuya-kiroku-adapter`, `kiroku-metrics`, and `kiroku-otel`.
- The observability guide still described the pre-0.3 checkpoint-load fallback to position zero,
  and the architecture guide described every checkpoint mutation as monotonic. The documentation
  audit corrected both stale claims and now separates failed initialization, ordinary monotonic
  save, and explicit reset.


## Decision Log

Record every decision made while working on the plan.

- Decision: Define exactly three policies named `FromBeginning`, `FromCurrentHead`, and
  `FailIfMissing`, with `FromBeginning` as the compatibility default.
  Rationale: These represent the three operational intentions exposed by the migration evidence in
  `mori://shinzui/mori/plans/215-restore-the-seven-registration-read-models-dropped-by-the-functional-rewrite`.
  A Boolean cannot express refusal, and an open callback would not be inspectable or portable
  through the `Store` effect.
  Date: 2026-08-09

- Decision: Materialize a missing `FromBeginning` checkpoint at position zero instead of retaining
  absence until the first batch completes.
  Rationale: All policies then resolve through one durable atomic boundary. Inventory can
  distinguish an initialized subscription from one that never started, and concurrent starters
  converge on one row.
  Date: 2026-08-09

- Decision: Existing rows always win, regardless of the configured policy.
  Rationale: A missing-checkpoint policy is not an implicit rewind. Changing configuration must
  not move durable progress; operators use the separate reset API.
  Date: 2026-08-09

- Decision: Expose reset as a `Hasql.Transaction.Transaction` combinator that reports exact reset
  member keys and requested names with no persisted rows.
  Rationale: Keiro must compose reset with its fence and target preparation. The report lets Keiro
  condemn the surrounding transaction while Kiroku retains schema and SQL ownership.
  Date: 2026-08-09

- Decision: Do not release or change dependent package bounds in this plan.
  Rationale: The user is accumulating the remaining breaking improvements before one coordinated
  release. Implementation records the next-major PVP requirement and validates repository sources
  together; the later release workflow chooses versions and publishes them.
  Date: 2026-08-09

- Decision: Keep the atomic insert and result classification in one package-internal Hasql session,
  with a fresh-snapshot read only for the concurrent `DO NOTHING` loser case.
  Rationale: Both the `Store` interpreter and the worker need identical semantics. PostgreSQL can
  hide a just-committed conflict winner from the first statement snapshot, while a second statement
  on the same session observes it without changing the winning checkpoint.
  Date: 2026-08-11

- Decision: Emit `KirokuEventSubscriptionCheckpointResolved` for successful resume/seed outcomes
  and `KirokuEventSubscriptionCheckpointMissing` for semantic refusal, both before `Started`.
  Rationale: The initialization result already distinguishes existing, zero-seeded, and head-seeded
  outcomes without adding another parallel vocabulary. A refused worker never truthfully starts;
  it emits the typed refusal and then follows the existing terminal crash path.
  Date: 2026-08-11

- Decision: Treat the non-empty reset input as a set of subscription names and report each
  requested name or persisted member exactly once in deterministic key order.
  Rationale: A duplicate declaration must not produce duplicate operational evidence, while the
  underlying name still expands to every persisted consumer-group member. Deduplication inside the
  owned SQL statement keeps the mutation and its report consistent in one snapshot.
  Date: 2026-08-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Milestone 1 established the public lifecycle vocabulary and effect boundary without involving a
worker. `FromBeginning`, `FromCurrentHead`, and `FailIfMissing` now have durable database evidence,
existing rows win for every policy, members remain isolated, concurrent starters converge, and a
Hasql-free interpreter can model the closed operation. `cabal build kiroku-store` succeeds and the
focused Hspec selection reports 8 examples with 0 failures.

Milestone 2 made that boundary authoritative for real workers. Missing refusal happens before the
handler and before `Started`; successful startup emits its exact resolution. The append-race test
proved a clean `FromCurrentHead` cut by observing that delivered positions were exactly those
greater than the durable seed. Non-group and two-member group workers, plain and bracketed IO,
Effectful, Streamly, and Shibuya paths all passed. Metrics consumes the resolution position and the
OTel translator remains exhaustive while starting its episode span at the subsequent `Started`.

Milestone 3 established an owned mutation seam without exposing a raw statement. The public
`resetSubscriptionCheckpointsTx` combinator directly assigns the requested position to every
persisted member, returns sorted affected keys and sorted absent names, and creates no topology.
Four focused PostgreSQL examples proved exact commit evidence, application-write plus reset
rollback under `Tx.condemn`, a real rewind, and the continued `GREATEST(...)` monotonicity of normal
saves. The complete `kiroku-store` run reports 264 examples with 0 failures.

Milestone 4 made the contract adoptable and durable. The native and Shibuya guides now contain an
explicit replayable `FromBeginning` projection and a future-only `FromCurrentHead` worker, plus the
transaction reset/report boundary. ADR-4 records existing-row precedence, atomic head seeding, and
the monotonic-save/reset separation; CAP-20 carries source and test evidence. IR-3 is `implemented`
but deliberately not `completed`, and no version, tag, upload, or GitHub release was created.

Final acceptance passed `nix fmt`, `cabal haddock kiroku-store`, `cabal build all`, all seven Cabal
test suites (373 examples total, 0 failures), `nix flake check`, strict profile/log validation for
the ADR and improvement-request bundles, profile/log-enforced validation for the capability bundle,
regenerated OKF indexes, and `git diff --check`. The capability catalog's strict mode still reports
its pre-existing recommended-review backlog; CAP-20 itself includes review provenance.


## Context and Orientation

Kiroku is a PostgreSQL event store. A subscription is a background worker that reads recorded
events in global-position order, calls an application handler, and durably records how far that
handler has acknowledged. The durable key is `(subscription_name, consumer_group_member)` in the
Kiroku-owned `subscriptions` table. A non-group worker uses member zero; a static consumer group
uses one independent row per configured member.

`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` owns `SubscriptionConfigM`. The configuration
now contains the closed `MissingCheckpointPolicy` field alongside name, target, handler,
batch/backpressure settings, consumer-group membership, retry policy, and filters.
`defaultSubscriptionConfig` supplies `FromBeginning` as the compatibility default and remains the
construction path used by Kiroku and the Shibuya adapter.

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` owns concrete worker startup.
`loadCheckpoint` now invokes the shared package-internal initialization session with the exact
member key and configured policy. A successful resolution is emitted before `Started`; a
`FailIfMissing` refusal is emitted and thrown before the handler runs. `saveCheckpoint` later calls
the member-aware monotonic upsert. The worker enters `CatchingUp` only after initialization
succeeds.

`kiroku-store/src/Kiroku/Store/Effect.hs` defines the exported, mockable `Store` GADT and its pool
and resource interpreters. `Kiroku.Store.Subscription.subscriptionCheckpointInventory` is the
released read-only checkpoint API. `InitializeSubscriptionCheckpoint` now carries the closed policy
through the effect, so an in-memory consumer can model it without Hasql.
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs` owns the package-internal Hasql
session used by that interpreter; Milestone 2 routes worker startup through the same session.

`kiroku-store/src/Kiroku/Store/Transaction.hs` is intentionally the public composition seam for
callers such as Keiro that need Kiroku-owned SQL inside a larger `Tx.Transaction`. Put the reset
combinator in a public checkpoint module and re-export it from `Kiroku.Store`; do not export a raw
`Statement`.

`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint.hs` is now that public checkpoint mutation
module. It exposes the typed reset report and transaction combinator, while the SQL statement
remains package-internal in `Checkpoint/SQL.hs`.

The primary tests live in `kiroku-store/test/Main.hs` and focused modules under
`kiroku-store/test/Test/Subscription*.hs`. Add focused modules for initialization and reset rather
than making the inventory tests own mutation. The Shibuya integration lives in
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` and already builds from
`defaultSubscriptionConfig`, so it inherits the compatibility default and can expose an override
without reconstructing the record.

[ADR 2](../adr/0002-static-hash-partitioned-consumer-groups.md) fixes structured per-member
checkpoint identity and forbids invented topology. [ADR 3](../adr/0003-dedicated-kiroku-schema.md)
assigns the `subscriptions` table and statements to Kiroku. Implementation must create or amend an
ADR recording existing-row precedence, atomic head seeding, and the separation between monotonic
save and explicit rewind. The cross-repository decisions
`mori://shinzui/mori/okf/adrs/concepts/ADR-20` and
`mori://shinzui/mori/okf/adrs/concepts/ADR-21` explain why ownership and real write-path evidence
matter, but Kiroku does not adopt Mori's projection model.


## Plan of Work

Milestone 1 establishes the public semantics independently of worker orchestration. Add
`MissingCheckpointPolicy`, `SubscriptionCheckpointKey`, `CheckpointInitialization`, and the typed
missing failure to `Kiroku.Store.Subscription.Types`. Add the policy field to
`SubscriptionConfigM` and default it to `FromBeginning`. Create package-internal SQL which resolves
one `(name, member)` atomically: an existing row is returned unchanged; `FromBeginning` inserts
zero; `FromCurrentHead` inserts the current `$all` position selected in the same statement; and
`FailIfMissing` inserts nothing. Use `ON CONFLICT DO NOTHING` plus a final read so concurrent
initializers converge on the winning row. Add an `InitializeSubscriptionCheckpoint` constructor to
the `Store` GADT, implement both concrete interpreters, and expose a smart function from
`Kiroku.Store.Subscription`. Focused database tests and a Hasql-free mock prove the contract
without starting a worker.

Milestone 2 makes worker startup consume the new boundary. Replace `loadCheckpoint`'s absent-to-zero
branch with the shared initializer before the worker emits its started event or enters
`CatchingUp`. Extend `KirokuEvent` only as needed to report whether startup resumed, seeded zero,
seeded the head, or refused a missing checkpoint; never log payloads. Pin the race in a PostgreSQL
test which appends while `FromCurrentHead` starts and proves every event is either at or before the
durable seed or delivered afterward. Cover non-group and multi-member behavior, plus the direct,
bracketed, higher-order effect, Streamly, and Shibuya paths to the degree each owns startup.

Milestone 3 adds the explicitly destructive composition API. Define
`SubscriptionCheckpointResetReport` and `resetSubscriptionCheckpointsTx` in a public checkpoint
module. Accept a `NonEmpty SubscriptionName` and target `GlobalPosition`, update every existing
member for those names without `GREATEST`, and return sorted affected keys plus sorted names with no
rows. One statement is preferred; a bounded fixed statement sequence in one transaction is
acceptable if it retains deterministic evidence. Tests compose the combinator with a sentinel
application-table update through `runTransaction`, prove commit and `Tx.condemn` rollback, and then
prove ordinary save cannot move the reset checkpoint backward.

Milestone 4 completes the source contract without publishing it. Update
`docs/user/subscriptions.md`, `docs/architecture/subscriptions.md`, public Haddocks, capability
evidence, and worked examples. Update `CHANGELOG.md` and package changelogs under an unreleased
heading, noting that the config record and `Store` GADT require a breaking package cycle. Add or
amend the checkpoint-lifecycle ADR, update IR-3 to `implemented` only after acceptance passes,
regenerate OKF indexes/logs, and run the entire repository suite. Do not tag, upload, create a
GitHub release, or mark the request `completed`; those wait for the coordinated downstream release.


## Concrete Steps

Work from the Kiroku repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

Before editing, confirm the released baseline and locate exhaustive consumers of the records that
will change:

```bash
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
git ls-remote --tags origin 'kiroku-store-v*'
rg -n 'SubscriptionConfig(M)?[ ({]|GetSubscriptionCheckpointInventory|RunTransaction' \
  --glob '*.hs' .
```

The registry and upstream tag should still identify 0.4.0.0 before the later release chooses a
breaking version. During milestones, run:

```bash
cabal build kiroku-store shibuya-kiroku-adapter
cabal test kiroku-store:kiroku-store-test
cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test
cabal haddock kiroku-store
```

Validate the improvement request and any ADR change with their declared profiles, maintain their
nearest logs, and regenerate generated indexes:

```bash
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
okf index docs/improvement-requests --write
okf index docs/adr --write
```

At final source acceptance, run:

```bash
nix fmt
cabal build all
cabal test all
nix flake check
git diff --check
```

Expected evidence is zero test failures, both strict bundles validating, and no release tag or
Hackage upload created by this plan.


## Validation and Acceptance

The focused initialization suite starts with an empty migrated store and proves that
`FromBeginning` creates an inventory row at zero, `FromCurrentHead` creates a row at the exact
pre-start head, and `FailIfMissing` returns the typed failure with no row and no handler call. It
then pre-creates a row and shows that all policies resume the same existing position without moving
it.

A concurrency example holds or races an append around head initialization and shows a clean cut:
after catch-up, delivered positions are exactly those greater than the durably seeded checkpoint.
Run the same cases for member zero and at least two consumer-group members, proving isolation.

The reset suite creates several member rows under two names, resets both inside a transaction, and
observes exact sorted keys. It includes one absent name in `missingSubscriptionNames`. Repeat with
an application sentinel write followed by `Tx.condemn`; neither sentinel nor rewind may remain.
Finally invoke ordinary save with a lower position and show that it cannot move the checkpoint
backward.

Adapter and higher-order tests compile without exhaustive record literals. At least one example
sets `FromCurrentHead` for a future-only handler and one projection example sets `FromBeginning`.
Haddocks state that policy applies only when the exact member key is absent and never rewinds an
existing row.


## Idempotence and Recovery

Initialization is safe to retry: the first successful insert establishes the checkpoint and every
later call returns it as existing. Do not make tests delete rows between retries; that would hide
the production contract.

Reset is intentionally not monotonic, but it runs inside the caller's transaction. If a later
statement or report check fails, call `Tx.condemn` and retry the whole transaction from the
original requested position. Never repair a partial test by editing `subscriptions` manually.

If a milestone must be backed out, use an ordinary revert while keeping IR-3 and this plan as the
record of the unresolved request. Do not move public tags or publish an intermediate package.


## Interfaces and Dependencies

`kiroku-store` owns the interface. Exact type placement may be refined, but equivalent shapes and
semantics are required:

```haskell
data MissingCheckpointPolicy
    = FromBeginning
    | FromCurrentHead
    | FailIfMissing

data SubscriptionCheckpointKey = SubscriptionCheckpointKey
    { subscriptionName :: SubscriptionName
    , consumerGroupMember :: Int32
    }

data CheckpointInitialization
    = ExistingCheckpoint SubscriptionCheckpointKey GlobalPosition
    | InitializedCheckpoint
        MissingCheckpointPolicy
        SubscriptionCheckpointKey
        GlobalPosition

data SubscriptionCheckpointMissing = SubscriptionCheckpointMissing
    { checkpointKey :: SubscriptionCheckpointKey
    }

initializeSubscriptionCheckpoint ::
    (HasCallStack, Store :> es) =>
    SubscriptionName ->
    Int32 ->
    MissingCheckpointPolicy ->
    Eff es (Either SubscriptionCheckpointMissing CheckpointInitialization)

data SubscriptionCheckpointResetReport = SubscriptionCheckpointResetReport
    { resetCheckpointKeys :: Vector SubscriptionCheckpointKey
    , missingSubscriptionNames :: Vector SubscriptionName
    }

resetSubscriptionCheckpointsTx ::
    NonEmpty SubscriptionName ->
    GlobalPosition ->
    Tx.Transaction SubscriptionCheckpointResetReport
```

`SubscriptionConfigM` gains `missingCheckpointPolicy :: MissingCheckpointPolicy`, and
`defaultSubscriptionConfig` sets `FromBeginning`. `Kiroku.Store.Subscription` and `Kiroku.Store`
re-export public vocabulary; raw statements remain package-internal.

The primary downstream consumer is
`mori://shinzui/keiro/plans/215-adopt-explicit-checkpoint-lifecycle-semantics-in-the-projection-catalog`.
Kiroku must not import Keiro catalog types. Hackage 0.4.0.0 and upstream tag
`kiroku-store-v0.4.0.0` are the released baseline; version selection and dependent bounds wait for
the later release workflow.


Revision note (2026-08-11): Recorded the active intention and Milestone 1 implementation evidence,
including the PostgreSQL conflict-snapshot retry decision discovered while implementing the atomic
initializer.

Revision note (2026-08-11): Recorded Milestone 2 worker routing, lifecycle telemetry, entry-point
coverage, and the clean-cut concurrency evidence from the complete affected-package test run.

Revision note (2026-08-11): Recorded Milestone 3's set-oriented reset contract, transaction
rollback evidence, explicit rewind behavior, and the complete store-suite result.

Revision note (2026-08-11): Recorded Milestone 4 documentation, ADR-4/CAP-20/IR-3 state, the absent
root changelog discovery, and the complete repository acceptance evidence.
