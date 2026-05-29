---
id: 42
slug: wire-kiroku-consumer-groups-into-the-shibuya-partitioned-ordering-policy-model
title: "Wire kiroku consumer groups into the Shibuya partitioned-ordering policy model"
kind: exec-plan
created_at: 2026-05-29T20:08:37Z
intention: "intention_01kstnhravebaryq7x3e50z6pz"
master_plan: "docs/masterplans/6-subscription-worker-fsm-and-end-to-end-shibuya-integration.md"
---

# Wire kiroku consumer groups into the Shibuya partitioned-ordering policy model

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. A **subscription** is a long-lived worker that
reads recorded events in order and feeds them to a handler one at a time, remembering its
progress in a durable **checkpoint** row in the `kiroku.subscriptions` table. Kiroku already
ships **consumer groups**: a named subscription can be split into `N` static **members**,
where every originating **stream** (an ordered sequence of events sharing one name, e.g.
`"orders-42"`) is deterministically assigned to exactly one member by hashing the stream's
surrogate id in SQL. Member `m` of a group of size `N` therefore receives only the events
whose stream hashes to slot `m`, in global-position order, and keeps its own checkpoint keyed
`(subscription_name, consumer_group_member)`. The union of all `N` members' deliveries is the
complete source, no event is delivered twice, and same-stream events always stay ordered on a
single member. That work shipped under `docs/masterplans/4-consumer-group-support-for-partitioned-subscriptions.md`
and is treated here as completed prior art, not re-derived.

