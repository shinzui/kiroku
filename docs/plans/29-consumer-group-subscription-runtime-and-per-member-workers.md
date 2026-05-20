---
id: 29
slug: consumer-group-subscription-runtime-and-per-member-workers
title: "Consumer-Group Subscription Runtime and Per-Member Workers"
kind: exec-plan
created_at: 2026-05-20T03:19:43Z
intention: "intention_01ks1npgpye4xvcczxvzjsq232"
master_plan: "docs/masterplans/4-consumer-group-support-for-partitioned-subscriptions.md"
---

# Consumer-Group Subscription Runtime and Per-Member Workers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. A **subscription** is a long-lived
background worker thread that reads events from the store in order and feeds them
one at a time to a caller-supplied **handler** function. Today every subscription
is a single sequential consumer: one thread reads either the whole global event
sequence (the `$all` stream) or one **category** (events whose stream names share
a prefix before the first dash, e.g. `acct-1` and `acct-2` are both in category
`acct`) in order. Because there is only one thread, a slow handler caps end-to-end
throughput, and there is no supported way to spread the work across threads or
processes while still processing each stream's events in their original order.

This plan adds **consumer groups**. A consumer group is a named set of `N`
**members** that together process one subscription in parallel. Each stream is
deterministically assigned to exactly one member by hashing the stream's
database id, so every event from the same stream always lands on the same member
in global-position order. Members run independently, each with its own checkpoint
(the saved "I have processed up to position P" marker), so adding members adds
parallelism without breaking per-stream ordering. We call `N` the **group size**
and each member's zero-based index its **member index**.

After this change a developer can start "member `m` of a group of size `N`" using
the existing `subscribe` / `withSubscription` functions plus a small
`ConsumerGroup` descriptor, run those members as separate threads in one process
(or separate processes), and observe that:

- each appended event is delivered to **exactly one** member (the union of all
  members' deliveries is the complete source, with no event delivered twice and
  none dropped);
- within each member, for each individual stream the events arrive in ascending
  global position (per-stream ordering is preserved);
- a size-1 group delivers exactly the same set as an ordinary (non-group)
  subscription.

You can see it working by running the automated test added by this plan
(`cabal test kiroku-store`): it appends events to forty streams in one category,
runs a size-4 group of four in-process members, waits for the publisher to ingest
everything, and asserts the disjoint/complete/ordered properties above plus a
checkpoint-resume scenario where one member restarts and continues from *its own*
saved position rather than another member's.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-05-20): Add `ConsumerGroup` type and `consumerGroup :: !(Maybe ConsumerGroup)`
  field (plus `consumerGroupGuard :: !Bool`) to `Kiroku.Store.Subscription.Types`; set
  them to `Nothing`/`False` in `defaultSubscriptionConfig`; export
  `ConsumerGroup`/`InvalidConsumerGroup`/`ConsumerGroupGuardConflict`. Build green; all
  existing tests pass (143 examples, 0 failures).
- [x] M1 (2026-05-20): Add the `InvalidConsumerGroup` (and `ConsumerGroupGuardConflict`)
  exceptions to `Kiroku.Store.Subscription.Types` and enforce `size >= 1` and
  `0 <= member < size` once, with `throwIO`, at the top of
  `Kiroku.Store.Subscription.subscribe`. Build green. Updated all 26 explicit
  `SubscriptionConfig` record literals (21 in test/Main.hs, 1 in
  Test/FailureInjection.hs, 1 in bench/Main.hs, 3 in bench/ShibuyaOverhead.hs) to set
  the two new fields, since a missing record field would be forced to bottom by the worker.
- [x] M2 (2026-05-20): Thread `consumerGroup` into `Kiroku.Store.Subscription.Worker.runWorker`
  and route `fetchBatch` / `catchUp` and the checkpoint load/save through the
  member-aware statements when in a group; keep non-group behavior identical.
  Build green. (`fetchBatch` now dispatches on `(consumerGroup, target)`;
  `loadCheckpoint`/`saveCheckpoint` take the full config and always use
  `getCheckpointMemberStmt`/`saveCheckpointMemberStmt` with `configMember` =
  member-or-0, one path for group and non-group.)
- [x] M2 (2026-05-20): Make the live loop for a `Category` group use the DB-driven
  `liveLoopCategoryDriven` path with the partitioned statement; per-member
  checkpoints persisted under `(name, member)`. (A `Category` group already
  selects `liveLoopCategoryDriven`, which calls the now-partitioned `fetchBatch`,
  so no live-loop change was needed for the category path; `$all` routing is M3.)
- [x] M2 (2026-05-20): Add `kiroku-store/test/Test/ConsumerGroup.hs`, register it in the cabal
  `other-modules`, wire it into `kiroku-store/test/Main.hs`; write the category
  group end-to-end test (disjoint + complete + per-stream-ordered) and the
  size-1-equals-plain test. Tests pass (2 examples, 0 failures).
- [x] M3 (2026-05-20): Add the `$all`-group runtime: route a `Just`-group `AllStreams`
  subscription through a DB-driven live loop using `readAllForwardConsumerGroupStmt`
  (not the broadcast queue); non-group `AllStreams` keeps the broadcast queue.
  Extend the test module with an `$all`-group case. Tests pass. (The live-phase
  selection now matches `(consumerGroup, target)`; `liveLoopCategoryDriven` was
  renamed `liveLoopDbDriven` since it now serves all grouped subscriptions too.)
- [x] M3 (2026-05-20): Extend observability (IP-5) so subscription lifecycle events carry
  member/size context; update the worker emit sites; build green and existing
  observability tests pass. (Added `SubscriptionGroupContext = NonGroup | GroupMember
  !Int32 !Int32`, a trailing field on the four `KirokuEventSubscription*` lifecycle
  constructors, re-exported from `Kiroku.Store`; updated the worker's 7 emit sites and
  the two test matchers in `Main.hs`/`Helpers.hs`.)
- [x] M3 (2026-05-20): Add the checkpoint-resume test (member 2 stops after K, restarts, resumes
  from its own checkpoint). Tests pass. (Proves member-keying by writing a competing
  high `(name, 0)` checkpoint and asserting member 2 ignores it, resuming from its own
  `(name, 2)` row against the EP-1 partition SQL ground truth.)
- [x] M4 (2026-05-20): Add the optional advisory-lock guardrail (`consumerGroupGuard :: !Bool`
  config field, default `False`, added in M1); implement the startup
  `pg_try_advisory_xact_lock` conflict check (`guardMember` in the worker, run before
  `loadCheckpoint` when the guard is on and a group is configured); lifetime-held-lock
  limitation documented in the Decision Log as follow-up. Build green; deterministic
  guard conflict test added (a dedicated connection holds the session-level lock; the
  guarded member fails with `ConsumerGroupGuardConflict`).
