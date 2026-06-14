---
id: 9
slug: audit-remediation-subscription-reliability-and-store-correctness-and-performance
title: "Audit remediation: subscription reliability and store correctness and performance"
kind: master-plan
created_at: 2026-06-11T04:32:35Z
intention: intention_01kv3qaxg9e91v0zq47stehnkz
---

# Audit remediation: subscription reliability and store correctness and performance

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A deep audit of the Kiroku event store (2026-06-10) — covering the subscription core
(`kiroku-store/src/Kiroku/Store/Subscription*`), the publisher/notifier
(`EventPublisher.hs`, `Notification.hs`), the append/read/SQL layers (`Append.hs`,
`Read.hs`, `SQL.hs`, `Effect.hs`, the bootstrap migration), the `shibuya-kiroku-adapter`
package, and the `kiroku-metrics` event-streaming endpoints — produced a set of
confirmed bugs and performance findings. The single most important theme: there are
several distinct paths by which a subscription stops consuming events **silently** —
no exception surfaces, no `KirokuEvent` is emitted, the process keeps running, and the
projection simply goes stale. The audit also verified the load-bearing foundations are
sound (commit-ordered, gap-free global positions via the `$all` row lock; correct
optimistic concurrency; sound lost-wakeup gates in all three live loops), so this
initiative is remediation, not redesign.

After this initiative is complete: no subscription, bridge stream, or Shibuya processor
can stall without a surfaced error; backward reads paginate correctly past the first
page; appends reject empty batches instead of silently mutating state; the publisher
does no fan-out work for subscribers that cannot consume it; the NOTIFY trigger fires
once per append instead of twice-plus-spurious; the WebSocket event tail neither
duplicates nor silently gaps events; and the two large performance ideas (append
pipelining, raw-payload reads) have been prototyped and benchmark-judged rather than
guessed at.

Excluded from scope: the parked partition-ready schema work, extraction of migrations
into a separate package (recorded long-term goal, but these fixes ship as new
timestamped migrations in `kiroku-store-migrations`), OTel metrics (deferred on the
unreleased hs-opentelemetry 0.4), and any change to the deliberate design decisions the
audit re-confirmed (no stream-name field on `RecordedEvent`; CTE-shaped append SQL —
plans 21/22/23 established round-trip count dominates SQL shape on hasql).

Cross-repo note: one HIGH finding (Shibuya's supervised runner skips `finalize` when a
handler throws, permanently wedging the kiroku ack bridge) is rooted in `shibuya-core`,
which lives in a different repository. EP-2 ships the defensive adapter-side fix here
and records the upstream fix as an explicit follow-up; keiro consumes kiroku by git pin,
so released fixes also need a push + pin bump to reach consumers.


## Decomposition Strategy