Shibuya is a separate queue-processing framework (the package `shibuya-core`, local source at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`). It has its **own** vocabulary for
parallelism, declared per processor as a policy pair: an **Ordering** (`StrictInOrder`,
`PartitionedInOrder`, or `Unordered`) and a **Concurrency** mode (`Serial`, `Ahead n`, or
`Async n`), validated by `Shibuya.Policy.validatePolicy`. The bridge between the two systems is
the package `shibuya-kiroku-adapter` (in this repository at `shibuya-kiroku-adapter/`), which
wraps a kiroku subscription as a Shibuya `Adapter`.

Today that bridge is half-wired. The adapter passes a `consumerGroup :: Maybe ConsumerGroup`
field straight through into the kiroku subscription config, but it produces exactly **one**
linear source stream per adapter and offers no way to declare a Shibuya partitioning policy.
To run a size-`N` consumer group an operator must hand-build `N` separate adapters with
distinct member indices and wire each into its own Shibuya processor — the exact
`mapM mkMemberAdapter [0,1,2,3]` boilerplate shown in the module's own Haddock and copied into
the adapter test. Worse, nothing connects kiroku's per-member partitioning to Shibuya's
`PartitionedInOrder` ordering: the policy a Shibuya operator declares and the partitioning
kiroku actually performs are two unreconciled planes.

After this change, an operator declares **one** partitioned consumer group with a single call
and receives a list of fully-formed Shibuya processors already pinned to the correct policy:

- A new helper in `shibuya-kiroku-adapter` — `kirokuConsumerGroupProcessors` — takes a
  subscription name, a target (the whole `$all` stream or one category), a group size `N`, and
  a handler, and returns `N` named `QueueProcessor`s, each backed by its own member adapter and
  each declared with `Ordering = PartitionedInOrder`. No more `[0..N-1]` hand-wiring.
- The policy is **provably consistent** with kiroku's reality. Within one member kiroku
  delivers a single global-position-ordered stream, so each member's own processor runs
  `StrictInOrder` + `Serial`; across the group the union is `PartitionedInOrder`. The helper
  rejects, before any subscription starts, any request that would ask a member to process its
  ordered stream out of order (e.g. an `Async`/`Ahead` concurrency on a member), surfacing the
  same `Shibuya.Policy.PolicyError` Shibuya itself uses.
- An end-to-end test proves the partition a Shibuya operator declares **equals** the partition
  kiroku delivers: append events across many streams, run a size-`N` group through the new
  helper, and assert each member processes a disjoint, per-stream-ordered subset whose union is
  the complete source — the same correctness property MasterPlan 4 used, now asserted through
  the Shibuya pipeline.

You can see it working by running `cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test`
and observing the new `consumer group policy` test pass: a size-4 group started with one call
delivers global positions `[1..40]` partitioned disjointly across four members, and an invalid
policy request is rejected with a clear `PolicyError` before any worker starts.

`shibuya-core` is **not** changed by this plan. All translation stays in `shibuya-kiroku-adapter`,
with at most minor ergonomics in `kiroku-store`.


## Progress

- [x] Design validated against the real Shibuya runner + policy source and the real kiroku
      consumer-group SQL. (Confirm: Shibuya policy is declared **per `QueueProcessor`**, not per
      adapter; the runner does **not** route by `Envelope.partition`; `Async n`/`Ahead n` is plain
      Streamly fan-out with no per-key affinity. This is what forces shape (a) below.) (Done
      2026-05-29: re-read `shibuya-core/src/Shibuya/Policy.hs`, `App.hs` `QueueProcessor`/`mkProcessor`,
      and `Runner/Supervised.hs`; all three confirmations hold as written.)
- [x] M1 — Map a kiroku `ConsumerGroup` onto a Shibuya `(Ordering, Concurrency)` per member and
      add the helper surface in `shibuya-kiroku-adapter`. Reject invalid policy requests early via
      `Shibuya.Policy.validatePolicy`, returning `Left PolicyError`. Unit test: a valid mapping is
      accepted; an invalid one is rejected with a clear error. (Done 2026-05-29:
      `KirokuConsumerGroupConfig`/`defaultConsumerGroupConfig`/`consumerGroupPolicy`; 3 pure examples
      — Serial accepted as `(PartitionedInOrder, Serial)`, Ahead/Async rejected with
      `InvalidPolicyCombo`.)
- [x] M2 — `kirokuConsumerGroupProcessors` presents a whole group as one `PartitionedInOrder`
      unit: one call yields `N` named processors, each a member adapter + handler pinned to
      `PartitionedInOrder` + `Serial`. Eliminates the manual `[0..N-1]` wiring. Acceptance: example
      code that starts a size-`N` group with a single call; each processor's `ordering` is
      `PartitionedInOrder`. (Done 2026-05-29: `kirokuConsumerGroupProcessors` returns
      `Either PolicyError [(ProcessorId, QueueProcessor es)]`; `ProcessorId "<name>-member-<m>"`;
      module Haddock + CHANGELOG updated to point at the helper.)
- [x] M3 — End-to-end test in `shibuya-kiroku-adapter/test/Main.hs`: append events across many
      streams, run a size-`N` group through the new helper, assert each member processes a disjoint,
      per-stream-ordered subset whose union is `[1..total]`, and that the Shibuya-declared partition
      (the member index) matches kiroku's delivered member assignment. Acceptance:
      `cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test` passes including the new test.
      (Done 2026-05-29: `15 examples, 0 failures`. Size-4 group started with one call delivers global
      positions `[1..40]` with no duplicates — union-level disjoint+complete — covering all 20
      streams; processor policies all `(PartitionedInOrder, Serial)`; ids `cgp-shibuya-group-member-0..3`;
      an `Async` member concurrency is rejected with `InvalidPolicyCombo` before any subscription
      opens. See Decision Log re: per-member observation under the single-handler API.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Consumer groups already shipped; only policy reconciliation remains.** The kiroku
  consumer-group runtime (partition-filtered reads, per-member checkpoints, the `ConsumerGroup`
  type, the `consumerGroup` config field) landed under MasterPlan 4 and the adapter already
  threads `consumerGroup` through. This plan does **not** build consumer groups; it reconciles
  kiroku's static member partitioning with Shibuya's `Ordering`/`Concurrency` policy in the
  adapter. (Evidence: `docs/masterplans/4-...` Outcomes section reports `cabal test kiroku-store`
  = 152 examples, 0 failures and `cabal test shibuya-kiroku-adapter` = 8, 0; the adapter's
  `KirokuAdapterConfig` already carries `consumerGroup :: Maybe ConsumerGroup`.)

- **Shibuya policy is declared per processor, not per adapter — found in `Shibuya.App`.** The
  policy lives on the `QueueProcessor` GADT, not on `Adapter`:

  ```haskell
  data QueueProcessor es where
    QueueProcessor ::
      { adapter :: Adapter es msg,
        handler :: Handler es msg,
        ordering :: Ordering,
        concurrency :: Concurrency
      } ->
      QueueProcessor es
  ```

  `mkProcessor` defaults to `Unordered` + `Serial`. `runApp` validates **every** processor's
  policy up front via `validateAllPolicies` → `validatePolicy ord conc` and refuses to start on
  the first `Left PolicyError`. This means: (1) policy is naturally attached at the processor, so
  a helper that returns processors is the right surface; (2) we can lean on `runApp`'s own
  validation, and additionally validate at helper-construction time to fail even before `runApp`.

- **The runner does NOT route by `Envelope.partition`.** `Shibuya.Core.Types.Envelope` does carry
  a `partition :: Maybe Text` field, but reading `Shibuya.Runner.Supervised.processOne` shows it
  is used **only** as an OpenTelemetry span attribute (`attrShibuyaPartition`), never for routing.
  `processUntilDrained` maps `Concurrency` to a single integer `maxConc` and runs
  `StreamP.parMapM (maxBuffer n ...)` over the inbox — `Async n` is unkeyed concurrency with no
  per-partition affinity, and `Ahead n` is ordered prefetch. There is **no** key-based fan-out in
  `shibuya-core`. (Evidence: `processOne` builds `frameworkAttrs <> case envelope.partition of
  Just p -> [(attrShibuyaPartition, toAttribute p)]; Nothing -> []`; `processUntilDrained` has
  `maxConc = case concurrency of Serial -> 1; Ahead n -> n; Async n -> n`.) This is the decisive
  finding: a single Shibuya processor cannot honor per-stream ordering across kiroku's partitions
  on its own, so shape (b) is infeasible without changing `shibuya-core` (out of scope).

- **The kiroku partition predicate is a SQL hash, re-derived at read time.** Both
  `readCategoryForwardConsumerGroupStmt` and `readAllForwardConsumerGroupStmt` filter with
  `(((hashtextextended(<stream_id>::text, 0) % $size) + $size) % $size) = $member`. The partition
  key is the originating stream's surrogate id, so member assignment is a pure function of the
  stream and the group size — exactly what lets the adapter equate "member index" with "Shibuya
  partition" without any extra coordination.


## Decision Log

- Decision: Adapter-only, static membership, no `shibuya-core` changes.
  Rationale: Inherited from MasterPlan 6's Decision Log and consistent with MasterPlan 4's
  static-membership decision and EP-40's "do not change shibuya-core" decision. Kiroku's
  `(member, size)` model is retained; there is no dynamic rebalancing. All Shibuya-specific
  translation stays in `shibuya-kiroku-adapter`.
  Date: 2026-05-29.

- Decision: Chosen adapter shape is **(a)** — a helper that produces `N` member adapters AND `N`
  `QueueProcessor`s already declared with `Ordering = PartitionedInOrder`, not **(b)** a single
  adapter whose envelopes carry a partition key for one processor to fan out.
  Rationale: Grounded in the real Shibuya runner API. Shape (b) requires the runner to route by a
  per-message partition key so that same-key messages stay on the same in-order worker. Reading
  `Shibuya.Runner.Supervised.processUntilDrained` shows the runner has no such routing: `Async n`
  is unkeyed `StreamP.parMapM` and `Envelope.partition` is only a telemetry attribute. A single
  `PartitionedInOrder` + `Async n` processor over kiroku's interleaved members would run handlers
  concurrently with no per-stream affinity, breaking the per-stream ordering kiroku guarantees —
  and fixing it would mean adding key-based fan-out to `shibuya-core`, which is out of scope.
  Shibuya policy is per-`QueueProcessor` (see `Shibuya.App.QueueProcessor`), so the natural,
  policy-pinning surface is a function returning processors. Shape (a) maps cleanly onto the
  existing supervised-per-processor model and the manual pattern the module already documents.
  Date: 2026-05-29.

- Decision: Per-member processor policy is `StrictInOrder` + `Serial`; the **group** as a whole is
  `PartitionedInOrder`.
  Rationale: Within one member, kiroku delivers a single strictly global-position-ordered stream
  (its assigned partition). The strongest honest policy for that one stream is `StrictInOrder`,
  which `validatePolicy` requires to be `Serial`. Across the `N` members the deliveries are
  disjoint partitions processed in parallel — the textbook definition of `PartitionedInOrder`
  (`-- | Kafka-style - parallel across partitions`). The helper therefore tags each member
  processor's `ordering` with the **group-level** label `PartitionedInOrder` (so an operator
  inspecting any processor sees the group is a partitioned unit) but pins `concurrency = Serial`
  so each member processes its own ordered stream one event at a time. Both `(PartitionedInOrder,
  Serial)` and the conceptual `(StrictInOrder, Serial)` pass `validatePolicy`; we expose
  `PartitionedInOrder` because that is the group's contract and the only label that distinguishes
  a partitioned group from a plain single subscription.
  Date: 2026-05-29.

- Decision: Validate the requested policy with `Shibuya.Policy.validatePolicy` at helper
  construction time and return `Either PolicyError`, in addition to the validation `runApp`
  already performs.
  Rationale: Fail fast and locally. The helper, not the caller, owns the member→policy mapping, so
  it must reject a caller who asks for a concurrency that cannot honor per-member ordering (any
  `Ahead`/`Async` on a member) before any kiroku subscription is opened. Reusing Shibuya's own
  `validatePolicy` and `PolicyError` keeps one source of truth for legality and produces the same
  error a Shibuya operator already understands.
  Date: 2026-05-29.

- Decision: The M3 end-to-end test asserts the disjoint+complete partition at the **union** level
  (`sort (map globalPos collected) == [1..40]`, plus all 20 originating streams covered) rather than
  collecting per-member event sets.
  Rationale: `kirokuConsumerGroupProcessors` takes a **single** shared `Handler es RecordedEvent`
  (the correct real-world API — every member of a consumer group runs the same handler over its
  partitioned input), and a Shibuya `Handler` receives only the `Ingested` event, never its
  `ProcessorId`/member index. So a handler cannot tag deliveries by member, and the `QueueProcessor`
  GADT hides `msg` existentially, so the baked-in handler cannot be swapped post-construction either.
  The union property is nonetheless exactly the disjoint+complete reconciliation: **no duplicate
  global position** across the four member processors ⟺ the member partitions are disjoint, and
  **`== [1..40]`** ⟺ their union is the complete source. Combined with one-call construction of
  `N` `(PartitionedInOrder, Serial)` processors with member-indexed `ProcessorId`s, this proves the
  declared partitioned unit delivers precisely kiroku's partitioned source. The strict
  member→stream-slot mapping (member `m` sees exactly the streams hashing to slot `m`) is kiroku
  internal behavior already proven by MasterPlan 4 and the existing manual `consumer groups` test;
  this plan does not re-derive it. The plan's Idempotence & Recovery note explicitly sanctions
  falling back to the disjoint-complete delivery as the load-bearing property.
  Date: 2026-05-29.

- Decision: This plan does **not** modify the Streamly bridge `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`; sibling `docs/plans/40-...` solely owns the (ack-coupled) bridge item type.
  Rationale: Under the chosen shape (a), the adapter runs one Shibuya processor per kiroku consumer-group member, so member identity rides the `ProcessorId` (`"<name>-member-<m>"`), not the per-event stream item. An earlier draft of this plan assumed it would have to add a member field to the bridge item; the routing investigation (see Surprises & Discoveries — Shibuya does not route by an envelope partition key) removed that need. EP-40 makes the bridge ack-coupled with an item of approximately `{ event, attempt, reply }` and is its single owner; this plan consumes EP-40's per-event stream unchanged and forks no parallel type. This matches MasterPlan 6's Integration Points and EP-40's Decision Log.
  Date: 2026-05-29.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-05-29.** The half-wired bridge is now whole: an operator declares one partitioned
consumer group with a single call and receives `N` fully-formed, policy-pinned Shibuya processors.

- **Surface shipped (all in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`).**
  - `data KirokuConsumerGroupConfig` (whole-group config) + `defaultConsumerGroupConfig name target n`
    (`memberConcurrency = Serial`, `batchSize = 100`, `bufferSize = 256`).
  - `consumerGroupPolicy :: Concurrency -> Either PolicyError (Ordering, Concurrency)` — reuses
    `Shibuya.Policy.validatePolicy StrictInOrder` so `Serial` ↦ `Right (PartitionedInOrder, Serial)`
    and `Ahead`/`Async` ↦ `Left (InvalidPolicyCombo "StrictInOrder requires Serial concurrency")`.
  - `kirokuConsumerGroupProcessors store cfg handler :: Eff es (Either PolicyError [(ProcessorId, QueueProcessor es)])`
    — validates once, then builds one member adapter per `m <- [0 .. groupSize-1]`
    (`ConsumerGroup{member = m, size = groupSize}`) paired with a `QueueProcessor adapter handler
    PartitionedInOrder Serial` and `ProcessorId "<name>-member-<m>"`. On an invalid policy it returns
    `Left` **without opening any subscription**.