- [x] M4 (2026-05-20): Confirm the Streamly bridge (`Kiroku.Store.Subscription.Stream.subscriptionStream`)
  forwards the new `consumerGroup` field unchanged (it threads the whole config via
  `config { handler = ... }` record update — no code change needed); bridge smoke test
  added (member 0 of 2 pulls exactly its partition slice). `cabal test kiroku-store` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Enforce the consumer-group validity invariant by throwing a dedicated
  exception `InvalidConsumerGroup` from `subscribe`, rather than returning
  `Either`.
  Rationale: `Kiroku.Store.Subscription.subscribe` already returns a bare
  `SubscriptionHandle` in `IO` (no `Either`), and the package's existing
  subscription error style is exception-based — `SubscriptionOverflowed` is an
  `Exception` surfaced through `wait`, and handler exceptions propagate uncaught.
  Changing `subscribe`'s return type to `Either` would be a breaking API change
  for every existing caller and for EP-3's effect wrappers. A misconfigured
  `(member, size)` is a programmer error that should fail loudly and immediately,
  so a `throwIO` at the top of `subscribe` (before any thread is spawned) is the
  least-disruptive, fail-fast choice.
  Date: 2026-05-20

- Decision: Always use the member-aware checkpoint statements
  (`getCheckpointMemberStmt`, `saveCheckpointMemberStmt`), with `member = 0` for
  non-group subscriptions, instead of branching between the old name-keyed
  statements and the new member-keyed ones.
  Rationale: EP-1 (`docs/plans/28-...`) changes the `subscriptions` unique key to
  `(subscription_name, consumer_group_member)` and migrates the existing
  `saveCheckpointStmt`/`getCheckpointStmt` to default member to 0, keeping them
  working. But carrying two code paths in the worker invites drift. Routing
  everything through the member-aware statements with `member = 0` for the
  non-group case yields one path, and it is exactly equivalent because IP-3
  guarantees existing rows are `consumer_group_member = 0`. The non-group worker
  therefore reads and writes the same `(name, 0)` row it always did.
  Date: 2026-05-20

