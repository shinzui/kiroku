---
id: 103
slug: close-the-subscription-worker-observability-and-decode-filter-gaps-from-rev-2
title: "Close the subscription worker observability and decode-filter gaps from REV-2"
kind: exec-plan
created_at: 2026-10-21T14:06:08Z
intention: "intention_01m5fcgrhve7mam08dd9f581h4"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T14:06:08Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T19:33:26Z
      verdict: "changes-requested"
      note: "Require name-locked initializer adoption, non-vacuous initializer and recovered-decode tests, explicit observer accounting, and accurate reset-lock documentation."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T19:43:51Z
      mode: "update"
      note: "Apply all five review findings: atomic topology inheritance, meaningful regression fixtures, single-stop observer accounting, and precise lock documentation; align validation and shell prerequisites."
---

# Close the subscription worker observability and decode-filter gaps from REV-2

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Review REV-2 (`docs/reviews/kiroku-0-10-subscription-hardening-cohort.md`) accepted
the subscription hardening shipped in kiroku-store 0.10.0.0 as correct but recorded
five gaps an operator or integrator would trip over. Two are observability: a worker
refused for an invalid `handlerStallWarnAfter` emits no `Stopped` event, and a target
binding mismatch has no dedicated observer event, unlike a size mismatch. One is a
consistency gap in decode handling: the first delivery pass applies the event-type
filter to the raw event for undecodable events but the retry pass applies it to the
decoded event, so a retry can change an event's disposition. One is a footgun: the
low-level `initializeSubscriptionCheckpoint` effect still writes size-1 `unbound` rows,
so calling it for a missing member of a bound group breaks that member's next start.
Existing member rows are preserved. The last gap is documentation: the topology
lock protects concurrent starters but not a running
member, whose next save overwrites a resize or rebind made while it ran.

After this plan an operator sees a `Stopped` event for every startup refusal and a
typed event for a target mismatch, the filter decision for an event is the same on
every attempt, the low-level initializer adopts an existing group's topology instead of
corrupting it, and the guides say plainly what the lock does not protect.


## Progress

- [ ] Milestone 1: invalid stall intervals and target mismatches emit exactly one `Stopped` event with `StopWorkerCrashed` before `wait` surfaces the refusal; target mismatches also emit their dedicated event; observer tests prove one crash count and one terminal span per refusal.
- [ ] Milestone 2: retry decoding retains the first filter decision, including delivery when decoding recovers to an excluded type; regression tests pin that transition, and `docs/user/subscriptions.md` and ADR-12 state the raw-versus-decoded filter rule and the `Stop` disposition's checkpoint effect.
- [ ] Milestone 3: the low-level initializer adopts uniform sibling topology under the per-name transaction lock; tests prove a previously absent member inherits size and binding, can start, and observes a concurrent rebind after waiting for the lock; both guides accurately distinguish startup/resize/rebind locking from reset and running-worker behavior.


## Surprises & Discoveries

The 2026-10-25 review found that resize materializes every member in the new
range, while initialization uses `ON CONFLICT DO NOTHING`. A test that initializes
an existing resized member would pass before this fix. The fixture must leave a
member absent. Likewise, retries that remain undecodable do not exercise the faulty
successful-decode filter branch; the regression must recover to an excluded type.

The same review verified that the metrics collector only touches subscription
state for a size-mismatch event and the OpenTelemetry observer ignores it. Their
terminal accounting comes from `Stopped`. It also verified that reset does not
acquire the per-name advisory lock, unlike worker startup, resize and rebind.


## Decision Log

- Decision: Add `KirokuEventSubscriptionTargetMismatch` as a new `KirokuEvent`
  constructor rather than reusing an existing one.
  Rationale: Operators can distinguish a target refusal by constructor without
  inspecting the exception inside `StopWorkerCrashed`. Existing metrics and tracing
  already report the subsequent crash; the dedicated event must not count it twice.
  The constructor breaks exhaustive matches, so this ships in a kiroku-store
  major version (0.12.0.0) with kiroku-metrics and kiroku-otel bumps, and the changelog
  says so.
  Date: 2026-10-21