The findings were grouped by functional concern and blast radius, not by file. The
guiding principles: every "subscription silently stops" path belongs to one plan so the
fix can be verified as a single behavior ("a dead worker/publisher always surfaces an
error"); consumer-facing layers (adapter, metrics endpoints) get their own plans because
they are separately verifiable packages with their own test suites; pure SQL/schema
work is isolated because it ships as codd migrations with different verification
mechanics (schema checks, `EXPLAIN` evidence); and the two speculative performance items
are quarantined in a final benchmark-gated plan so unproven optimizations never block
correctness fixes.

Seven child plans, in three waves. Wave 1 (EP-1, EP-4) fixes the highest-severity
correctness bugs in kiroku-store itself. Wave 2 (EP-2, EP-3, EP-5, EP-6) builds on the
wave-1 surfaces: the adapter consumes EP-1's new bridge error semantics; the publisher
efficiency work touches the same modules EP-1 stabilizes; schema and metrics fixes are
independent but lower severity. Wave 3 (EP-7) is exploratory performance work, last
because it is the only plan whose outcome may legitimately be "measured, rejected,
documented".

Alternatives considered: a single mega-plan was rejected (well over five milestones,
four packages, two repos implicated); folding the adapter fixes into EP-1 was rejected
because the adapter is independently testable and its key fix (overflow policy) is
useful even before EP-1 lands; folding trigger changes into EP-3 (both reduce publisher
wakeups) was rejected because trigger changes are migration-shipped and EP-3 is pure
Haskell.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Eliminate silent subscription stalls in worker, publisher, and stream bridge | docs/plans/56-eliminate-silent-subscription-stalls-in-worker-publisher-and-stream-bridge.md | None | None | Complete |
| 2 | Harden shibuya adapter ack contract and overflow policy | docs/plans/57-harden-shibuya-adapter-ack-contract-and-overflow-policy.md | EP-1 | None | Complete |
| 3 | Stop publisher fan-out work for category and consumer-group subscribers | docs/plans/58-stop-publisher-fan-out-work-for-category-and-consumer-group-subscribers.md | None | EP-1 | Complete |
| 4 | Fix backward read pagination and append edge-case errors | docs/plans/59-fix-backward-read-pagination-and-append-edge-case-errors.md | None | None | Complete |
| 5 | Schema and trigger hygiene: NOTIFY guard, dead-letter FK policy, and index fixes | docs/plans/60-schema-and-trigger-hygiene-notify-guard-dead-letter-fk-policy-and-index-fixes.md | None | None | In Progress |
| 6 | Fix WebSocket event tail replay duplication and gap handling | docs/plans/61-fix-websocket-event-tail-replay-duplication-and-gap-handling.md | None | None | Not Started |
| 7 | Benchmark-gated append pipelining and raw-payload read passthrough | docs/plans/62-benchmark-gated-append-pipelining-and-raw-payload-read-passthrough.md | None | EP-4, EP-5 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 → EP-2 is the only hard dependency. EP-2's central fix is to make the Shibuya
processor observe worker death, which requires the error-carrying stream termination
that EP-1 adds to `Kiroku.Store.Subscription.Stream.subscriptionAckStream`. Until EP-1
delivers that surface (a terminal `TVar`-signalled outcome: clean end on stop/cancel,
rethrown exception on crash — see Integration Points), the adapter has nothing to
consume. EP-2's overflow-policy change (`DropSubscription` →
`PauseAndResume`) does not depend on EP-1, but shipping EP-2 as one coherent
"adapter cannot stall silently" change is worth the serialization.

EP-3 soft-depends on EP-1: both modify
`kiroku-store/src/Kiroku/Store/Subscription.hs` (`subscribe`) and
`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`. EP-1 should land first
because it changes the publisher loop's exception envelope; EP-3 then restructures
registration on top of the stabilized loop. EP-3 can proceed in parallel if its author
coordinates on the two files (see Integration Points).

EP-4, EP-5, and EP-6 have no dependencies and can proceed in parallel with everything
else. EP-7 soft-depends on EP-4 (its pipelining prototype must not re-introduce the
empty-batch behavior EP-4 fixes, and benchmarks should run against fixed appends) and
on EP-5 (benchmark numbers shift once the NOTIFY trigger fires half as often; measuring
before and after EP-5 would conflate the two effects).

Parallelism summary: EP-1, EP-4, EP-5, EP-6 may all start immediately. EP-2 starts when
EP-1 completes. EP-3 starts any time, ideally after EP-1. EP-7 starts after EP-4 and
EP-5 complete.


## Integration Points