- Decision: Route the live phase of **both** `Category` groups and `$all` groups
  through a DB-driven live loop (the `liveLoopCategoryDriven` shape), never the
  publisher's broadcast `TBQueue`.
  Rationale: The publisher's per-subscriber `TBQueue` carries *unfiltered* `$all`
  events (every appended event, decoded once and fanned out). A partitioned member
  must see only the events whose originating stream hashes to its slot. There is
  no in-process map from a stream id to its assigned member that the worker could
  use to filter the queue, and building/invalidating one is exactly the complexity
  the existing category path already avoids by re-querying the database with a
  source-side filter (see the comment in
  `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` referencing the EP-3 F18
  rationale: filtering broadcast events in-process "would require a stream-id ->
  category map and a cache invalidation story"). The partition predicate lives in
  the SQL EP-1 provides, so re-querying with `readCategoryForwardConsumerGroupStmt`
  / `readAllForwardConsumerGroupStmt` on each publisher tick is the correct,
  simple fit. A non-group `AllStreams` subscription is unchanged: it keeps using
  the broadcast queue exactly as today.
  Date: 2026-05-20

- Decision: Surface member/size context in observability by adding two optional
  fields to the existing subscription lifecycle constructors via a small
  `SubscriptionGroupContext` record threaded into the events, rather than adding
  parallel group-aware constructors.
  Rationale: IP-5 requires "without breaking the `KirokuEvent(..)` taxonomy
  re-exported from `Kiroku.Store`." `Kiroku.Store.Observability` documents the
  constructor set as *additive* (new constructors, never changed ones), and adding
  brand-new constructors is the most conservative reading. However the lifecycle
  events (`KirokuEventSubscriptionStarted`, `*CaughtUp`, `*Stopped`,
  `*DbError`) already exist and downstream code pattern-matches them; doubling them
  with `*Group` variants forces every consumer to handle both. The chosen approach
  adds a single new field of a new type `SubscriptionGroupContext` (which is
  `NonGroup | GroupMember !Int32 !Int32`) to each of those four constructors. This
  *is* a constructor signature change, so it is a compile-time-visible, additive
  change to the field list (not a silent semantic change); existing call sites in
  the worker are updated in the same milestone, and external pattern matches get a
  `-Wincomplete-patterns`-style nudge to add the field. We justify the field-add
  over new constructors because it keeps the taxonomy (the set of constructor
  *names*) intact, which is what "the `KirokuEvent(..)` taxonomy re-exported from
  `Kiroku.Store`" most directly refers to. If a reviewer prefers strict additivity
  of constructor *signatures*, the fallback is new `*Group` constructors; this is
  noted so the decision can be revisited cheaply.
  Date: 2026-05-20

- Decision: Scope the advisory-lock guardrail in this plan to a **startup conflict
  check** using `pg_try_advisory_xact_lock`, and document full lifetime-held
  locking as a marked limitation / follow-up.
  Rationale: A correct "one live process per member" guard needs a *session-level*
  advisory lock (`pg_advisory_lock` / `pg_try_advisory_lock`) held for the worker's
  entire lifetime. Session-level locks live on a specific connection and release
  when that connection is returned to the pool or closed. The worker fetches each
  batch via `Hasql.Pool.use`, which acquires a connection, runs the statement, and
  immediately returns the connection to the pool — so a session lock taken inside
  one `Pool.use` is released the instant that call finishes, defeating the guard.
  Holding the lock for the worker's lifetime therefore requires a *dedicated*
  connection kept open for that worker (the pattern
  `Kiroku.Store.Notification.Notifier` already uses for its `LISTEN` socket: it
  acquires a `Hasql.Connection.Connection` outside the pool and holds it). Wiring a
  dedicated per-member connection into the worker is a larger change than this
  runtime plan should carry, so this plan ships the cheaper, honest version: at
  worker startup, run `pg_try_advisory_xact_lock(key)` inside a one-shot
  transaction-scoped check (transaction-scoped locks auto-release at transaction
  end, which is fine for a *detection* probe). If the probe returns `false`, a
  conflicting holder exists right now and the worker fails fast with
  `ConsumerGroupGuardConflict`. This catches the common "I accidentally started two
  copies of member 3 at the same moment" mistake but does **not** prevent a second
  member from starting after the first has moved past startup. The full
  lifetime-held session lock on a dedicated connection is recorded as follow-up
  work. The key is a `bigint` derived from `hashtextextended(name <> ':' <> show
  member, 0)` computed in SQL so it is stable across processes.
  Date: 2026-05-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-05-20.** All four milestones landed. A developer can now start
member `m` of a size-`N` group via `subscribe`/`withSubscription` (or the Streamly
bridge) with a `ConsumerGroup` descriptor, and the members deliver a disjoint,
complete, per-stream-ordered partition of the source.

Against the original purpose:

- **Public surface (M1, IP-4).** `Kiroku.Store.Subscription.Types` exports
  `ConsumerGroup { member, size }`, the `consumerGroup :: Maybe ConsumerGroup` and
  `consumerGroupGuard :: Bool` fields on `SubscriptionConfigM` (defaulting to
  `Nothing`/`False`, so every existing caller compiles unchanged), and the
  `InvalidConsumerGroup` / `ConsumerGroupGuardConflict` exceptions. `subscribe`
  validates `size >= 1` and `0 <= member < size` and throws `InvalidConsumerGroup`
  before spawning a thread. All re-exported through `Kiroku.Store`.

- **Runtime (M2/M3).** `Worker.fetchBatch` dispatches on `(consumerGroup, target)`
  through EP-1's four partitioned/​member-aware statements; `loadCheckpoint`/
  `saveCheckpoint` go through one member-aware path (`configMember` = member-or-0).
  The live phase routes any group (and non-group `Category`) through the DB-driven
  `liveLoopDbDriven` (renamed from `liveLoopCategoryDriven`); only non-group
  `AllStreams` keeps the broadcast queue. Lifecycle observability carries
  `SubscriptionGroupContext` (`NonGroup | GroupMember member size`) on the four
  `KirokuEventSubscription*` constructors (IP-5).

- **Guardrail + bridge (M4).** An opt-in `consumerGroupGuard` runs a startup
  `pg_try_advisory_xact_lock` probe (`guardMember`) keyed on a stable
  `hashtextextended(name:member, 0)`; a concurrent holder makes it fail fast with
  `ConsumerGroupGuardConflict`, and a DB error degrades open. The Streamly bridge
  needed no change — it forwards the whole config via record update.

- **Acceptance.** `cabal test kiroku-store` is green: 150 examples, 0 failures, of
  which 7 are the new `Test.ConsumerGroup` cases — size-4 category partition
  (disjoint + complete + per-stream-ordered), size-1 == plain, `$all` partition,
  member-keyed checkpoint resume (proven against a competing high `(name, 0)`
  checkpoint), `GroupMember 2 4` observability, the guard conflict, and the bridge
  smoke test. The pre-existing 143 examples (M1 baseline) stayed green throughout,
  including the checkpoint-resume and lifecycle-event tests that exercise the
  migrated member-aware checkpoints and the new observability field.

Gaps / deferred (intentional):

- The advisory guard is a startup **detection probe**, not a lifetime-held lock —
  it catches a simultaneous double-start but not a staggered one. Full mutual
  exclusion needs a session-level lock on a dedicated per-worker connection (the
  `Notifier` pattern); recorded as follow-up in the Decision Log.

- The package-wide `SubscriptionConfig` record gained two fields, so all 26
  explicit record literals across the test and benchmark sources had to be updated
  (M1). A future refactor toward `defaultSubscriptionConfig`-plus-record-update at
  call sites would make such additions non-breaking.

Lessons: routing all checkpoints through the member-aware statements with member 0
for the non-group case (one code path) avoided worker drift and was exactly
equivalent because EP-1 guarantees legacy rows are `consumer_group_member = 0`.
Adding the `SubscriptionGroupContext` field to existing lifecycle constructors
(rather than new `*Group` constructors) kept the event taxonomy intact at the cost
of a compile-time-visible field add, which the two internal matchers absorbed with
one extra wildcard each.


## Context and Orientation

This section explains everything a newcomer needs, assuming only this file and the
current source tree.

### Hard dependency: EP-1 (the SQL and schema layer)

This plan **hard-depends on** the ExecPlan at
`docs/plans/28-consumer-group-partition-routing-sql-and-checkpoint-schema.md`
("EP-1"). EP-1 adds, to `kiroku-store/src/Kiroku/Store/SQL.hs`, four prepared
statements and the `subscriptions`-table schema changes this plan consumes. None
of the code here compiles until EP-1 has landed those statements and exported
them. The exact statements (verbatim from the parent MasterPlan's Integration
Point IP-2, `docs/masterplans/4-consumer-group-support-for-partitioned-subscriptions.md`)
are:

```haskell
-- params (startPosition, category, member, size, limit)
readCategoryForwardConsumerGroupStmt
    :: Statement (Int64, Text, Int32, Int32, Int32) (Vector RecordedEvent)

-- params (startPosition, member, size, limit)
readAllForwardConsumerGroupStmt
    :: Statement (Int64, Int32, Int32, Int32) (Vector RecordedEvent)

-- params (subscriptionName, member); returns the saved position or Nothing
getCheckpointMemberStmt
    :: Statement (Text, Int32) (Maybe Int64)

-- params (subscriptionName, member, position); upserts with GREATEST semantics
saveCheckpointMemberStmt
    :: Statement (Text, Int32, Int64) ()
```

The two read statements return the same `Vector RecordedEvent` shape as the
existing `readCategoryForwardStmt` and `readAllForwardStmt`, so the worker swaps
statements without touching event decoding. The **partition assignment rule**
EP-1 implements (MasterPlan IP-1) is, in SQL:

```text
member_of(stream_id) = (((hashtextextended(stream_id::text, 0) % size) + size) % size)
```

A stream belongs to member `m` of a group of size `N` iff `member_of(stream_id) =
m`. With `size = 1` this is always `0`, so a size-1 group equals a non-partitioned
subscription. This plan never re-implements that predicate; it lives entirely in
EP-1's SQL. We only pass `(member, size)` as parameters.

### How subscriptions work today (restated, self-contained)

The relevant files are:

- `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` — the public types:
  `SubscriptionName`, `SubscriptionTarget` (`AllStreams` or `Category
  !CategoryName`), `SubscriptionResult` (`Continue` or `Stop`), the record
  `SubscriptionConfigM m` (fields `name`, `target`, `handler`, `batchSize`,
  `queueCapacity`, `overflowPolicy`), the smart constructor
  `defaultSubscriptionConfig`, and `SubscriptionHandleM m` (`cancel`, `wait`).
- `kiroku-store/src/Kiroku/Store/Subscription.hs` — `subscribe` and
  `withSubscription`. `subscribe` registers the subscriber with the publisher
  (getting a bounded queue, a status `TVar`, and an `unsubscribe` action), then
  spawns `runWorker` on an `async` thread wrapped in `finally unsubscribe`.
- `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` — `runWorker` and its
  helpers (`loadCheckpoint`, `catchUp`, `liveLoop`, `liveLoopCategoryDriven`,
  `fetchBatch`, `processEvents`, `saveCheckpoint`). This is the heart of the
  change.
- `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` — the
  `EventPublisher`. A single background thread waits for a `NOTIFY` tick (or a
  30-second safety poll), reads new `$all` events once with `readAllForwardStmt`,
  decodes them once, and **fans them out** to every registered subscriber's
  bounded `TBQueue`. It also keeps a `lastPublished :: TVar GlobalPosition`
  cursor (the highest position it has broadcast).
- `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` — `subscriptionStream`,
  a bridge that turns a subscription into a Streamly pull stream. It builds its
  own handler and writes events into a `TBQueue`; crucially it passes the rest of
  the caller's `SubscriptionConfig` through with record-update syntax (`config {
  handler = bridgeHandler }`), so any new config field rides along automatically.
- `kiroku-store/src/Kiroku/Store/Connection.hs` — `KirokuStore` holds `pool`
  (the `Hasql.Pool.Pool`), `publisher`, `eventHandler` (the optional
  `Maybe (KirokuEvent -> IO ())` observability callback), and `storeSettings`.
- `kiroku-store/src/Kiroku/Store/Observability.hs` — the `KirokuEvent` sum type
  and its enums (`SubscriptionDbPhase`, `SubscriptionStopReason`).
- `kiroku-store/src/Kiroku/Store/SQL.hs` — the existing prepared statements,
  including `readAllForwardStmt`, `readCategoryForwardStmt`, `getCheckpointStmt`,
  `saveCheckpointStmt`.

The worker runs in two phases. **Phase 1 (catch-up):** it loads its checkpoint
(`loadCheckpoint`, a single SQL read keyed by subscription name, defaulting to
position 0), then repeatedly fetches a batch from the database (`fetchBatch`,
which calls `readAllForwardStmt` for `AllStreams` or `readCategoryForwardStmt`
for a category), processes the batch through the handler (`processEvents`, which
saves a checkpoint at the batch tail when the handler returned `Continue` for the
whole batch, or at the stop event when the handler returned `Stop`), and loops
until its cursor reaches the publisher's `lastPublished`. **Phase 2 (live):** for
`AllStreams` it reads pre-broadcast batches from its bounded `TBQueue`
(`liveLoop`), filtering out any stale events at or below its cursor; for
`Category` it **bypasses the broadcast** and re-queries the database with
`readCategoryForwardStmt` every time `lastPublished` advances past its cursor
(`liveLoopCategoryDriven`). The reason category subscriptions re-query rather than
reading the queue is that the queue carries unfiltered `$all` events and there is
no in-process stream-to-category map to filter them with; the SQL filter at the
source is simpler and correct. **Delivery is at-least-once**: a crash or cancel
between handler call and checkpoint save replays the boundary events, so handlers
must be idempotent.

Important type detail: `runWorker` is typed in terms of the IO-specialized
`SubscriptionConfig` (= `SubscriptionConfigM IO`). `subscribe` is `MonadIO m =>
... -> m SubscriptionHandle` but `liftIO`s into IO and passes the
`SubscriptionConfig` through. The handler in the config runs in `IO`.

### Definitions of terms used in this plan

- **Member / member index**: a single worker in a group; its zero-based slot
  `m` with `0 <= m < N`.
- **Group size `N`**: the total number of members.
- **Partition assignment**: the deterministic stream-id → member mapping defined
  by EP-1's SQL (above). We never compute it in Haskell.
- **Checkpoint**: the persisted last-processed `GlobalPosition`, stored in the
  `subscriptions` table. Per-member checkpoints are keyed by
  `(subscription_name, consumer_group_member)`.
- **Publisher**: the single fan-out thread in `EventPublisher.hs`.
- **Broadcast queue**: the publisher's per-subscriber bounded `TBQueue` of
  unfiltered `$all` event batches.
- **Advisory lock**: a PostgreSQL application-level lock keyed by an integer; we
  use it only as an optional guard against two processes running the same member.


## Plan of Work

The work is four milestones. Each ends with a green build (`cabal build
kiroku-store`) and, from M2 on, passing tests (`cabal test kiroku-store`).

### Milestone M1 — Public types and validity enforcement (IP-4)

Scope: introduce the `ConsumerGroup` type, the `consumerGroup` config field, and
the validity check, without changing any runtime behavior. At the end of M1 the
package compiles, every existing caller compiles unchanged (because the new field
defaults to `Nothing`), and every existing test still passes. There is no
group-aware delivery yet — that is M2.

Edit `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`:

1. Add the type, exactly per IP-4:

```haskell
-- | Static consumer-group membership for a subscription.
data ConsumerGroup = ConsumerGroup
    { member :: !Int32  -- ^ 0-based member index; must satisfy 0 <= member < size
    , size   :: !Int32  -- ^ total members in the group; must be >= 1
    }
    deriving stock (Eq, Show)