- Decision: Read sibling topology and initialize the exact key inside one
  `ReadCommitted Write` transaction holding `lockCheckpointNameStmt`.
  Rationale: A shared session alone does not serialize the read and insertion with
  startup, resize or rebind. Adopt only a uniform size/binding pair; retain the
  legacy size-1/unbound fallback for empty or inconsistent sets without repairing
  siblings. Existing rows and `FailIfMissing` retain their existing semantics.
  Date: 2026-10-25
- Decision: Match target mismatch like size mismatch in the built-in observers:
  touch subscription state in metrics, do nothing in tracing, and leave terminal
  accounting to the following `Stopped` event.
  Rationale: This preserves one crash count and one terminal span per refused
  worker without adding metric fields or a second terminal lifecycle event.
  Date: 2026-10-25
- Decision: Keep ADR-12's rule that filtered-out raw events bypass the undecodable
  callback; make the retry path consistent with it rather than changing the first pass.
  Rationale: ADR-12 chose raw-event filtering deliberately; the defect is that retries
  disagree with it. Changing the rule would alter delivery for every consumer with a
  filter.
  Date: 2026-10-21
- Decision: The low-level initializer adopts sibling topology instead of refusing.
  Rationale: Its return type `Either SubscriptionCheckpointMissing CheckpointInitialization`
  has no refusal case, and adding one is a break; adopting the rows' size and binding
  removes the footgun without changing the type. A name with no rows keeps today's
  size-1 `unbound` behaviour.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kiroku is a PostgreSQL event store in Haskell. A subscription worker is the thread
`Kiroku.Store.Subscription.Worker` runs for each subscription; it loads its checkpoint,
catches up from the database, switches to live delivery, and reports its lifecycle
through `KirokuEvent` values (`kiroku-store/src/Kiroku/Store/Observability.hs`) passed
to the store's event handler. Exhaustive consumers of `KirokuEvent` in this repository
are `kiroku-metrics/src/Kiroku/Metrics/Collector.hs` and
`kiroku-otel/src/Kiroku/Otel/Subscription.hs`; downstream exhaustive matchers are found
with `mori registry dependents shinzui/kiroku --packages`.

In `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`,
`withHandlerStallDiagnostics` (lines 249 to 263) throws
`InvalidHandlerStallWarnAfter` when the interval is not positive, before
`runWorkerBody` is entered; `runWorkerBody` wraps the body in `try` (around line 499)
and emits `KirokuEventSubscriptionStopped subName pos (classifyStopReason e) groupCtx`
for any exception, so refusals raised inside it are observable and this one is not.
The checkpoint load (lines 578 to 596) converts `SomeSubscriptionStartupFailure` to a
throw and emits `KirokuEventSubscriptionGroupSizeMismatch` only for the size case; a
`SubscriptionTargetMismatch` reaches the operator only inside `StopWorkerCrashed`.
Delivery is `processEvents`: `walk` (lines 817 to 836) applies
`shouldDeliver (eventTypeFilter config) (selector config) event` to `rawOf item`, where
`rawOf = decodedEventRecorded` returns the hook's output for `Decoded` and the raw
event for `Undecodable`; `dispatch` (843 to 853) handles the undecodable branch; and
`retryDecode` (855 onward) re-applies the hook and, on success, filters on the decoded
event (`Decoded event | not (shouldDeliver ... event) -> pure True`). The test
`kiroku-store/test/Test/PublisherCallbackResilience.hs` "does not apply an undecodable
disposition to an explicitly filtered-out event" pins the raw-excluded case;
`kiroku-store/test/Test/HandlerStall.hs` line
250 asserts the typed `InvalidHandlerStallWarnAfter` from `wait`;
`kiroku-store/test/Test/SubscriptionTarget.hs` covers binding policies.