**`Kiroku.Store.Subscription.Stream` bridge termination semantics (EP-1 defines,
EP-2 consumes).** EP-1 changes `subscriptionAckStream`/`subscriptionStream` so the
bridge terminates with the worker's outcome on every exit path. As authored, EP-1
implements this with a terminal `TVar (Maybe BridgeTermination)` consulted via STM
`orElse` in the reader step — not a terminal queue element, because a queue write can
block when the queue is full (the very defect EP-1's M1 also fixes). The behavioral
contract is mechanism-independent: a clean stop or cancellation ends the stream; a
worker crash rethrows the worker's exception to the consumer. EP-2 relies on exactly
this: the adapter's processor stream must end with an error Shibuya's supervision can
see. EP-1 must document the final shape in its Outcomes section; EP-2 must read it
before starting.

**`subscribe` registration flow in `kiroku-store/src/Kiroku/Store/Subscription.hs`
(EP-1 and EP-3 both touch).** EP-1 adds masking/bracketing around the
register-then-fork window; EP-3 makes publisher-queue registration conditional on the
subscription target (only non-group `AllStreams` subscribers register a queue). The
combined invariant: every acquired resource (publisher queue registration, state
registry entry) is released on every exit path including async exceptions in the
pre-fork window, and category/consumer-group workers never own a publisher queue at
all. EP-1 defines the bracketing structure; EP-3 extends it rather than rewriting it.

**`EventPublisher` loop (EP-1 and EP-3 both touch).** EP-1 wraps the loop body so user
callbacks (`decodeHook`, `eventHandler`) cannot kill the thread and adds a liveness
signal. EP-3 changes `fetchAndBroadcast` to fetch full rows only when at least one
queue-consuming subscriber is registered, advancing `lastPublished` via the cheap
`currentGlobalPositionStmt` otherwise. EP-3 must preserve EP-1's exception envelope.

**`subscriptions` / `dead_letters` tables (EP-5 defines schema changes, EP-1
reads).** EP-5 adds the `dead_letters(event_id)` index and decides the FK policy for
hard deletes. EP-1's checkpoint-load hardening does not change schema; no coordination
needed beyond both plans citing the same bootstrap migration
(`kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`).

**NOTIFY contract (EP-5 changes the producer, no consumer changes).** The trigger
payload format `stream_name,stream_id,stream_version` parsed by
`Kiroku.Store.Notification.categoryFromPayload` must remain stable. EP-5's trigger
guard (skip the `stream_id = 0` row and non-version-bump updates) changes *when*
notifications fire, never the payload shape. Any payload change is out of scope for
this initiative.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: Bridge streams terminate with the worker's outcome (sentinel on every exit path; non-blocking cancel)
- [x] EP-1: Publisher loop survives user-callback exceptions and surfaces liveness
- [x] EP-1: `subscribe` pre-fork window is async-exception safe; checkpoint-load failure no longer silently replays from 0
- [x] EP-1: Notifier startup releases the connection when LISTEN fails
- [x] EP-2: Adapter defaults to `PauseAndResume`; overflow can no longer kill the processor
- [x] EP-2: Handler exceptions finalize a disposition (adapter-side defense; shibuya-core follow-ups recorded)
- [x] EP-2: Worker death is visible at the adapter boundary (consumes EP-1's termination contract)
- [x] EP-2: `kirokuConsumerGroupProcessors` validates group size and cleans up on partial failure
- [x] EP-3: Category/consumer-group subscriptions no longer register publisher queues
- [x] EP-3: Publisher fetches full rows only when an AllStreams subscriber exists
- [x] EP-3: Full-fetch attach race closed (late registrants receive the in-flight batch atomically with the position advance)
- [x] EP-4: Backward reads paginate correctly with nonzero cursors (failing test first)
- [x] EP-4: Empty-batch appends are rejected before touching the pool
- [x] EP-4: Link errors and single-stream deadlocks map to typed errors / are retried
- [x] EP-4: Round-trip economies (short-page stream stop; empty lookup short-circuit)
- [x] EP-5: NOTIFY trigger fires once per append; lifecycle updates fire nothing
- [x] EP-5: Dead-letter FK policy decided and enforced; `dead_letters(event_id)` indexed
- [ ] EP-5: Junction-delete path has index support; index hygiene applied
- [ ] EP-5: Stream-name length bound enforced (closes the NOTIFY payload abort edge)
- [ ] EP-6: WS replay neither duplicates past attach position nor falls through a gap
- [ ] EP-6: `subscriptionsApp` unknown paths return the documented 404
- [ ] EP-7: Pipelined multi-stream append prototyped and benchmarked (promote or document rejection)
- [ ] EP-7: Raw-bytes read variant prototyped and benchmarked (promote or document rejection)
- [ ] EP-7: Conditional integration of passing prototypes; unconditional lock-hold documentation


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

Seed observation from the audit itself: the three independent "silent stall" paths —
bridge sentinel, publisher death, skipped finalize — compound: any one of them leaves a
Shibuya processor consuming nothing while healthy-looking. EP-1 + EP-2 together close
all three.

2026-06-11, discovered while drafting EP-6 (docs/plans/61): a **new, pre-existing
event-loss race** in `EventPublisher.fetchAndBroadcast` — a subscriber whose
registration commits between the publisher's registry snapshot and its `lastPublished`
advance never receives the in-flight batch, and if its checkpoint already sits inside
that batch's range its catch-up gate (which still reads the pre-advance position)
declares it caught up, so the missed positions are silently skipped until a pause or
reconnect forces a re-catch-up. Folded into EP-3's Milestone 2 (docs/plans/58, Finding
C there), which already rebuilds that function around an atomic
snapshot-recheck-plus-position-write.

2026-06-11, discovered while drafting EP-2 (docs/plans/57): shibuya-core's supervised
runner *discards the ingester async handle* (`withAsync` handle dropped,
`Supervised.hs:253` in the shibuya repo), so even after EP-1 makes the bridge rethrow a
worker crash, `runApp` swallows it; the rethrow is observable at the `adapter.source`
boundary and via `runWithMetrics`. Recorded in EP-2 as a second shibuya-core upstream
follow-up alongside finalize-on-exception.

2026-06-11, EP-1 authoring refined the bridge termination mechanism from the
provisional "terminal queue element" sketched here to a terminal `TVar` consulted via
`orElse` (a queue write can block on a full queue — the defect being fixed). Integration
Points and EP-2's dependency callout were aligned accordingly.

2026-06-14, discovered while completing EP-1: the new
`KirokuEventPublisherLoopError` event also had to be consumed by in-repo
observability packages. `kiroku-otel` now ignores it explicitly because it is not
subscription-scoped, and `kiroku-metrics` now exposes a distinct publisher loop error
counter so callback/decode failures are visible separately from publisher pool errors.

2026-06-14, EP-1 completed. Final validation passed with `just build` and `just test`;
all workspace suites passed, including `kiroku-store-test` (196 examples),
`shibuya-kiroku-adapter-test` (21 examples), `kiroku-metrics-test` (16 examples),
`kiroku-otel-test` (17 examples), `kiroku-cli-test` (22 examples), and
`kiroku-store-migrations-test` (1 example).

2026-06-14, EP-2 completed. `shibuya-kiroku-adapter` now uses Kiroku's
lossless `PauseAndResume` overflow behavior, exposes `queueCapacity`, rejects
zero bridge buffers at `subscriptionAckStream`, guards throwing handlers into
finalized retry dispositions, verifies EP-1's worker-crash rethrow at
`Adapter.source`, and validates/cleans up consumer-group construction.
Validation passed with `just build` and `just test`; `shibuya-kiroku-adapter-test`
now has 29 examples and `kiroku-store-test` now has 197 examples.

2026-06-14, EP-3 M1 completed. EP-1's exception-safe `subscribe` bracket was
already present, so conditional publisher registration was slotted into the
existing acquisition path. Category subscriptions and consumer-group members now
construct DB-driven `LiveSource` values without calling `subscribePublisher`; the
new registry assertions prove these subscriptions leave the publisher subscriber
map empty while non-group `AllStreams` still registers and unregisters exactly
one queue. Validation passed with `just build` and
`cabal test kiroku-store:kiroku-store-test` (198 examples, 0 failures).

2026-06-14, EP-3 M2 completed. The publisher now takes a single-row
`currentGlobalPositionStmt` path when no queue subscriber is registered, with an
STM registry re-check before advancing `lastPublished`; the full-fetch path now
offers the in-flight batch to late registrants in the same STM transaction that
advances the position. Focused tests showed the pre-fix publisher decoded 25
rows with no subscribers and 30 rows with only a category subscriber, then passed
after the edit. Full validation passed with `cabal test
kiroku-store:kiroku-store-test` (201 examples, 0 failures).

2026-06-14, EP-3 completed. Workspace validation passed with `just test`:
`kiroku-store-test` (201 examples), `shibuya-kiroku-adapter-test` (29 examples),
`kiroku-metrics-test` (16 examples), `kiroku-otel-test` (17 examples),
`kiroku-cli-test` (22 examples), and `kiroku-store-migrations-test` (1 example)
all reported 0 failures. No cross-plan interface changes were needed beyond the
documented EP-1 extension points.

2026-06-14, EP-4 M1 completed. Backward stream reads and `$all` reads now treat
nonzero cursors as exclusive upper bounds, while cursor 0 is mapped to `maxBound` in
the interpreter before the SQL runs. The new bite-check tests failed before the fix
with newer events on page 2 and passed afterward; `kiroku-store-test` now has 203
examples and passed with 0 failures.

2026-06-14, EP-4 M2 completed. Empty per-stream append batches now fail before pool or
transaction work with `EmptyAppendBatch` / `EmptyAppendBatchConflict`; `appendMultiStream
[]` remains a no-op success. The bite-check reproduced the previous phantom stream and
partial multi-stream commit behavior before guards were added. Validation passed with
`kiroku-store-test` (208 examples, 0 failures) and `cabal build all`.

2026-06-14, EP-4 M3 completed. `linkToStream` now maps duplicate links to
`EventAlreadyLinked` and missing source events to `LinkSourceEventMissing`, and the
single-stream append interpreter retries once on PostgreSQL transient transaction
SQLSTATEs `40001` and `40P01`. Validation passed with targeted link, pure predicate,
and concurrency tests, full `kiroku-store-test` (210 examples, 0 failures), and
`cabal build all`.

2026-06-14, EP-4 completed. `readStreamForwardStream` now stops after a short final
page and flattens vectors without an intermediate list, and `lookupStreamNames []`
returns `Map.empty` without a pool checkout. Final validation passed with `cabal build
all` and `cabal test all`: `kiroku-store-test` (212 examples), `shibuya-kiroku-adapter-test`
(29 examples), `kiroku-metrics-test` (16 examples), `kiroku-otel-test` (17 examples),
`kiroku-cli-test` (22 examples), and `kiroku-store-migrations-test` (1 example) all
reported 0 failures.


## Decision Log

- Decision: Group all silent-stall fixes (bridge, publisher supervision, subscribe
  leak window, notifier startup leak, checkpoint-load fallback) into one plan (EP-1)
  rather than splitting by module.
  Rationale: They share one verifiable behavior — "no subscription path may stop
  without a surfaced error" — and one test harness (fault-injected worker/publisher
  death). Splitting would scatter that invariant across plans.
  Date: 2026-06-11