```

2. Add the field to `SubscriptionConfigM m` (after `overflowPolicy`):

```haskell
    , consumerGroup :: !(Maybe ConsumerGroup)
    {- ^ 'Nothing' (the default) = ordinary single-consumer subscription.
       'Just cg' = this worker is member 'member cg' of a group of size
       'size cg'. The invariant @size >= 1@ and @0 <= member < size@ is
       enforced once at 'Kiroku.Store.Subscription.subscribe' time, which
       throws 'InvalidConsumerGroup' on violation. -}
    , consumerGroupGuard :: !Bool
    {- ^ When 'True' (default 'False'), the worker performs a one-shot
       PostgreSQL advisory-lock conflict check at startup so two processes
       cannot both run the same @(name, member)@ at once. See M4 for the
       exact semantics and its documented limitation. Ignored when
       'consumerGroup' is 'Nothing'. -}
```

3. In `defaultSubscriptionConfig`, set `consumerGroup = Nothing` and
   `consumerGroupGuard = False`.

4. Add and export the exception:

```haskell
{- | Thrown by 'Kiroku.Store.Subscription.subscribe' when a
'ConsumerGroup' violates @size >= 1@ or @0 <= member < size@. Carries the
offending values for diagnostics. -}
data InvalidConsumerGroup = InvalidConsumerGroup
    { invalidMember :: !Int32
    , invalidSize   :: !Int32
    }
    deriving stock (Show)
    deriving anyclass (Exception)
```

5. Add `ConsumerGroup (..)`, `InvalidConsumerGroup (..)`, and (for M4)
   `ConsumerGroupGuardConflict (..)` to the module export list.

Edit `kiroku-store/src/Kiroku/Store/Subscription.hs`: at the top of `subscribe`,
before registering with the publisher, validate the group:

```haskell
subscribe store config = liftIO $ do
    for_ (consumerGroup config) $ \(ConsumerGroup m n) ->
        when (n < 1 || m < 0 || m >= n) $
            throwIO (InvalidConsumerGroup m n)
    -- ... existing body unchanged ...
```

(Add imports `Control.Monad (when)`, `Data.Foldable (for_)`,
`Control.Exception (throwIO)` — `throwIO` is already imported transitively via
`Control.Exception (bracket, finally)`; add `throwIO` to that import list.)

Acceptance for M1: `cabal build kiroku-store` succeeds; `cabal test kiroku-store`
passes (the existing subscription tests in `kiroku-store/test/Main.hs` use
positional record syntax `SubscriptionConfig { name = ..., ..., overflowPolicy =
... }` — these will now fail to compile because the record gains two fields. **Fix
those call sites** by appending `, consumerGroup = Nothing, consumerGroupGuard =
False` to each literal, or, preferably, by leaving them as-is only if they use
`defaultSubscriptionConfig`. Inspect `kiroku-store/test/Main.hs`: the subscription
tests build the config with explicit record literals, so each must gain the two
new fields. This is mechanical and is the price of an explicit record.)

### Milestone M2 — Category group runtime + per-member checkpoint + first end-to-end test

Scope: make a `Category` consumer group actually work end-to-end. At the end of
M2, starting member `m` of an `N`-member category group reads only the streams
assigned to `m`, in order, and checkpoints under `(name, m)`. A new test proves
disjoint + complete + per-stream-ordered delivery for a size-4 category group, and
proves a size-1 group equals a plain subscription.

Edit `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`. The worker functions
all receive `SubscriptionConfig`, so they already have `consumerGroup config` in
scope. The changes are:

1. `fetchBatch`: branch on `consumerGroup config`. The function currently is:

```haskell
fetchBatch pool config (GlobalPosition pos) emit stSettings =
    case target config of
        AllStreams -> ... readAllForwardStmt ...
        Category (CategoryName cat) -> ... readCategoryForwardStmt ...