The low-level initializer is the `InitializeSubscriptionCheckpoint` constructor of the
`Store` effect (`kiroku-store/src/Kiroku/Store/Effect.hs` lines 175 to 179 and 442 to
444), interpreted by `Kiroku.Store.Subscription.Checkpoint.SQL.initializeSubscriptionCheckpointSession`,
in `kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs`, which calls
`initializeCheckpointWith ... 1 Nothing` (size 1, unbound). Its insert leaves an
existing exact-key row unchanged. The topology lock and verification used by workers
live in the same module
(`initializeWorkerCheckpointSession`, with `pg_advisory_xact_lock` on a per-name key).
`SubscriptionTargetMismatch` and `ConsumerGroupSizeMismatch` are defined in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`.

The per-name advisory lock is a PostgreSQL lock released at transaction end.
`resizeConsumerGroupTx` and `rebindSubscriptionTargetTx` in
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint.hs` acquire it;
`resetSubscriptionCheckpointsTx` does not. None of these operations stops an active
worker. Resize creates every member from zero through size minus one, so a missing
member fixture should instead start and stop only member 0 of a configured size-2
group before initializing member 1.

`kiroku-metrics/src/Kiroku/Metrics/Collector.hs` handles size mismatch with
`touchSub ... id`; `kiroku-otel/src/Kiroku/Otel/Subscription.hs` handles it with
`pure ()`. Their `Stopped` branches increment `subscriptionsStoppedCrashed` and
emit the `kiroku.subscription.stopped` span respectively. Observer fixtures live in
`kiroku-metrics/test/Test/CollectorSpec.hs` and `kiroku-otel/test/Main.hs`.

Documentation: `docs/user/subscriptions.md` (decode hooks, undecodable handler,
dispositions), `docs/user/consumer-groups.md` ("Operational Invariant" at line 114 and
"Resizing The Group" at 146), `docs/user/observability.md` (the `KirokuEvent`
catalogue), and `docs/user/metrics.md` where the collector's counters are listed.