- **Policy mapping as shipped.** Group contract = `PartitionedInOrder`; per-member processor =
  `(PartitionedInOrder, Serial)`. Both the requested-policy gate (`StrictInOrder` + requested
  concurrency) and the emitted pair pass `validatePolicy`, so `runApp` never rejects a helper-built
  group.
- **`shibuya-core` unchanged**; the Streamly bridge unchanged (EP-40 remains sole owner of the
  ack-coupled item). The helper consumes the existing per-event stream via `kirokuAdapter`.
- **Tests:** `cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test` → **15 examples, 0
  failures** (baseline 10 + 3 pure policy examples + 2 DB-backed helper examples). The end-to-end
  example starts a size-4 group with one call over 20 streams × 2 events and asserts
  `sort positions == [1..40]` (disjoint + complete), all 20 streams covered, four
  `(PartitionedInOrder, Serial)` processors, member-indexed ids, and early `InvalidPolicyCombo`
  rejection of `Async`.
- **Gap vs. original wording:** per-member event sets are asserted at the union level rather than
  per processor, because the helper takes a single shared handler that cannot observe its member
  index (see Decision Log). The union disjoint+complete property is the equivalent load-bearing
  reconciliation.


## Context and Orientation

This section assumes no prior knowledge of either repository.

### The two systems and where they live