```

Change it to dispatch on the pair `(consumerGroup config, target config)`:

```haskell
fetchBatch pool config (GlobalPosition pos) emit stSettings =
    case (consumerGroup config, target config) of
        (Nothing, AllStreams) ->
            run (Session.statement (pos, batchSize config) SQL.readAllForwardStmt)
        (Nothing, Category (CategoryName cat)) ->
            run (Session.statement (pos, cat, batchSize config) SQL.readCategoryForwardStmt)
        (Just (ConsumerGroup m n), AllStreams) ->
            run (Session.statement (pos, m, n, batchSize config) SQL.readAllForwardConsumerGroupStmt)
        (Just (ConsumerGroup m n), Category (CategoryName cat)) ->
            run (Session.statement (pos, cat, m, n, batchSize config) SQL.readCategoryForwardConsumerGroupStmt)
  where
    run sess = do
        result <- Pool.use pool sess
        case result of
            Left err -> do
                emit (KirokuEventSubscriptionDbError (name config) FetchBatch err)
                pure V.empty
            Right events -> decodeEvents stSettings events
```

`catchUp` already calls `fetchBatch`, so catch-up automatically uses the
partitioned statement once `fetchBatch` does. No change to `catchUp` is needed
beyond what M3 adds for routing the live phase.

2. Per-member checkpoints. Define a small helper for "the member index for this
config" so non-group is member 0:

```haskell
configMember :: SubscriptionConfig -> Int32
configMember config = maybe 0 member (consumerGroup config)
```

Change `loadCheckpoint` to take the config (or the member) and call
`getCheckpointMemberStmt`:

```haskell
loadCheckpoint pool config emit = do
    let SubscriptionName name' = name config
        mem = configMember config
    result <- Pool.use pool (Session.statement (name', mem) SQL.getCheckpointMemberStmt)
    case result of
        Left err -> do
            emit (KirokuEventSubscriptionDbError (name config) LoadCheckpoint err)
            pure (GlobalPosition 0)
        Right Nothing -> pure (GlobalPosition 0)
        Right (Just pos) -> pure (GlobalPosition pos)
```

Change `saveCheckpoint` similarly to call `saveCheckpointMemberStmt` with `(name',
mem, pos)`. Update the `body`/`processEvents` call sites that pass
`(name config)` to `saveCheckpoint` so they pass `config` instead (or keep passing
`name config` plus the member; choose one signature and apply it consistently).
The simplest is to make both `loadCheckpoint` and `saveCheckpoint` take the full
`SubscriptionConfig`.

This satisfies the Decision Log entry "always use member-aware checkpoint
statements with member = 0 for non-group." The non-group worker now reads/writes
`(name, 0)`, which IP-3 guarantees is the same row it used before.

3. Live phase routing for category groups. In `runWorker`'s `body`, the `case
target config of` that chooses `liveLoop` vs `liveLoopCategoryDriven` must also
consider whether we are in a group. For M2 (category only) the change is: a
`Category` subscription — group or not — already uses `liveLoopCategoryDriven`,
and that function calls `fetchBatch`, which now partitions. So a category group's
live phase works with no further change. (M3 handles `$all` groups, which is where
the routing branch matters.)

Add the test module `kiroku-store/test/Test/ConsumerGroup.hs` (full content in
Concrete Steps), register it in `kiroku-store/kiroku-store.cabal` under the
test-suite `other-modules`, and import + call its `spec` from
`kiroku-store/test/Main.hs`.

Acceptance for M2: `cabal test kiroku-store` passes, including the new category
group end-to-end test and the size-1-equals-plain test.

### Milestone M3 — `$all` group runtime + observability member/size context

Scope: make `$all` consumer groups work, and add member/size context to the
lifecycle observability events. At the end of M3, a `Just`-group `AllStreams`
subscription routes through the DB-driven live loop with
`readAllForwardConsumerGroupStmt` (never the broadcast queue), and the lifecycle
events carry the member/size context. The checkpoint-resume test is added here.

Edit `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, `runWorker`'s `body`,
the live-phase selection:

```haskell
case (consumerGroup config, target config) of
    -- Non-group AllStreams: broadcast queue, exactly as today.
    (Nothing, AllStreams) ->
        liveLoop pool liveQueue statusVar config emit posRef finalPos
    -- Non-group Category: DB-driven, exactly as today.
    (Nothing, Category{}) ->
        liveLoopCategoryDriven pool config pubPosVar emit posRef finalPos stSettings
    -- Any group (Category or AllStreams): DB-driven partitioned live loop.
    -- A partitioned AllStreams group CANNOT use the broadcast TBQueue because
    -- that queue carries unfiltered $all events and there is no in-process
    -- stream-id -> member map to filter them with (mirrors the EP-3 F18
    -- rationale already documented for category subscriptions). The DB-driven
    -- loop re-queries with the partition predicate baked into the SQL.
    (Just _, _) ->
        liveLoopCategoryDriven pool config pubPosVar emit posRef finalPos stSettings
```

`liveLoopCategoryDriven` already calls `fetchBatch`, which already partitions for
both targets (M2). So no new live-loop function is needed; the existing DB-driven
loop serves all grouped subscriptions. Consider renaming
`liveLoopCategoryDriven` to `liveLoopDbDriven` to reflect its broadened role, and
update its Haddock comment; this is optional but clarifies intent. If renamed,
update both call sites.

Observability (IP-5). Edit `kiroku-store/src/Kiroku/Store/Observability.hs`:

1. Add the context type:

```haskell
-- | Consumer-group context attached to subscription lifecycle events.
data SubscriptionGroupContext
    = -- | Ordinary, non-grouped subscription.
      NonGroup
    | -- | Member of a group: @GroupMember member size@.
      GroupMember !Int32 !Int32
    deriving stock (Eq, Show)
```

2. Add a `!SubscriptionGroupContext` field to the four lifecycle constructors
   `KirokuEventSubscriptionDbError`, `KirokuEventSubscriptionStarted`,
   `KirokuEventSubscriptionCaughtUp`, `KirokuEventSubscriptionStopped`. Place the
   context as the last field of each so the existing leading fields keep their
   positions in `show` output as much as possible. Export
   `SubscriptionGroupContext (..)`.

3. In `kiroku-store/src/Kiroku/Store/Worker.hs` (the worker), compute the context
   once near the top of `runWorker`:

```haskell
let groupCtx = maybe NonGroup (\(ConsumerGroup m n) -> GroupMember m n) (consumerGroup config)
```

and pass `groupCtx` as the new trailing field to every `emit (KirokuEventSubscription* ...)`
call.

4. Update any pattern matches on these constructors elsewhere. The two known
   internal matchers are `caughtUpEventHandler` in
   `kiroku-store/test/Test/Helpers.hs` (matches
   `KirokuEventSubscriptionCaughtUp n _`) and `classifyStopReason`'s caller in the
   worker. `caughtUpEventHandler` uses a wildcard for the position so it just needs
   one more wildcard: `KirokuEventSubscriptionCaughtUp n _ _`. Grep for each
   constructor name across `kiroku-store/` and fix every match.

Add the checkpoint-resume test (member 2 stops after K, restarts, resumes from its
own checkpoint) to `kiroku-store/test/Test/ConsumerGroup.hs`. Add an `$all`-group
end-to-end case mirroring the category one but with `target = AllStreams` and
stream names spanning multiple categories.

Acceptance for M3: `cabal test kiroku-store` passes. Optionally add a small test
that installs an `eventHandler` and asserts a `KirokuEventSubscriptionStarted`
carries `GroupMember 2 4` for a member-2-of-4 subscription.

### Milestone M4 — Optional advisory-lock guardrail + Streamly bridge confirmation

Scope: add the opt-in startup advisory-lock conflict check and confirm the
Streamly bridge forwards the new config field. At the end of M4, a worker started
with `consumerGroupGuard = True` fails fast with `ConsumerGroupGuardConflict` if
another holder currently holds the member's advisory lock at startup, and
`subscriptionStream` is verified to pass `consumerGroup` through.

Add the conflict exception to `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`
(exported in M1's export list):

```haskell
{- | Thrown at subscription startup when 'consumerGroupGuard' is 'True' and
another holder currently holds the advisory lock for this @(name,
member)@. Indicates two processes are configured as the same group member.
See the Decision Log: this is a startup *detection* probe, not a
lifetime-held lock. -}
data ConsumerGroupGuardConflict = ConsumerGroupGuardConflict
    { conflictName   :: !SubscriptionName
    , conflictMember :: !Int32
    }
    deriving stock (Show)
    deriving anyclass (Exception)
```

Edit `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, in `runWorker`'s
`body`, before `loadCheckpoint`, when `consumerGroupGuard config` is `True` and
`consumerGroup config` is `Just`:

```haskell
checkpoint <- do
    case (consumerGroupGuard config, consumerGroup config) of
        (True, Just (ConsumerGroup m _)) -> guardMember pool (name config) m
        _ -> pure ()
    loadCheckpoint pool config emit
```

with the guard:

```haskell
-- Startup-only conflict probe. Uses a transaction-scoped advisory lock
-- (pg_try_advisory_xact_lock) which auto-releases at transaction end, so it
-- only detects a *concurrent* holder at this instant. The key is a stable
-- bigint hash of the (name, member) pair computed in SQL so all processes
-- agree. NOTE: this does NOT hold the lock for the worker's lifetime; full
-- mutual exclusion needs a session-level lock on a dedicated connection (the
-- Notifier pattern). That is recorded as follow-up in the plan's Decision Log.
guardMember :: Pool -> SubscriptionName -> Int32 -> IO ()
guardMember pool subName@(SubscriptionName n) mem = do
    let probe :: Statement (Text, Int32) Bool
        probe =
            preparable
                "SELECT pg_try_advisory_xact_lock(hashtextextended($1 || ':' || $2::text, 0))"
                ((fst >$< E.param (E.nonNullable E.text)) <> (snd >$< E.param (E.nonNullable E.int4)))
                (D.singleRow (D.column (D.nonNullable D.bool)))
    result <- Pool.use pool (Session.statement (n, mem) probe)
    case result of
        Right True -> pure ()       -- got the lock; no concurrent holder right now
        Right False -> throwIO (ConsumerGroupGuardConflict subName mem)
        Left _ -> pure ()            -- DB error: degrade open (do not block startup)
```

(Add imports to `Worker.hs`: `Hasql.Decoders qualified as D`,
`Hasql.Encoders qualified as E`, `Hasql.Statement (Statement, preparable)`,
`Data.Functor.Contravariant ((>$<))`.)

Because `pg_try_advisory_xact_lock` runs inside the implicit single-statement
transaction of one `Hasql.Session.statement`, the lock is released as soon as that
`Pool.use` returns — which is exactly the detection-only semantics we documented.
This is honest: it catches a simultaneous double-start but not a staggered one.

Streamly bridge. Read `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`. The
bridge builds `bridgeConfig = config { handler = bridgeHandler }` with record
update, which preserves every other field including the new `consumerGroup` and
`consumerGroupGuard`. So no code change is needed; M4 only adds a small smoke test
proving a grouped `subscriptionStream` delivers the partitioned subset (one member
of a size-2 group, asserting it receives a strict subset of the appended events).

Acceptance for M4: `just test` passes. If feasible without flakiness, a guard
test starts two member-3 workers and asserts at least one observes
`ConsumerGroupGuardConflict`; because the probe is racy by design, mark this test
as best-effort or assert the weaker property "starting a second member-3 with the
guard either succeeds or throws `ConsumerGroupGuardConflict`, never silently
double-processes within the same probe window." Prefer a deterministic unit-style
check: hold the xact lock open on a separate dedicated connection, then start a
guarded member with the same `(name, member)` and assert it throws.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless stated otherwise.

### Build after each edit

```bash
cabal build kiroku-store
```

Expected on success (abbreviated):

```text
Building library 'kiroku-store' ...
[ 1 of 1] Compiling Kiroku.Store.Subscription.Worker ...
Linking ...
```

### Run the test suite

```bash
cabal test kiroku-store
```

or, equivalently, via the project's task runner:

```bash
just test
```

`just test` runs `cabal test all`. The kiroku-store test suite uses an ephemeral
PostgreSQL (`EphemeralPg`), so no external database is required; the first run may
take longer while it initializes the temporary cluster.

### Register the new test module

Edit `kiroku-store/kiroku-store.cabal`, in the `test-suite kiroku-store-test`
stanza's `other-modules`, add `Test.ConsumerGroup`:

```text
  other-modules:
    Test.Causation
    Test.Concurrency
    Test.ConsumerGroup
    Test.FailureInjection
    Test.Helpers
    Test.InterpreterHooks
    Test.Properties
    Test.ReadStream
    Test.Transaction
```

Edit `kiroku-store/test/Main.hs`: add `import Test.ConsumerGroup qualified as
ConsumerGroup` near the other `Test.*` imports, and call `ConsumerGroup.spec` in
`main` alongside `Causation.spec`, `Concurrency.spec`, etc. (Those `spec`s are
called *outside* the `around withTestStore` block because, like
`Test.Concurrency`, the consumer-group spec manages its own store via
`withTestStore` internally.)

### The new test module

Create `kiroku-store/test/Test/ConsumerGroup.hs`. It uses the helper patterns from
`kiroku-store/test/Test/Helpers.hs`: `withTestStore` (brackets an ephemeral
Postgres and a `KirokuStore`), `makeEvent`, `runStoreIO` (re-exported from
`Kiroku.Store` via `Kiroku.Store.Effect`), `waitForPublisher`, and the
`subscribe` / `wait` / `cancel` lifecycle. Each member runs as one in-process
worker collecting `RecordedEvent`s into its own `IORef`, with a `Stop` condition
driven by a per-member expected count. The skeleton:

```haskell
module Test.ConsumerGroup (spec) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.IORef (newIORef, readIORef, modifyIORef')
import Data.Int (Int32)
import Data.List (sort)
import Data.Text qualified as T
import Data.Vector qualified as V
import Kiroku.Store
import Kiroku.Store.Subscription.Types (ConsumerGroup (..), SubscriptionConfigM (..))
import Test.Helpers
import Test.Hspec

-- Build a size-N category group config for member m that stops after it has
-- seen `expected` events (or never stops if expected is 0 — caller cancels).
memberConfig ::
    SubscriptionName -> CategoryName -> Int32 -> Int32 ->
    (RecordedEvent -> IO SubscriptionResult) -> SubscriptionConfig
memberConfig nm cat m n h =
    (defaultSubscriptionConfig nm (Category cat) h)
        { consumerGroup = Just (ConsumerGroup { member = m, size = n }) }

spec :: Spec
spec = describe "consumer groups" $ do
    it "delivers a disjoint, complete, per-stream-ordered partition (size-4 category group)" $
        withTestStore $ \store -> do
            -- Append a few events to each of 40 streams in category "acct".
            let streams = [ "acct-" <> T.pack (show i) | i <- [1 .. 40 :: Int] ]
            mapM_
                (\sn -> do
                    let evs = [ makeEvent ("E" <> T.pack (show k)) (Aeson.object []) | k <- [1 .. 3 :: Int] ]
                    Right _ <- runStoreIO store $ appendToStream (StreamName sn) NoStream evs
                    pure ())
                streams
            -- 40 streams * 3 events = 120 events; wait for the publisher.
            waitForPublisher store (GlobalPosition 120)

            -- Start one collector per member. Each collects (streamId, globalPosition).
            let n = 4 :: Int32
            refs <- mapM (const (newIORef [])) [0 .. n - 1]
            handles <-
                mapM
                    (\m -> do
                        let ref = refs !! fromIntegral m
                            h evt = do
                                modifyIORef' ref ((evt ^. #originalStreamId, evt ^. #globalPosition) :)
                                pure Continue
                            cfg = memberConfig (SubscriptionName "cg-cat") (CategoryName "acct") m n h
                        subscribe store cfg)
                    [0 .. n - 1]

            -- Let the members drain. Poll until the total collected reaches 120,
            -- with a timeout, then cancel all members.
            let drained = do
                    counts <- mapM (fmap length . readIORef) refs
                    pure (sum counts)
            waitUntil 10_000_000 (fmap (>= 120) drained)
            mapM_ cancel handles

            collected <- mapM readIORef refs
            -- (1) Disjoint + complete: union of all positions = [1..120], no dup.
            let allPositions = sort (concatMap (map snd) collected)
            map GlobalPosition [1 .. 120] `shouldBe` allPositions
            -- (2) Per-stream ordering within each member: for each streamId the
            -- positions appear in ascending order (collector prepended, so reverse).
            mapM_ (\pairs -> assertPerStreamAscending (reverse pairs)) collected

    it "size-1 group delivers the same set as a plain subscription" $
        withTestStore $ \store -> do
            -- ... append; run a plain subscription collecting positions; run a
            -- size-1 group collecting positions; assert the two sets are equal.
            pure ()

    it "resumes member 2 from its own checkpoint, not member 0's" $
        withTestStore $ \store -> do
            -- ... run member 2 of 4, Stop after K of its events; restart member 2;
            -- assert it resumes after its own saved position (the second run sees
            -- only member-2 events with position > the first run's last).
            pure ()

    it "$all group partitions the whole store across members" $
        withTestStore $ \store -> do
            -- ... like the category test but target = AllStreams and stream names
            -- spanning several categories.
            pure ()
```

Provide the small helpers used above in the same module:

```haskell
-- Poll an IO Bool predicate until True or the microsecond budget runs out.
waitUntil :: Int -> IO Bool -> IO ()
waitUntil budget act
    | budget <= 0 = pure ()
    | otherwise = do
        ok <- act
        if ok then pure () else do
            -- 20ms poll; deterministic enough for tests, bounded by waitForPublisher
            Control.Concurrent.threadDelay 20_000
            waitUntil (budget - 20_000) act

-- Assert that within each originalStreamId the globalPositions are ascending.
assertPerStreamAscending :: [(StreamId, GlobalPosition)] -> Expectation
assertPerStreamAscending pairs =
    let byStream = Data.Map.Strict.fromListWith (flip (++)) [ (sid, [gp]) | (sid, gp) <- pairs ]
    in mapM_ (\ps -> ps `shouldBe` sort ps) (Data.Map.Strict.elems byStream)
```

(Adjust imports: `Control.Concurrent (threadDelay)`,
`Data.Map.Strict qualified`, `Data.List (sort)`. Prefer reusing the existing
`waitWithTimeout`/`waitForPublisher` style; `waitUntil` is added here because the
group members do not all `Stop` on a single global count.)

Expected test output (abbreviated):

```text
consumer groups
  delivers a disjoint, complete, per-stream-ordered partition (size-4 category group) [✔]
  size-1 group delivers the same set as a plain subscription [✔]
  resumes member 2 from its own checkpoint, not member 0's [✔]
  $all group partitions the whole store across members [✔]

Finished in N.NNNN seconds
NN examples, 0 failures
```


## Validation and Acceptance

The change is validated by behavior, not just compilation.

**Disjoint + complete (the core guarantee).** The size-4 category test appends 120
events across 40 streams in category `acct`, runs four members, and asserts the
sorted union of every member's received global positions equals `[1..120]` exactly
— proving no event was delivered twice (a duplicate would make the multiset longer
than 120 or contain a repeat) and none was dropped (a gap would make a missing
position). Run it with:

```bash
cabal test kiroku-store
```

**Per-stream ordering.** For each member and each `originalStreamId` it received,
the test asserts the global positions for that stream are in ascending order. This
proves that even split across members, a single stream's events never arrive out
of order (they cannot, because all of one stream's events go to one member, and a
member processes in `global_position` order).

**Size-1 equivalence.** A separate test runs a plain (`consumerGroup = Nothing`)
subscription and a size-1 group over the same data and asserts identical received
sets. This is the IP-1 property "size-1 group equals non-partitioned subscription"
observed at the runtime layer (EP-1 proves it at the SQL layer).

**Per-member checkpoint resume.** The resume test runs member 2 of 4, stops it
after it has processed K of its assigned events (handler returns `Stop`),
restarts member 2 with the same name, and asserts the second run delivers only
member-2 events whose position is strictly greater than the first run's last
processed position. If checkpoints were keyed by name only (not by member), member
2's restart would resume from whatever member wrote last — the test would see
wrong/duplicate events and fail. This proves the `(name, member)` checkpoint key
is honored.

**Observability context.** A test installs an `eventHandler` (via
`withTestStoreSettings` setting `eventHandler`) and asserts that, for a member-2-
of-4 subscription, the captured `KirokuEventSubscriptionStarted` carries
`GroupMember 2 4`. This proves IP-5 threading.

**Streamly bridge.** A smoke test calls
`Kiroku.Store.Subscription.Stream.subscriptionStream` with a grouped config
(member 0 of 2) and asserts the pulled stream yields a strict subset of the
appended events (the member's partition), confirming the new field rides along the
bridge's `config { handler = ... }` record update.

**Guard (best-effort).** The advisory-lock test acquires the
`pg_advisory_lock`/`pg_try_advisory_xact_lock` key for `(name, member)` on a
separate dedicated connection held open, then starts a guarded worker for the same
`(name, member)` and asserts it throws `ConsumerGroupGuardConflict`. Because the
shipped guard is a startup probe (see Decision Log), the test exercises exactly the
detection it provides and does not claim lifetime exclusion.

A failure to compile after EP-1 has *not* landed is expected and is the signal that
the hard dependency is unmet — the four EP-1 statement names will be undefined.


## Idempotence and Recovery

Every step here is additive and safe to repeat. Re-running `cabal build` and
`cabal test` is idempotent. The new code paths do not run any DDL; the
`subscriptions`-table schema changes are owned and applied idempotently by EP-1.

At runtime, consumer-group delivery inherits the existing **at-least-once**
contract documented on `Kiroku.Store.Subscription.subscribe`: checkpoints advance
per batch, so a worker that is cancelled or crashes between a handler call and its
checkpoint save will replay the boundary events on restart. Handlers must be
idempotent. This is unchanged by partitioning — each member is just an ordinary
worker over a filtered slice, with its own `(name, member)` checkpoint.

The advisory-lock guard, when enabled, never blocks startup on a database error
(it degrades open: a `Left` result from the probe is treated as "no conflict
detected"), so a transient pool error cannot wedge a worker. Disabling the guard
(`consumerGroupGuard = False`, the default) removes the probe entirely.

If a milestone's tests fail, revert that milestone's edits (they are confined to
the files named in the Plan of Work) and re-run; no database cleanup is needed
because `withTestStore` uses a fresh ephemeral cluster per run.


## Interfaces and Dependencies

Libraries and modules used, and why:

- `Kiroku.Store.Subscription.Types` — owns the new public types (IP-4). Adds
  `ConsumerGroup`, the `consumerGroup` and `consumerGroupGuard` config fields,
  and the exceptions `InvalidConsumerGroup` and `ConsumerGroupGuardConflict`.
- `Kiroku.Store.Subscription` — enforces the validity invariant at `subscribe`.
- `Kiroku.Store.Subscription.Worker` — routes through the partitioned statements
  and per-member checkpoints; selects the DB-driven live loop for any group.
- `Kiroku.Store.SQL` — consumed (IP-2): the four EP-1 statements below.
- `Kiroku.Store.Observability` — extended (IP-5) with `SubscriptionGroupContext`.
- `Kiroku.Store.Subscription.Stream` — confirmed to forward the new field.
- `hasql`, `hasql-pool` — `Pool.use`, `Session.statement`, `Statement`,
  `Decoders`/`Encoders` for the guard probe.

Signatures that must exist at the end of each milestone (full module paths):

End of M1, in `Kiroku.Store.Subscription.Types`:

```haskell
data ConsumerGroup = ConsumerGroup { member :: !Int32, size :: !Int32 }
    deriving stock (Eq, Show)

-- new fields on SubscriptionConfigM m:
--   consumerGroup      :: !(Maybe ConsumerGroup)
--   consumerGroupGuard :: !Bool

data InvalidConsumerGroup = InvalidConsumerGroup
    { invalidMember :: !Int32, invalidSize :: !Int32 }
    deriving stock (Show) ; deriving anyclass (Exception)

defaultSubscriptionConfig
    :: SubscriptionName -> SubscriptionTarget -> EventHandlerM m -> SubscriptionConfigM m
    -- now also sets consumerGroup = Nothing, consumerGroupGuard = False
```

and in `Kiroku.Store.Subscription`:

```haskell
subscribe :: (MonadIO m) => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle
    -- throws InvalidConsumerGroup if the group is invalid, before spawning a thread
```

Consumed from `Kiroku.Store.SQL` (provided by EP-1,
`docs/plans/28-consumer-group-partition-routing-sql-and-checkpoint-schema.md`):

```haskell
readCategoryForwardConsumerGroupStmt
    :: Statement (Int64, Text, Int32, Int32, Int32) (Vector RecordedEvent)
readAllForwardConsumerGroupStmt
    :: Statement (Int64, Int32, Int32, Int32) (Vector RecordedEvent)
getCheckpointMemberStmt
    :: Statement (Text, Int32) (Maybe Int64)
saveCheckpointMemberStmt
    :: Statement (Text, Int32, Int64) ()
```

End of M2, in `Kiroku.Store.Subscription.Worker` (internal, but their shapes are
fixed by the call sites):

```haskell
configMember :: SubscriptionConfig -> Int32       -- maybe 0 member . consumerGroup
loadCheckpoint :: Pool -> SubscriptionConfig -> (KirokuEvent -> IO ()) -> IO GlobalPosition
saveCheckpoint :: Pool -> SubscriptionConfig -> GlobalPosition -> (KirokuEvent -> IO ()) -> IO ()
fetchBatch :: Pool -> SubscriptionConfig -> GlobalPosition -> (KirokuEvent -> IO ()) -> StoreSettings -> IO (Vector RecordedEvent)
```

End of M3, in `Kiroku.Store.Observability`:

```haskell
data SubscriptionGroupContext = NonGroup | GroupMember !Int32 !Int32
    deriving stock (Eq, Show)

-- KirokuEventSubscriptionStarted  !SubscriptionName !GlobalPosition !SubscriptionGroupContext
-- KirokuEventSubscriptionCaughtUp !SubscriptionName !GlobalPosition !SubscriptionGroupContext
-- KirokuEventSubscriptionStopped  !SubscriptionName !GlobalPosition !SubscriptionStopReason !SubscriptionGroupContext
-- KirokuEventSubscriptionDbError  !SubscriptionName !SubscriptionDbPhase !UsageError !SubscriptionGroupContext
```

End of M4, in `Kiroku.Store.Subscription.Types`:

```haskell
data ConsumerGroupGuardConflict = ConsumerGroupGuardConflict
    { conflictName :: !SubscriptionName, conflictMember :: !Int32 }
    deriving stock (Show) ; deriving anyclass (Exception)
```

and in `Kiroku.Store.Subscription.Worker`:

```haskell
guardMember :: Pool -> SubscriptionName -> Int32 -> IO ()
    -- pg_try_advisory_xact_lock probe; throws ConsumerGroupGuardConflict on a
    -- detected concurrent holder; degrades open on DB error.
```


## Revision History

- 2026-05-20: Initial authoring of the full ExecPlan body from the empty
  skeleton. Restated current subscription behavior self-contained; specified the
  four milestones (types/validity, category runtime + checkpoint + test, `$all`
  runtime + observability + resume test, advisory-lock guard + Streamly
  confirmation); recorded the local decisions (throw `InvalidConsumerGroup`;
  always member-aware checkpoints with member 0; DB-driven live loop for all
  groups; advisory-lock scoped to a startup `pg_try_advisory_xact_lock` probe with
  lifetime-held locking deferred; observability via a `SubscriptionGroupContext`
  field on the four lifecycle constructors). Reason: convert the placeholder into
  a self-contained, novice-followable plan honoring MasterPlan IP-2/IP-4/IP-5 and
  consuming EP-1's statements by exact signature.