Relevant ADRs: [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md)
(existing checkpoints win, missing policies retain their position semantics, and
explicit topology operations require stopped workers),
[ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md)
(every runtime startup refusal is an exception under one parent; the store never skips
an event on a consumer's behalf; checkpoint-set operations live together),
[ADR-12](../adr/0012-decode-failures-are-per-event-outcomes-with-independent-subscription-dispositions.md)
(filtered-out raw events bypass the callback; `Stop` checkpoints the event; the
default path stops before it), and
[ADR-13](../adr/0013-handler-stall-diagnostics-are-worker-owned-and-advisory.md)
(nonpositive intervals fail before checkpoint initialization under the shared parent).
Milestone 2 adds one sentence to ADR-12; milestone 1 does not change ADR-13's rule, only
makes the refusal observable. Milestone 3 amends ADR-4 to describe low-level
inheritance of uniform sibling metadata, without creating other members or inferring
their positions, and the exact advisory-lock coverage. No cross-repository ADR applies.


## Plan of Work

Milestone 1 makes refusals observable. In the invalid-threshold branch of
`withHandlerStallDiagnostics`, emit `KirokuEventSubscriptionStopped` with
`StopWorkerCrashed` carrying the typed exception before throwing it. The event carries
the worker's name, position 0 and group context. Preserve validation before checkpoint
initialization and the exception surfaced by `wait`; this branch must not enter
`runWorkerBody` and produce a second stop. Extend
`kiroku-store/test/Test/HandlerStall.hs` to assert exactly one stop for both zero and
negative intervals, the concrete and parent exceptions, and no checkpoint creation.

Add `KirokuEventSubscriptionTargetMismatch !SubscriptionTargetMismatch
!SubscriptionGroupContext` next to the size-mismatch constructor in
`kiroku-store/src/Kiroku/Store/Observability.hs`, and emit it in the checkpoint-load
refusal branch before throwing. Extend `kiroku-store/test/Test/SubscriptionTarget.hs`
to assert the mismatch payload and group context, followed by exactly one crashed
stop and the typed refusal from `wait`. In the collector use `touchSub ... id` for
the new event; in the tracer use `pure ()`. Feed a target-mismatch/Stopped sequence
without a preceding Started event through the observer fixtures named above and
assert exactly one crash count and one terminal span with stop reason and checkpoint
attributes. Also cover the lone Stopped sequence for invalid stall configuration.
Document the dedicated event and single-stop accounting in
`docs/user/observability.md`; no new metrics fields or counters are required.

Milestone 2 makes filtering consistent. In `retryDecode`, drop the decoded-event
filter and instead rely on the decision `walk` already made for the raw event, so a
retry either delivers the decoded event or continues the undecodable path, never
silently skips. In `kiroku-store/test/Test/PublisherCallbackResilience.hs`, use event
types `OrderCreatedV1` (V1) and `OrderCreatedV2` (V2). Cover immediate V1-to-V2 success
with a V2-only filter and failed V1 decoding being excluded by that filter without
calling the undecodable callback. Add the
regression that fails on today's code: use a V1-only filter, fail decoding V1 initially,
then have the undecodable callback enable successful V1-to-V2 decoding and return
`Retry (RetryDelay 0)`. The next decode succeeds to V2, which is outside the filter,
but the ordinary handler must receive it exactly once and return `Stop`. Assert one
undecodable callback, one ordinary delivery, the event's checkpoint and no dead letter.
Keep the hook failing until the callback enables recovery so publisher decoding cannot
consume the intended first failure. Use bounded waits, preserve event identity and
position, and name the case with "undecodable" so the focused command selects it.
Existing persistent-failure retry tests remain relevant but do not prove this fix.
Add one sentence to ADR-12 making the rule explicit
("the filter decision is taken once, on the hook's output for decodable events and on
the raw event otherwise, and does not change across retries"), bump its timestamp, add
the log entry and validate strictly. In `docs/user/subscriptions.md` add the same rule
and a warning that a type-rewriting hook should keep raw types in the filter, and make
the `Stop` disposition's effect explicit: it checkpoints past the event, so a callback
that wants to investigate an event later should use `Retry` with a delay or
`DeadLetter`, not `Stop`.

Milestone 3 removes the initializer footgun and documents the lock. Wrap
`initializeSubscriptionCheckpointSession` in a `ReadCommitted Write` transaction,
acquire `lockCheckpointNameStmt`, read the name's rows, then call
`initializeCheckpointWith Tx.statement` while still holding the lock. If all existing
rows agree on both size and binding, inherit that pair, including an unbound binding.
For no rows or disagreement on either field, pass the existing size-1/unbound defaults;
do not mutate siblings or claim to repair inconsistent sets. The initializer keeps its
return type, existing-row precedence, atomic current-head seeding and `FailIfMissing`
behavior. The transaction ends only after initialization and any winner reread.

In `kiroku-store/test/Test/SubscriptionCheckpointInitialization.hs`, start only member
0 of a size-2 group with a category target, await live, then cancel and wait for it.
Assert member 1 is absent, initialize member 1, and require `InitializedCheckpoint`,
size 2 and the exact category binding in the new row. Start member 1 with the matching
configuration and `RequireBound`, and await live with a timeout before cancelling and
joining it. This fixture must fail against the old size-1/unbound initializer. Reuse
existing tests for existing-row preservation, empty-name defaults, missing policies and
concurrent exact-key initialization; add focused assertions for uniform unbound and
inconsistent sibling metadata if those cases lack coverage.

Add a bounded concurrent-rebind case to that suite: with all workers stopped and a
member absent, hold a rebind transaction open after it acquires the name lock, then
start low-level initialization on another connection. Establish that the initializer
is waiting on the advisory lock (using PostgreSQL lock state rather than a fixed
sleep), commit the rebind, and assert the inserted member inherits the committed new
binding. Ensure timeout cleanup joins the initializer and rolls back any still-open
transaction. This checks that adoption reads occur after lock acquisition.

In `docs/user/consumer-groups.md` "Operational Invariant" and
`docs/user/subscriptions.md`, state that the per-name lock serializes worker
initialization, the updated low-level initializer, resize and rebind. Reset does not
acquire this advisory lock. None of these operations stops a running member; its next
save writes its configured size and binding and can advance past a reset position.
Stop every member and prevent new starts during resize, rebind or reset. Amend ADR-4
with these boundaries and the low-level metadata-inheritance rule, advance its
timestamp, add its bundle log entry and validate strictly. Draft the `## Unreleased`
changelog entries for kiroku-store
(breaking: new `KirokuEvent` constructor; bug fixes: refusal observability, consistent
filtering, initializer adoption), kiroku-metrics and kiroku-otel (handle the new
constructor).


## Concrete Steps

All commands run from the repository root. `cabal.project` requires `ghc-9.12.4`;
the database fixtures require PostgreSQL binaries and create their own ephemeral
databases. If the compiler or database tools are missing, enter the repository's
development shell before the commands below:

```bash
nix develop --no-write-lock-file
ghc-9.12.4 --numeric-version
postgres --version
```

Expect GHC 9.12.4 and PostgreSQL 18 from the default shell. `nix/haskell.nix` defines
that shell; the suites do not require starting the project's development database.

```bash
cabal build all
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "stall"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "target"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "undecodable"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "initializ"'
cabal test kiroku-metrics:kiroku-metrics-test kiroku-otel:kiroku-otel-test \
  --test-show-details=direct
```

Each focused group must show the new cases passing; before the change, the new cases
fail with messages like:

```text
  emits a Stopped event for an invalid stall interval [✘]
    expected: one KirokuEventSubscriptionStopped with StopWorkerCrashed
     but got: []
```

Then the whole repository, because the new constructor touches three packages:

```bash
cabal test all
just perf-structure
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix fmt
```


## Validation and Acceptance

Milestone 1 is accepted when the worker tests prove event order, payload, typed
exceptions and exactly one crashed stop, and the observer tests prove exactly one
crash count and terminal span for each refusal sequence. Both observer suites pass
and `docs/user/observability.md` documents the new event and its accounting.

Milestone 2 is accepted when the recovered-decode regression delivers the excluded
rewritten type exactly once, checkpoints it and writes no dead letter; the immediate
success and raw-excluded scenarios still pass. The recovered-decode test must fail
with the old `retryDecode` guard. ADR-12 validates strictly and the guide carries the
filter rule and `Stop` warning.

Milestone 3 is accepted when a genuinely absent member is inserted with the uniform
sibling topology and then starts under `RequireBound`, and the concurrent-rebind test
proves the initializer waits and adopts the committed binding. Existing policies and
fallback behavior remain covered, both guides describe the precise lock boundaries,
and amended ADR-4 validates strictly. The full repository suite passes.

`just perf-structure` must pass. Review the diff of
`kiroku-store/src/Kiroku/Store/SQL.hs` and
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs` to confirm no append,
event-read or per-batch statement changes. The low-level initialization path adds a
transaction, name-lock acquisition and topology read; these occur only during explicit
provisioning, not per delivered batch. No remote performance experiment is required.

Proposed, not required: a typed refusal for `rebindSubscriptionTargetTx` on an absent
name, which today fails with hasql's `UnexpectedAmountOfRows`; it changes the function's
error contract and is left for a later decision.


## Idempotence and Recovery

Code changes are small and local; tests run on ephemeral databases and can be repeated.
The ADR amendments and guide edits are additive. If the new constructor breaks a
downstream package found by `mori registry dependents`, record it under Surprises and
coordinate the bump. No schema migration is required. Initialization changes metadata
only for newly inserted rows; it does not repair existing inconsistent topology.
On failure the transaction rolls back and releases its advisory lock, so the same
initialization policy can be retried. Keep fixture setup and cleanup inside ephemeral
test databases.


## Interfaces and Dependencies

`Kiroku.Store.Observability.KirokuEvent` gains
`KirokuEventSubscriptionTargetMismatch !SubscriptionTargetMismatch !SubscriptionGroupContext`
(kiroku-store 0.12.0.0). `Kiroku.Store.Subscription.Worker` changes internally only.
`Kiroku.Store.Subscription.Checkpoint.SQL.initializeSubscriptionCheckpointSession`
keeps its type and now serializes topology inheritance with startup, resize and rebind.
`Kiroku.Metrics.Collector` and `Kiroku.Otel.Subscription` must match the new constructor
without duplicating terminal accounting; their public metric fields and span names
remain unchanged. ADR-4, ADR-12 and the user guides change text. Plan 102 owns the errata
for already-published entries; this plan writes only `## Unreleased` entries.

Revision note (2026-10-25): Applied the review findings by requiring name-locked
topology inheritance, tests that exercise missing-member insertion and successful
decode recovery to an excluded type, explicit single-stop observer accounting, and
accurate reset-lock documentation. Added the development-shell prerequisite and
aligned milestone acceptance with those checks. Implementation remains pending.