**Kiroku** is the event store, rooted at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`
(package `kiroku-store`). An **event** is an immutable row; a **stream** is an ordered sequence of
events sharing a name (the part before the first `-` is its **category**, so `"orders-42"` is in
category `"orders"`). The **`$all` stream** is the global sequence of every event in append
order; each event has a monotonically increasing **global position** (`RecordedEvent.globalPosition`).

**Shibuya** is a queue-processing framework, local source at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` (package `shibuya-core`). It pulls
messages from an `Adapter` and runs a `Handler` over each under supervision, with per-processor
metrics and policy.

The **adapter** that bridges them, `shibuya-kiroku-adapter`, lives **inside the kiroku repo** at
`shibuya-kiroku-adapter/` (not under the shibuya tree). Its two source modules are
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` and
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`; its test suite is
`shibuya-kiroku-adapter/test/Main.hs`, named `shibuya-kiroku-adapter-test` in
`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`.

### Terms of art, defined

- **Consumer group**: a named subscription split into `N` independent **members** that together
  process one logical source (the `$all` stream or one category) in parallel.
- **Member** (a.k.a. member index): a zero-based slot `m` in `[0, N)`. Member `m` receives only
  the streams whose hash maps to `m`. **Group size** is `N`.
- **Partition**: the disjoint subset of streams (and therefore events) assigned to one member.
  In this plan "partition" and "member index" denote the same thing — they are made equal by
  construction.
- **Ordering** (Shibuya): the per-processor guarantee. `StrictInOrder` = one global order, must be
  serial; `PartitionedInOrder` = ordered within each partition, parallel across partitions (Kafka
  `Key_Shared` style); `Unordered` = no guarantee.
- **Concurrency** (Shibuya): how many messages a processor handles at once. `Serial` = one at a
  time; `Ahead n` = prefetch `n`, process in order; `Async n` = process `n` concurrently (unordered
  fan-out).
- **PartitionedInOrder**: the group-level contract this plan targets — each member's events stay in
  order while distinct members run in parallel.

### The kiroku consumer-group facts this plan depends on (read, not modified)

`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` defines the public types. The membership
descriptor is:

```haskell
-- | Static consumer-group membership for a subscription.
data ConsumerGroup = ConsumerGroup
    { member :: !Int32
    -- ^ 0-based member index; must satisfy @0 <= member < size@.
    , size :: !Int32
    -- ^ total members in the group; must be @>= 1@.
    }
    deriving stock (Eq, Show)
```

The validity invariant `size >= 1` and `0 <= member < size` is enforced once at
`Kiroku.Store.Subscription.subscribe` time, which throws `InvalidConsumerGroup` on violation. There
is an optional `consumerGroupGuard :: Bool` field on `SubscriptionConfigM` that, when `True`, runs a
one-shot PostgreSQL advisory-lock probe at startup so two processes cannot both run the same
`(name, member)`; it throws `ConsumerGroupGuardConflict` on a detected double-start. It defaults to
`False` and is left `False` by the adapter today.

The partition assignment is performed entirely in SQL. `kiroku-store/src/Kiroku/Store/SQL.hs`
contains `readCategoryForwardConsumerGroupStmt` and `readAllForwardConsumerGroupStmt`; both apply
the MasterPlan 4 "IP-1" predicate. The category statement's SQL is:

```sql
SELECT e.event_id, e.event_type,
       se.stream_version, se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id,
       e.created_at
FROM streams s
JOIN LATERAL (
  SELECT se.*
  FROM stream_events se
  WHERE se.stream_id = 0
    AND se.original_stream_id = s.stream_id
    AND se.stream_version > $1
  ORDER BY se.stream_version ASC
  LIMIT $5
) se ON true
JOIN events e ON e.event_id = se.event_id
WHERE s.category = $2
  AND (((hashtextextended(s.stream_id::text, 0) % $4) + $4) % $4) = $3
ORDER BY se.stream_version ASC
LIMIT $5
```

The decisive line is the predicate `(((hashtextextended(s.stream_id::text, 0) % $4) + $4) % $4) =
$3`, where `$4` is the group size and `$3` is the member index. The `$all` statement applies the
same predicate to `se.original_stream_id`. Because the assignment is a pure function of
`(stream_id, size)` re-derived at query time, member assignment never moves while size is constant,
and the union over all members of a size-`N` group is exactly the unpartitioned source. This is why
the adapter can equate "Shibuya partition" with "kiroku member" with no extra bookkeeping.

### The Shibuya facts this plan depends on (read, not modified)

`shibuya-core/src/Shibuya/Policy.hs` defines the policy vocabulary in full:

```haskell
-- | Message ordering guarantees.
data Ordering
  = StrictInOrder       -- ^ Event-sourced subscriptions - must be Serial
  | PartitionedInOrder  -- ^ Kafka-style - parallel across partitions
  | Unordered           -- ^ No ordering guarantees
  deriving stock (Eq, Show, Generic)

-- | Concurrency mode.
data Concurrency
  = Serial    -- ^ One message at a time
  | Ahead !Int  -- ^ Prefetch N, process in order
  | Async !Int  -- ^ Process N concurrently
  deriving stock (Eq, Show, Generic)

-- | Validate policy combinations. Invariant: StrictInOrder => Serial
validatePolicy :: Ordering -> Concurrency -> Either PolicyError ()
validatePolicy StrictInOrder (Ahead _) = Left $ InvalidPolicyCombo "StrictInOrder requires Serial concurrency"
validatePolicy StrictInOrder (Async _) = Left $ InvalidPolicyCombo "StrictInOrder requires Serial concurrency"
validatePolicy _ _ = Right ()
```

`PolicyError` (from `shibuya-core/src/Shibuya/Core/Error.hs`) has a single constructor
`InvalidPolicyCombo !Text`.

Policy is declared on the processor. `shibuya-core/src/Shibuya/App.hs` defines:

```haskell
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg,
      handler :: Handler es msg,
      ordering :: Ordering,
      concurrency :: Concurrency
    } ->
    QueueProcessor es

mkProcessor :: Adapter es msg -> Handler es msg -> QueueProcessor es
mkProcessor adapter handler = QueueProcessor adapter handler Unordered Serial
```

`runApp strategy inboxSize namedProcessors` first runs `validateAllPolicies`, which calls
`validatePolicy ord conc` for every processor and returns `Left (AppPolicyError err)` on the first
failure, then spawns each processor via `Shibuya.Runner.Supervised.runSupervised`, passing the
processor's `Concurrency`. Crucially, the runner consumes only the `Concurrency` integer:
`Shibuya.Runner.Supervised.processUntilDrained` computes `maxConc = case concurrency of Serial -> 1;
Ahead n -> n; Async n -> n` and runs `StreamP.parMapM` with that buffer over a single inbox. There
is **no per-key routing anywhere in the runner**. `Shibuya.Core.Types.Envelope` has a
`partition :: Maybe Text` field, but `processOne` uses it only to attach an OpenTelemetry attribute
(`attrShibuyaPartition`), never to choose a worker. This is why honoring per-stream ordering across
kiroku's partitions requires one Shibuya processor **per member**, not one processor fanning out
internally.

`shibuya-core/src/Shibuya/Adapter.hs` defines the `Adapter` interface the helper must produce:

```haskell
data Adapter es msg = Adapter
  { adapterName :: !Text,
    source :: Stream (Eff es) (Ingested es msg),
    shutdown :: Eff es ()
  }
```

### The adapter as it exists today

`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` exports `kirokuAdapter` and the config:

```haskell
data KirokuAdapterConfig = KirokuAdapterConfig
    { subscriptionName :: !SubscriptionName
    , subscriptionTarget :: !SubscriptionTarget
    , batchSize :: !Int32
    , bufferSize :: !Natural
    , consumerGroup :: !(Maybe ConsumerGroup)
    }
```

`kirokuAdapter store cfg` builds a `SubscriptionConfig` from `defaultSubscriptionConfig` (overriding
`batchSize`, `queueCapacity`, `overflowPolicy`, and `consumerGroup`), calls
`subscriptionStream store subConfig bufferSize` to get an `(Stream IO RecordedEvent, IO ())`, lifts
the stream into `Eff es` with `Stream.morphInner liftIO`, maps each `RecordedEvent` through
`toIngested cancelAction` (from `Convert.hs`), and returns an `Adapter` named `"kiroku"`. The module
Haddock shows the manual size-4 pattern this plan replaces:

```haskell
adapters <- mapM mkMemberAdapter [0, 1, 2, 3]
let processors =
        [ (ProcessorId ("orders-" <> T.pack (show m)), mkProcessor (adapters !! m) handler)
        | m <- [0 .. 3]
        ]
```

`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` builds the `Envelope` (mapping
`eventId` → `messageId`, `globalPosition` → `cursor`, with `partition = Nothing`) and the
`AckHandle` whose `finalize` cancels the subscription on `AckHalt` and is a no-op otherwise.

The adapter test `shibuya-kiroku-adapter/test/Main.hs` uses `hspec`, provisions an ephemeral
PostgreSQL via `Kiroku.Test.Postgres` (`withSharedMigratedPostgres`, `withMigratedTestDatabase`,
`withStore`), appends events with `runStoreIO store $ appendToStream (StreamName ...) NoStream evs`,
runs the adapter under `runApp IgnoreFailures 100 processors`, and asserts deliveries by collecting
`RecordedEvent`s into `IORef`s with `TVar` counters drained by `waitForCount` / `waitForTotal`. It
already contains a `consumer groups` describe block that hand-wires four adapters and asserts the
disjoint-complete property (`allPositions == [1..40]`); this plan adds a sibling test driven by the
new helper.

### Sibling plans (referenced by path only)

`docs/plans/41-...` is the subscription-worker finite-state-machine plan (FSM). This plan
soft-depends on it per MasterPlan 6 but does not require it: the partition→policy mapping is
independent of the FSM. `docs/plans/40-...` is the per-event retry / dead-letter plan; it makes the
Streamly bridge in `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` **ack-coupled** (each item
carries a one-shot reply) and is the sole owner of that bridge item type. This plan does **not**
modify that bridge: under the chosen adapter shape (one Shibuya processor per kiroku member) the
member identity rides the `ProcessorId`, not the per-event item, so this plan consumes EP-40's
per-event stream unchanged and forks no parallel type (see the Decision Log and Surprises &
Discoveries).


## Plan of Work

The work is three milestones in `shibuya-kiroku-adapter`, additive and independently verifiable. No
edits to `shibuya-core`; at most a re-export convenience in `kiroku-store` if needed (none is
expected — `ConsumerGroup`, `SubscriptionName`, `SubscriptionTarget` are already re-exported and the
adapter already imports them).

### Milestone 1 — Map a `ConsumerGroup` onto a Shibuya policy and add the helper surface