- Decision: EP-2 hard-depends on EP-1.
  Rationale: The adapter can only surface worker death once the bridge stream
  carries it (EP-1's new termination semantics). Shipping the adapter plan in two
  halves was rejected as churn.
  Date: 2026-06-11

- Decision: Fix Shibuya's skipped-finalize defect defensively in the adapter (wrap
  the handler so an exception finalizes `AckDeadLetter`/`AckRetry`), and record the
  proper fix in shibuya-core as an upstream follow-up rather than a child plan here.
  Rationale: shibuya-core is a separate repository; this MasterPlan only coordinates
  kiroku-repo work. The adapter-side wrap is correct regardless of when upstream
  lands.
  Date: 2026-06-11

- Decision: Performance items (append pipelining via `Hasql.Pipeline`, raw-bytes
  payload passthrough) are quarantined in benchmark-gated EP-7 with explicit
  promote-or-reject criteria.
  Rationale: Plans 21/22/23 established that benchmark evidence, not SQL-shape
  intuition, decides append-path changes (round-trip count dominates). Pipelining
  aligns with that finding (it removes round trips) but must prove itself the same
  way.
  Date: 2026-06-11

- Decision: Keep the NOTIFY payload format unchanged in EP-5; address the ~8 kB
  payload abort by constraining stream-name length at append validation time, not by
  changing the payload.
  Rationale: The payload is a cross-component contract (trigger →
  `categoryFromPayload`); changing it has fan-out far beyond the low-severity
  finding it would fix.
  Date: 2026-06-11