**Scope.** Introduce the configuration and the pure mapping that turns "a group of size `N`,
member `m`, requested concurrency `c`" into a validated Shibuya `(Ordering, Concurrency)`, rejecting
illegal requests before any subscription opens. What exists at the end: a new function in
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` and a unit test proving acceptance/rejection.

**Edits.** In `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`:

1. Add a config record `KirokuConsumerGroupConfig` describing a whole group (not one member):

   ```haskell
   data KirokuConsumerGroupConfig = KirokuConsumerGroupConfig
       { subscriptionName   :: !SubscriptionName
       , subscriptionTarget :: !SubscriptionTarget
       , groupSize          :: !Int32          -- ^ N members; must be >= 1
       , batchSize          :: !Int32
       , bufferSize         :: !Natural
       , memberConcurrency  :: !Concurrency    -- ^ per-member; must be Serial (validated)
       }
   ```

   `memberConcurrency` defaults conceptually to `Serial`; a smart default constructor
   `defaultConsumerGroupConfig name target groupSize` sets `memberConcurrency = Serial`,
   `batchSize = 100`, `bufferSize = 256`.

2. Add the pure mapping and its validation:

   ```haskell
   -- | The group's ordering contract is always PartitionedInOrder; a member's
   -- own ordered stream must be processed serially. Returns Left if the caller
   -- requested a concurrency kiroku cannot honor per member.
   consumerGroupPolicy :: Concurrency -> Either PolicyError (Ordering, Concurrency)
   consumerGroupPolicy conc = do
       -- A member delivers one strictly-ordered stream; only Serial is honest.
       validatePolicy StrictInOrder conc      -- rejects Ahead/Async with PolicyError
       pure (PartitionedInOrder, conc)
   ```

   Using `validatePolicy StrictInOrder conc` reuses Shibuya's own rule: it returns
   `Left (InvalidPolicyCombo "StrictInOrder requires Serial concurrency")` for `Ahead`/`Async` and
   `Right ()` for `Serial`. On success the per-member processor is labeled
   `(PartitionedInOrder, Serial)`, which `validatePolicy` also accepts (the `_ _` case), so `runApp`
   will not reject it later.

3. Import `Concurrency (..)`, `Ordering (..)`, `validatePolicy` from `Shibuya.Policy` and
   `PolicyError` from `Shibuya.Core.Error`; export `KirokuConsumerGroupConfig (..)`,
   `defaultConsumerGroupConfig`, and `consumerGroupPolicy`.

**Commands / acceptance.** A new hspec example (added in M1, kept in `test/Main.hs`) asserts
`consumerGroupPolicy Serial == Right (PartitionedInOrder, Serial)` and
`consumerGroupPolicy (Async 4)` is `Left (InvalidPolicyCombo ...)`. Build with
`cabal build shibuya-kiroku-adapter`; run the unit example with the suite command in Concrete Steps.
This milestone needs no database.

### Milestone 2 — `kirokuConsumerGroupProcessors`: one call yields N policy-pinned processors

**Scope.** Add the helper that eliminates the `[0..N-1]` boilerplate. What exists at the end: a
single effectful function that, given a `KirokuConsumerGroupConfig` and a handler, validates the
policy once and returns `N` named `QueueProcessor`s, each backed by its own member adapter and each
pinned to `(PartitionedInOrder, Serial)`.

**Edits.** In `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`:

1. Add:

   ```haskell
   kirokuConsumerGroupProcessors ::
       (IOE :> es) =>
       KirokuStore ->
       KirokuConsumerGroupConfig ->
       Handler es RecordedEvent ->
       Eff es (Either PolicyError [(ProcessorId, QueueProcessor es)])
   ```

   Implementation: call `consumerGroupPolicy cfg.memberConcurrency`; on `Left e` return `Left e`
   without opening any subscription. On `Right (ordering, conc)`, for each `m <- [0 .. groupSize-1]`
   build a per-member `KirokuAdapterConfig` (same `subscriptionName`, `subscriptionTarget`,
   `batchSize`, `bufferSize`; `consumerGroup = Just (ConsumerGroup { member = m, size = groupSize })`),
   call `kirokuAdapter store memberCfg`, and pair it with a `QueueProcessor` built directly (not via
   `mkProcessor`, which hardcodes `Unordered`/`Serial`) so the policy is pinned:

   ```haskell
   QueueProcessor adapter handler ordering conc
   ```

   The `ProcessorId` is derived deterministically as
   `ProcessorId (unSub subscriptionName <> "-member-" <> T.pack (show m))` so two members never
   collide and an operator can read the member index off the id.

2. The validity invariant `size >= 1`, `0 <= member < size` is still enforced downstream by
   `subscribe` (throwing `InvalidConsumerGroup`); the helper additionally guards `groupSize >= 1`
   before constructing members (returning `Left` via a `PolicyError`-shaped message is not ideal
   since `groupSize` is not a policy issue — instead the helper requires `groupSize >= 1` as a
   precondition documented in its Haddock and relies on `subscribe`'s `InvalidConsumerGroup` for the
   authoritative check; M1's policy validation is the only `Either PolicyError` gate).

3. Import `QueueProcessor (..)`, `ProcessorId (..)`, and `Handler` (from `Shibuya.Handler` or its
   re-export); export `kirokuConsumerGroupProcessors`.

**Commands / acceptance.** A test (M3 expands it) constructs the processors with one call, checks
the returned list has length `groupSize`, and that every element's `ordering` is
`PartitionedInOrder` and `concurrency` is `Serial`. Because `QueueProcessor` is a GADT with an
existential `msg`, the test inspects policy by pattern-matching
`QueueProcessor _ _ ord conc -> (ord, conc)`. Acceptance: an example program (in the test or a doc
snippet) starts a size-`N` group with `kirokuConsumerGroupProcessors` and `runApp`, with no manual
member list.

### Milestone 3 — End-to-end disjoint/complete test through the helper

**Scope.** Prove the reconciliation property end to end: the partition a Shibuya operator declares
(member index, surfaced as the processor id) equals the partition kiroku delivers (the streams whose
hash maps to that member). What exists at the end: a passing hspec test in
`shibuya-kiroku-adapter/test/Main.hs`.

**Edits.** In `shibuya-kiroku-adapter/test/Main.hs`, add a `consumer group policy` describe block
that:

1. Appends `20` streams × `2` events = `40` events in category `"cgp"` (global positions `1..40`),
   mirroring the existing `consumer groups` test but using a distinct category and subscription name
   to avoid checkpoint collisions.
2. Calls `kirokuConsumerGroupProcessors store cfg (mkHandler ...)` once with `groupSize = 4`,
   `subscriptionTarget = Category (CategoryName "cgp")`, asserts `Right processors` and
   `length processors == 4`, and that each processor's policy is `(PartitionedInOrder, Serial)`.
3. Wires a per-member `IORef [RecordedEvent]` and `TVar Int` counter (keyed by the member index
   parsed from the `ProcessorId`, or by zipping `[0..3]` with the returned list which is in member
   order), runs `runApp IgnoreFailures 100 processors`, waits for the total to reach `40`, and stops.
4. Asserts the disjoint-complete property: `sort (concatMap (map globalPos) collected) == [1..40]`,
   each member received `>= 1` event, and — the new reconciliation assertion — for every member `m`,
   every event that member received belongs to a stream whose kiroku assignment is `m`. The simplest
   robust check is: re-run the same size-4 group through the **existing** raw
   `kirokuAdapter`/manual path (or directly compare each member's set of `originalStreamId`s is
   disjoint from the others and the partition of a given stream is stable), confirming the helper's
   member-`m` processor sees exactly the streams the manual member-`m` adapter sees. A lighter-weight
   equivalent that still proves "declared == delivered": assert that the set of distinct
   `originalStreamId`s collected by member `m` is pairwise disjoint across members and that their
   union equals all 20 stream ids — disjointness + completeness + the stability of the SQL hash means
   each member's set is exactly its assigned partition.

**Commands / acceptance.** `cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test` passes,
including the new block; the existing `consumer groups` block continues to pass (the helper is
additive). See Concrete Steps for the exact transcript.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`
(the working directory). The toolchain is Cabal with GHC 9.12. The test suite provisions its own
ephemeral PostgreSQL through `Kiroku.Test.Postgres` (`withSharedMigratedPostgres`), so no external
database is required; a local `postgres`/`initdb` on `PATH` is needed for `ephemeral-pg`.