- Decision: Assign the full-fetch attach race (discovered 2026-06-11 during EP-6
  drafting) to EP-3's Milestone 2, fixed by delivering the in-flight batch to late
  registrants inside the same STM transaction that advances `lastPublished`.
  Rationale: EP-3's M2 already rebuilds `fetchAndBroadcast` around exactly that atomic
  shape for its cheap-advance path; EP-1 owns the publisher loop's exception envelope,
  not its delivery/advance ordering. The alternative (advancing the position before
  delivery) closes the attach race but opens a crash-loss window under EP-1's
  continue-on-error policy. Full rationale in docs/plans/58's Decision Log.
  Date: 2026-06-11

- Decision: Defer these LOW/INFO findings without a child plan, recording them here:
  duplicate same-name non-group subscriptions are unguarded (extend
  `consumerGroupGuard` to non-group subscriptions later); `categoryGenerations` map
  never prunes (bounded by category cardinality in practice); retry-count doc
  off-by-one ("five redeliveries" is actually five total deliveries — fix docs in
  EP-1 while touching the worker); `WrongExpectedVersion` actual-version is always 0
  on the empty-CTE path (doc fix in EP-4); soft-deleted streams remain visible to
  category subscription reads (`readCategoryForwardSQL` has no `deleted_at` filter,
  unlike `readStreamForwardSQL`) — intentionality unclear, needs a product decision
  before any code change.
  Rationale: Each is low severity, and several need decisions rather than code.
  Date: 2026-06-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