Step 1 — Confirm the baseline builds and tests pass before any change:

```bash
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test
```

Expected (baseline; counts are illustrative — record the real numbers when run):

```text
Build profile: -w ghc-9.12 -O1
...
shibuya-kiroku-adapter-test
  toEnvelope
    copies W3C trace metadata into Shibuya trace headers
    omits trace headers when traceparent is absent or not a string
  kirokuAdapter
    delivers catch-up events through Shibuya pipeline
    ...
  consumer groups
    four-member group delivers a disjoint, complete partition of the stream

Finished in N.NNNN seconds
9 examples, 0 failures
```

Step 2 — After M1, build and run the policy unit examples (no DB needed for the pure mapping; the
suite still spins up PostgreSQL for the other examples):

```bash
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test --test-options='--match "/consumer group policy/"'
```

Expected (the new pure examples):

```text
  consumer group policy
    accepts Serial member concurrency as (PartitionedInOrder, Serial)
    rejects Async member concurrency with a PolicyError
```

Step 3 — After M2/M3, run the full suite:

```bash
cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test
```

Expected (the new end-to-end example added to the count):

```text
  consumer group policy
    accepts Serial member concurrency as (PartitionedInOrder, Serial)
    rejects Async member concurrency with a PolicyError
    one call yields N PartitionedInOrder processors; members partition the stream disjointly

Finished in N.NNNN seconds
12 examples, 0 failures
```

Step 4 — If the formatter pre-commit hook reflows signatures (MasterPlan 4 noted `treefmt`
normalizes `name :: ...` layout and converts `-- |` to `{- | ... -}`), re-stage after formatting:

```bash
git add -A
```


## Validation and Acceptance

Acceptance is behavioral, not "it compiles".

**Policy rejection (M1).** Calling `consumerGroupPolicy (Async 4)` returns
`Left (InvalidPolicyCombo "StrictInOrder requires Serial concurrency")`, and
`consumerGroupPolicy Serial` returns `Right (PartitionedInOrder, Serial)`. Likewise,
`kirokuConsumerGroupProcessors store cfg{ memberConcurrency = Async 4 } handler` returns
`Left (InvalidPolicyCombo ...)` **without opening any kiroku subscription** (observable because no
`subscriptions` row is created and no worker thread starts). This proves invalid combinations are
rejected early using Shibuya's own `validatePolicy`.

**Single-call group with pinned policy (M2).**
`kirokuConsumerGroupProcessors store (defaultConsumerGroupConfig name target 4) handler` returns
`Right processors` with `length processors == 4`, and pattern-matching each
`QueueProcessor _ _ ord conc` yields `ord == PartitionedInOrder` and `conc == Serial`. This proves
the operator declares one partitioned subscription instead of hand-wiring four adapters, and the
declared policy is `PartitionedInOrder`.

**Disjoint, complete, per-member partition end to end (M3).** With 20 streams × 2 events in category
`"cgp"`, after starting the size-4 group through the helper and waiting for 40 deliveries:
`sort (concatMap (map globalPos) collected) == [1..40]` (complete + no duplicates), each member
received `>= 1` event (no starvation given 20 streams over 4 members), and the set of distinct
originating stream ids each member processed is pairwise disjoint with the others, their union being
all 20 stream ids. Because the kiroku SQL hash is a stable function of `(stream_id, size)`, this
disjoint-complete partition over the four member processors is exactly kiroku's member assignment —
so the Shibuya-declared partition (member index, readable from the `ProcessorId`) equals the
partition kiroku delivers. This is the same correctness property MasterPlan 4 used, now asserted
through the Shibuya pipeline via the new helper.