2026-06-14, after EP-2: the Shibuya adapter no longer has the silent-stall
paths identified for this package. A slow adapter-backed subscription no longer
dies on publisher queue overflow, a synchronous handler exception is turned into
a real Kiroku disposition instead of abandoning the ack reply, EP-1's worker
death signal is observable at the adapter stream boundary, and the
consumer-group helper now fails loudly for invalid sizes and releases partially
created members on construction failure. The remaining caveat is upstream:
shibuya-core still needs to propagate supervised ingester failures and decide
how `processOne` should finalize handler exceptions.

2026-06-14, after EP-3: category and consumer-group subscriptions no longer own
publisher queues they never read, so their configured overflow policy cannot
silently become inert and their processes do not pin unused publisher batches.
When no queue-consuming subscriber exists, the publisher now advances its
`lastPublished` position with a single-row `$all` tail query instead of fetching
and decoding event payloads. The full-fetch attach race is closed by delivering
the in-flight batch to late registrants atomically with the position advance.

2026-06-14, after EP-4: store read and append edge cases from the audit are remediated.
Backward reads now paginate with exclusive upper-bound cursors; empty append batches no
longer create phantom streams or take the `$all` lock; link failures are typed instead
of raw `ConnectionError` blobs; single-stream appends retry one transient transaction
abort; and two read-path round-trip leaks are closed. EP-7 can now benchmark append
pipelining against the fixed empty-batch behavior.


---

*Revision note (2026-06-11).* Post-authoring consistency pass after all seven child
plans were drafted in parallel: (1) Integration Points now records EP-1's as-authored
bridge-termination mechanism (terminal `TVar` via `orElse`, replacing the provisional
terminal-queue-element sketch), and EP-2's dependency callout was aligned (revision
note in docs/plans/57). (2) The full-fetch attach race discovered while drafting EP-6
was recorded in Surprises & Discoveries, assigned to EP-3's Milestone 2 by a new
Decision Log entry, and cascaded into docs/plans/58 (Finding C, M2 edit, progress item,
decision; revision note there). (3) The shibuya-core ingester-async-discard discovery
from EP-2 drafting was recorded in Surprises & Discoveries. (4) The Progress checklist
was expanded to match the milestones the child plans actually shipped with (EP-2 M3,
EP-3 attach race, EP-4 M4, EP-5 M4, EP-6 404, EP-7 M3).

*Revision note (2026-06-14).* EP-4 implementation completed under docs/plans/59: the
registry status is now Complete, all four EP-4 progress items are checked, Surprises &
Discoveries records milestone validation, and Outcomes & Retrospective summarizes the
store correctness and efficiency fixes now available to downstream plans.