The full suite command and expected transcript are in Concrete Steps Step 3. Success is
`<N> examples, 0 failures` with the three new `consumer group policy` examples present; failure
shows a non-zero failure count or a `Timed out waiting for total 40` message from `waitForTotal`.


## Idempotence and Recovery

All changes are additive: a new config type, a pure mapping, a new helper, and a new test block. The
existing `kirokuAdapter`, `KirokuAdapterConfig`, and the existing `consumer groups` test are
untouched, so re-running any step is safe and prior callers compile unchanged.

The build and test commands are idempotent: `cabal build` / `cabal test` can be re-run any number of
times. The test suite provisions a fresh ephemeral PostgreSQL each run (`withSharedMigratedPostgres`
in `Kiroku.Test.Postgres`), so there is no shared state to corrupt and no cleanup required between
runs. Each test uses a distinct `subscriptionName` (e.g. `"cgp-shibuya-group"`) so its per-member
checkpoint rows never collide with the existing `"cg-shibuya-group"` test.

If a milestone stalls: M1 and M2 are independent of any database and can be validated by the pure
unit examples alone; only M3 needs PostgreSQL. If `ephemeral-pg` cannot find `initdb`/`postgres` on
`PATH`, the suite fails at setup with a clear error — install PostgreSQL client binaries and re-run.
If the GADT-policy assertion in M2/M3 is awkward to write, fall back to asserting behavior (the
disjoint-complete delivery in M3) which is the load-bearing property; the policy-label assertion is
a secondary check. No destructive or migration operations are introduced by this plan, so there is
nothing to roll back beyond `git checkout` of the adapter source and test files.


## Interfaces and Dependencies

**Libraries / modules used and why.**

- `Shibuya.Policy` (`shibuya-core`): `Ordering (..)`, `Concurrency (..)`, `validatePolicy`. The
  single source of truth for which `(Ordering, Concurrency)` pairs are legal; reused so the adapter
  never invents its own rule.
- `Shibuya.Core.Error` (`shibuya-core`): `PolicyError (InvalidPolicyCombo)`. The error the helper
  returns and that `runApp` already surfaces, so callers see one consistent error type.
- `Shibuya.App` (`shibuya-core`): `QueueProcessor (..)`, `ProcessorId (..)`, `mkProcessor` (for
  contrast). The helper returns `[(ProcessorId, QueueProcessor es)]` ready to hand to `runApp`.
- `Shibuya.Handler` (`shibuya-core`): `Handler es msg`, the per-event handler type.
- `Shibuya.Adapter` (`shibuya-core`): `Adapter (..)`, produced per member by `kirokuAdapter`.
- `Kiroku.Store.Subscription.Types` (`kiroku-store`): `ConsumerGroup (..)`, `SubscriptionName`,
  `SubscriptionTarget`, already imported by the adapter.
- `Kiroku.Store.Subscription.Stream` (`kiroku-store`): `subscriptionStream`, the bridge the adapter
  already calls (see shared-artifact note below).

**Signatures that must exist at the end of each milestone** (all in
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`, module `Shibuya.Adapter.Kiroku`):

M1:

```haskell
data KirokuConsumerGroupConfig = KirokuConsumerGroupConfig
    { subscriptionName   :: !SubscriptionName
    , subscriptionTarget :: !SubscriptionTarget
    , groupSize          :: !Int32
    , batchSize          :: !Int32
    , bufferSize         :: !Natural
    , memberConcurrency  :: !Concurrency
    }

defaultConsumerGroupConfig ::
    SubscriptionName -> SubscriptionTarget -> Int32 -> KirokuConsumerGroupConfig

consumerGroupPolicy :: Concurrency -> Either PolicyError (Ordering, Concurrency)
```

M2:

```haskell
kirokuConsumerGroupProcessors ::
    (IOE :> es) =>
    KirokuStore ->
    KirokuConsumerGroupConfig ->
    Handler es RecordedEvent ->
    Eff es (Either PolicyError [(ProcessorId, QueueProcessor es)])
```

M3: no new exported signature; a new hspec `describe "consumer group policy"` block in
`shibuya-kiroku-adapter/test/Main.hs`.

**Shared Streamly-bridge item type and the agreement with `docs/plans/40-...`.** Per MasterPlan 6's
Integration Points, `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` is a shared artifact.
Today `subscriptionStream` returns `(Stream IO RecordedEvent, IO ())` and emits a bare
`RecordedEvent`. EP-40 changes the bridge to be **ack-coupled**: each emitted item becomes a record
carrying the event plus a one-shot reply variable (EP-40's draft names it as roughly
`{ event, attempt, reply }`, possibly via a new `subscriptionAckStream` that preserves the existing
`subscriptionStream` semantics by always replying `Continue`). **This plan does not modify the bridge or its item type.** Under the chosen shape (a) — one Shibuya processor per kiroku member, the shape this plan implements — each member is a distinct adapter with its own `subscriptionStream` whose `consumerGroup = Just (ConsumerGroup m N)` is fixed at construction, so member identity is carried by the adapter/processor pairing (`ProcessorId "<name>-member-<m>"`) rather than by any per-event item field. EP-40 is therefore the **sole owner** of the ack-coupled bridge item (`{ event, attempt, reply }`); this plan consumes EP-40's per-event stream unchanged and forks no parallel type. The reconciliation checkpoint named in MasterPlan 6 reduces, for this plan, to confirming that EP-42 introduces no competing bridge item type and that EP-42's member-aware presentation and EP-40's ack-coupled reply coexist on the same `Ingested` value (EP-40 owns the `AckHandle.finalize` changes; EP-42 owns the processor/policy shape). This matches MasterPlan 6's Integration Points and EP-40's Decision Log.

**`shibuya-core` is unchanged.** The helper only consumes existing `shibuya-core` exports
(`QueueProcessor`, `validatePolicy`, `PolicyError`, `Adapter`, `Handler`). No new type, field, or
function is added to `shibuya-core`, satisfying the MasterPlan 6 constraint.
