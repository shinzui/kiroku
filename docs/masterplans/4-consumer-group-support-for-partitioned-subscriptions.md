---
id: 4
slug: consumer-group-support-for-partitioned-subscriptions
title: "Consumer Group Support for Partitioned Subscriptions"
kind: master-plan
created_at: 2026-05-20T03:19:43Z
intention: "intention_01ks1npgpye4xvcczxvzjsq232"
---


# Consumer Group Support for Partitioned Subscriptions

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Kiroku is a PostgreSQL-backed event store (package `kiroku-store`). Today a
subscription is a single sequential consumer: one worker thread reads the
global event sequence (the `$all` stream) or one category in order and feeds a
handler one event at a time (see `kiroku-store/src/Kiroku/Store/Subscription.hs`
and `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`). A high-volume
projection therefore cannot be scaled horizontally: a single slow handler bounds
end-to-end throughput, and there is no supported way to spread the work across
threads or processes while preserving ordering.

A **consumer group** is a named set of N **members** that collectively process
one logical subscription (one category, or the whole `$all` stream) in parallel.
Each stream in the source is deterministically assigned to exactly one member, so
all events that belong to the same stream are always processed by the same member
in their original order. Members otherwise run independently, each with its own
checkpoint, so adding members increases parallelism without sacrificing
per-stream ordering. We call the number of members the **group size** and each
member's zero-based index its **member index**.

After this initiative is complete, a developer can:

- Start a subscription as member `m` of a group of size `N` (for example `(member
  0, size 4)`), where that member receives only the events whose originating
  stream hashes to slot `m`, in global-position order, and the other three
  members receive the disjoint remainder. The union of all four members'
  deliveries is exactly the full source, with no event delivered to two members
  and none dropped.
- Run those members in the same process (one thread each) or across separate
  processes/hosts (one process each), using the same `subscribe` /
  `withSubscription` API plus a small `ConsumerGroup` descriptor, the effectful
  `Subscription` effect, the Streamly bridge, or the Shibuya adapter.
- See it working through a runnable example and an automated test: append events
  to many streams, run a size-4 group, and observe each member processing a
  disjoint, per-stream-ordered subset whose union is complete.

**Membership model (decided): static assignment.** The caller supplies `(member,
size)` per worker; there is no dynamic rebalancing, heartbeat protocol, or
coordinator that reassigns partitions automatically. This is the same model
message-db uses and — per the research summarized in the Decision Log — it yields
a *stronger* per-stream ordering guarantee than dynamic schemes (EventStoreDB's
"Pinned" strategy documents that ordering is "not a guarantee" during
rebalancing) precisely because a stream's assignment never moves while the group
size is constant. As a robustness guardrail we add an *optional* PostgreSQL
advisory lock per `(group, member)` so two processes cannot silently both run the
same member index (the technique Marten uses for projection ownership).

**In scope:**

- Hash-partitioned routing of `Category`-targeted subscriptions across members.
- Hash-partitioned routing of `$all`-targeted subscriptions across members
  (partitioned by originating stream), so a whole-store projection can also be
  split. This is delivered as a second milestone within the SQL and runtime plans
  so the category path can ship and be verified independently first.
- Per-member checkpoints persisted in the existing `subscriptions` table, extended
  with structured `(consumer_group_member, consumer_group_size)` columns.
- An optional advisory-lock guardrail enforcing one live process per member index.
- Surfacing consumer groups through every existing subscription entry point: the
  `MonadIO` `subscribe`/`withSubscription`, the effectful `Subscription` effect,
  the Streamly `subscriptionStream` bridge, and the Shibuya adapter.
- User documentation and a runnable, tested end-to-end example.

**Explicitly out of scope:**

- Dynamic rebalancing / cooperative reassignment (Kafka- or Pulsar-style). The
  static model is deliberate; dynamic membership is recorded as a possible future
  follow-up in the Decision Log, not built here.
- Automatic group-size resizing without redeploy. Changing `size` re-buckets every
  stream and is treated as a coordinated operator action (stop the group, let
  in-flight work drain to checkpoints, restart all members with the new size). The
  user guide documents this procedure.
- A full migration framework (`kiroku-migrate` package extraction). This work
  introduces the first non-trivial DDL beyond `CREATE TABLE IF NOT EXISTS` (an
  idempotent `ALTER TABLE`/constraint swap on `subscriptions`); the Decision Log
  records the explicit decision to defer the package extraction and ship the DDL
  idempotently in the existing embedded `kiroku-store/sql/schema.sql`, consistent
  with how `docs/plans/partition-ready-schema.md` was parked.


## Decomposition Strategy

The initiative was decomposed by **functional concern**, so that each child plan
produces an independently verifiable behavior and the hard dependencies form a
short chain rather than a web.

1. **Data layer first (EP-1).** Every higher layer needs two new capabilities
   from PostgreSQL: a partition-filtered read that returns only the streams
   assigned to one member, and a per-member checkpoint. Both are pure SQL +
   schema concerns and both touch migration-sensitive DDL, so they are
   consolidated into one foundation plan that can be verified entirely at the
   prepared-statement level (a property test proving disjointness, completeness,
   per-stream affinity, and determinism). Putting all the DDL in one place keeps
   the `kiroku-migrate` decision in a single plan.

2. **Runtime next (EP-2).** With the SQL and schema in place, the subscription
   worker can route a member through the partitioned statements and the
   per-member checkpoint. This plan owns the public `ConsumerGroup` type, the new
   config field, the worker wiring (catch-up + the existing DB-driven live loop,
   which is the natural fit because it already re-queries the database on each
   publisher tick), the optional advisory-lock guardrail, and observability. It
   delivers a working group via the existing `MonadIO` `subscribe`/`withSubscription`
   and the Streamly bridge.

3. **Integrations last (EP-3).** The effectful `Subscription` effect and the
   Shibuya adapter are thin pass-throughs that expose the runtime to the two
   higher-level consumption styles used in this ecosystem. They depend only on
   the runtime's public types.

4. **Documentation and a runnable example (EP-4).** Consumer groups carry real
   operational subtleties — the one-process-per-member invariant, the resize
   procedure, the cross-version hash caveat — that deserve a focused,
   self-contained user guide plus a runnable, tested example program so the docs
   are demonstrably correct rather than aspirational.

**Alternatives considered and rejected.** (a) A single mega-plan: rejected — the
work spans the SQL layer, the concurrency runtime, two integration surfaces, and
docs; that is more than five milestones across unrelated modules, which the
MasterPlan guidance says to split. (b) Splitting the checkpoint schema from the
read SQL into separate plans: rejected — both are migration-sensitive DDL and the
checkpoint `ON CONFLICT` target depends on the new unique constraint, so they
must change together to keep the build green. (c) A dynamic-rebalancing plan:
rejected for this initiative per the static-membership decision; recorded as
future work.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Consumer-Group Partition Routing SQL and Checkpoint Schema | docs/plans/28-consumer-group-partition-routing-sql-and-checkpoint-schema.md | None | None | Complete |
| 2 | Consumer-Group Subscription Runtime and Per-Member Workers | docs/plans/29-consumer-group-subscription-runtime-and-per-member-workers.md | EP-1 | None | Not Started |
| 3 | Consumer-Group Effect API and Shibuya Adapter Integration | docs/plans/30-consumer-group-effect-api-and-shibuya-adapter-integration.md | EP-2 | None | Not Started |
| 4 | Consumer-Group User Guide and Runnable Example | docs/plans/31-consumer-group-user-guide-and-runnable-example.md | EP-2 | EP-3 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The hard dependencies form a chain `EP-1 → EP-2 → {EP-3, EP-4}`:

- **EP-2 hard-depends on EP-1.** The runtime worker calls the partition-filtered
  prepared statements (`readCategoryForwardConsumerGroupStmt`, and for `$all`
  `readAllForwardConsumerGroupStmt`) and the per-member checkpoint statements
  (`getCheckpointMemberStmt`, `saveCheckpointMemberStmt`) that EP-1 defines in
  `kiroku-store/src/Kiroku/Store/SQL.hs`, and it relies on the
  `subscriptions`-table columns EP-1 adds. None of that code exists or compiles
  before EP-1.

- **EP-3 hard-depends on EP-2.** The effect wrappers and the Shibuya adapter
  re-export and consume the `ConsumerGroup` type and the `consumerGroup` config
  field that EP-2 introduces in
  `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`. There is nothing to
  surface until EP-2 lands.

- **EP-4 hard-depends on EP-2 and soft-depends on EP-3.** The user guide and the
  runnable example need the working runtime (EP-2). The example is most natural
  written against the plain `subscribe` API from EP-2, so it does not strictly
  need EP-3; if EP-3 is done first, EP-4 should additionally document and show the
  effectful and Shibuya entry points. EP-4 can therefore start as soon as EP-2 is
  complete, in parallel with EP-3.

**Parallelism:** Only one plan (EP-1) can start immediately. After EP-1 completes,
EP-2 is the sole next step. After EP-2 completes, EP-3 and EP-4 may proceed in
parallel.


## Integration Points

These are the shared artifacts multiple child plans touch. Each names the owning
plan (which defines it) and how later plans consume it. Child plans must keep
these descriptions byte-consistent.

### IP-1 — Partition assignment rule (owned by EP-1)

The single source of truth for "which member owns a stream." The partition key is
the **originating stream's surrogate id** (`streams.stream_id`, equivalently
`stream_events.original_stream_id`, a `BIGINT`). The assignment is:

```text
member_of(stream_id) = (((hashtextextended(stream_id::text, 0) % size) + size) % size)
```

A stream belongs to member `m` of a group of size `N` iff `member_of(stream_id) =
m`. The double-mod `((h % N) + N) % N` normalizes PostgreSQL's possibly-negative
`hashtextextended` result into `[0, N)`; a plain `MOD` or `abs()` is wrong
(`abs(min_bigint)` overflows). `hashtextextended(text, bigint)` is PostgreSQL's
native extended hash (the same family used by declarative HASH partitioning),
chosen over a custom MurmurHash or md5 for zero maintenance and good
distribution. Because all members re-derive the assignment at query time on the
same cluster, the documented "stable only within an installation/major version"
caveat is benign; EP-4 documents it for operators who upgrade.

Key property the rule guarantees and EP-1 must test: with `size = 1`, the
predicate is always true (`((h % 1) + 1) % 1 = 0` for all `h`), so a size-1 group
is exactly equivalent to a non-partitioned subscription.

### IP-2 — New prepared statements (owned by EP-1, consumed by EP-2)

EP-1 adds to `kiroku-store/src/Kiroku/Store/SQL.hs` (and exports):

- `readCategoryForwardConsumerGroupStmt :: Statement (Int64, Text, Int32, Int32, Int32) (Vector RecordedEvent)`
  — params `(startPosition, category, member, size, limit)`. Mirrors
  `readCategoryForwardSQL` but adds the IP-1 predicate on `streams s` so whole
  unassigned streams are pruned before the lateral join.
- `readAllForwardConsumerGroupStmt :: Statement (Int64, Int32, Int32, Int32) (Vector RecordedEvent)`
  — params `(startPosition, member, size, limit)`. Mirrors `readAllForwardSQL`
  but adds the IP-1 predicate on `se.original_stream_id`. (Delivered in EP-1's
  `$all` milestone.)
- `getCheckpointMemberStmt :: Statement (Text, Int32) (Maybe Int64)` — params
  `(subscriptionName, member)`.
- `saveCheckpointMemberStmt :: Statement (Text, Int32, Int64) ()` — params
  `(subscriptionName, member, position)`, upserting on the new composite unique
  key with `last_seen = GREATEST(...)` semantics identical to the existing
  `saveCheckpointStmt`.

The decoders reuse the existing `recordedEventRow`; the new read statements return
the same `Vector RecordedEvent` shape as `readCategoryForwardStmt`, so EP-2's
worker can swap statements without touching decoding or the
`Kiroku.Store.Settings.decodeEvents` hook.

### IP-3 — `subscriptions` table schema (owned by EP-1, consumed by EP-2)

EP-1 extends the `subscriptions` table in `kiroku-store/sql/schema.sql` with two
columns and a composite unique key, applied idempotently so both fresh databases
and existing ones converge:

```sql
-- columns (idempotent)
consumer_group_member INT NOT NULL DEFAULT 0
consumer_group_size   INT NOT NULL DEFAULT 1
-- unique key changes from UNIQUE(subscription_name)
-- to UNIQUE(subscription_name, consumer_group_member)
```

Backward compatibility: existing rows and all non-group subscriptions are member
0, size 1. **Critical detail for EP-1:** the existing `saveCheckpointStmt` uses
`ON CONFLICT (subscription_name)`, which stops being a valid conflict target once
the single-column unique is dropped. EP-1 must update that `ON CONFLICT` target to
`(subscription_name, consumer_group_member)` in the *existing* statement (whose
inserts default member to 0) at the same time it swaps the constraint, so the
build and all current subscription tests stay green after EP-1 alone. EP-2 then
migrates the worker call sites to the member-aware statements from IP-2.

### IP-4 — `ConsumerGroup` type and `consumerGroup` config field (owned by EP-2, consumed by EP-3, EP-4)

EP-2 adds to `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` and exports:

```haskell
-- | Static consumer-group membership for a subscription.
data ConsumerGroup = ConsumerGroup
    { member :: !Int32  -- ^ 0-based member index; must satisfy 0 <= member < size
    , size   :: !Int32  -- ^ total members in the group; must be >= 1
    }
    deriving stock (Eq, Show)
```

and a new field on `SubscriptionConfigM m`:

```haskell
, consumerGroup :: !(Maybe ConsumerGroup)
  -- ^ 'Nothing' (the default) = ordinary single-consumer subscription.
  --   'Just cg' = this worker is member 'cg.member' of a group of size 'cg.size'.
```

`defaultSubscriptionConfig` sets `consumerGroup = Nothing`, so all existing
callers compile unchanged. When `consumerGroup = Just cg` the worker routes
through the IP-2 partitioned statements and persists its checkpoint under
`(name, cg.member)`; when `Nothing` it behaves exactly as today and persists under
`(name, 0)`. EP-3 re-exports `ConsumerGroup` and threads the field through the
effect wrappers and the `KirokuAdapterConfig`; EP-4 references the type in docs
and the example. The validity invariant `0 <= member < size` and `size >= 1` is
enforced once, in EP-2, at `subscribe` time (rejecting invalid groups with a
clear error), and documented identically wherever the field is surfaced.

### IP-5 — Observability events (owned by EP-2)

EP-2 extends the subscription lifecycle events in
`kiroku-store/src/Kiroku/Store/Observability.hs` so the existing
`KirokuEventSubscription*` signals carry the member/size context (or adds
group-aware variants) without breaking the current event taxonomy re-exported
from `Kiroku.Store`. EP-3 and EP-4 only read these; they do not define new ones.


## Progress

Track milestone-level progress across all child plans.

- [x] EP-1 (2026-05-20): Partition-filtered category read statement + assignment-rule property tests
- [x] EP-1 (2026-05-20): `subscriptions` schema extension (member/size columns, composite unique, ON CONFLICT migration) + per-member checkpoint statements
- [x] EP-1 (2026-05-20): Partition-filtered `$all` read statement + tests
- [ ] EP-2: `ConsumerGroup` type, `consumerGroup` config field, validity checks
- [ ] EP-2: Worker routing through partitioned statements + per-member checkpoints (category)
- [ ] EP-2: `$all` group routing + optional advisory-lock guardrail + observability
- [ ] EP-2: End-to-end group test (disjoint, complete, per-stream-ordered) + Streamly bridge
- [ ] EP-3: `ConsumerGroup` surfaced through the effectful `Subscription` effect wrappers
- [ ] EP-3: `KirokuAdapterConfig` consumer-group fields + multi-member Shibuya test
- [ ] EP-4: `docs/user/consumer-groups.md` guide (model, invariants, resize, hash caveat)
- [ ] EP-4: Runnable, tested size-N example demonstrating disjoint + ordered processing


## Surprises & Discoveries

- **EP-1 complete (2026-05-20).** The IP-2 prepared statements landed with the
  exact signatures the contract names, so EP-2 can consume them without
  adaptation: `readCategoryForwardConsumerGroupStmt :: Statement (Int64, Text,
  Int32, Int32, Int32) (Vector RecordedEvent)`, `readAllForwardConsumerGroupStmt
  :: Statement (Int64, Int32, Int32, Int32) (Vector RecordedEvent)`,
  `getCheckpointMemberStmt :: Statement (Text, Int32) (Maybe Int64)`, and
  `saveCheckpointMemberStmt :: Statement (Text, Int32, Int64) ()`, all exported
  from the now-`exposed-module` `Kiroku.Store.SQL`. The IP-3 schema change (the
  two columns, the composite unique index `ix_subscriptions_name_member`, and the
  retargeted `ON CONFLICT (subscription_name, consumer_group_member)` on the
  existing `saveCheckpointStmt`) is in place; the pre-existing `subscribe`
  checkpoint-resume tests stayed green, confirming the migration. Final state:
  `cabal test kiroku-store` = 143 examples, 0 failures.

- **Affects EP-2/EP-3 — formatter normalizes signatures.** The repo's `treefmt`
  pre-commit hook reflows the `name\n    :: Statement ...` layout used in the
  plans' code snippets into `name ::\n    Statement ...` and converts multi-line
  `-- |` Haddock into `{- | ... -}`. The shipped EP-1 source is therefore
  cosmetically different from IP-2's snippets but byte-equivalent in meaning;
  EP-2/EP-3 authors copying signatures from the IP descriptions should expect the
  hook to reflow them and budget a re-`git add` per commit.

- **Existing-database (upgrade) convergence not exercised by CI.** `cabal test`
  always provisions a fresh ephemeral PostgreSQL, so only the fresh-schema path is
  automated. EP-1's idempotent `ALTER`/`DROP CONSTRAINT`/`CREATE UNIQUE INDEX`
  block is proven by construction plus the checkpoint regression; the optional
  `just reset-database` / `just init-schema` manual upgrade check was not run to
  avoid mutating a shared local DB. Operators upgrading a pre-EP-1 database should
  run it once (documented in EP-1's Concrete Steps Step 4 and to be surfaced in
  EP-4's user guide).


## Decision Log

- Decision: Implement consumer groups as **static, hash-partitioned competing
  consumers** (paradigm A), not as distributed whole-projection shards (paradigm
  B, Marten's model).
  Rationale: The user's requirement — "partition a subscription to process faster
  while keeping same-stream events ordered" — is exactly the Kafka / Pulsar
  `Key_Shared` / EventStoreDB `Pinned` / message-db pattern. A research survey of
  Marten (May 2026, Marten 8.x) confirmed Marten deliberately does **not**
  hash-partition a single projection; it scales by distributing whole projections
  across nodes via PostgreSQL advisory-lock leader election, and the team has
  wanted single-projection sharding since v4 but never shipped it — a signal of
  the difficulty of bolting per-key partitioning onto a strict global-sequence
  model. Kiroku lacks Marten's "split into more, smaller projections" escape
  hatch, so hash partitioning is the right parallelism axis here.
  Date: 2026-05-20

- Decision: **Static membership** (caller supplies `(member, size)`); no dynamic
  rebalancing in this initiative.
  Rationale: The user confirmed "static assignment is fine." Research showed
  static membership yields a *stronger* per-stream ordering guarantee than dynamic
  schemes: EventStoreDB's Pinned strategy explicitly documents ordering as "not a
  guarantee" during rebalancing, whereas message-db's static model never moves a
  stream's assignment while size is constant. Dynamic rebalancing (a coordinator,
  heartbeats, partition handoff that drains in-flight acks à la Pulsar) is
  recorded as possible future work but is a large, separable effort.
  Date: 2026-05-20

- Decision: Add an **optional PostgreSQL advisory-lock guardrail** per
  `(group, member)`.
  Rationale: The one weakness of static membership is the operational invariant
  "exactly one live process per member index." Marten uses session-level advisory
  locks for projection ownership; we adopt the same cheap technique as an opt-in
  guard so a misconfigured second member-3 process fails fast instead of silently
  double-processing. Off by default to keep the simple in-process case
  dependency-free.
  Date: 2026-05-20

- Decision: Use PostgreSQL-native **`hashtextextended`** as the partition hash,
  over the originating stream's surrogate id rendered as text.
  Rationale: The user selected the native hash over MurmurHash (no native pg
  implementation; custom plpgsql to write/test/maintain) and md5 (heavier,
  message-db-compat we are not pursuing). `hashtextextended` is the same hash
  family PostgreSQL uses for declarative HASH partitioning, is SQL-callable and
  well-distributed. Hashing the surrogate `stream_id` (available with zero extra
  joins in both the category and `$all` read paths) rather than the stream *name*
  avoids a name-parse/`cardinal_id` step and a streams join on the hot `$all`
  path, while giving identical per-stream affinity. The "stable only within an
  installation/version" caveat is benign because members re-derive at query time
  on one cluster; EP-4 documents it.
  Date: 2026-05-20

- Decision: Include **`$all`** as a partitionable target, not categories only.
  Rationale: The user deferred the scope choice to research ("stop basing
  decisions on message-db"). The mechanism is identical for `$all` (filter by
  originating stream) and unlocks parallelizing a whole-store projection, which is
  valuable because kiroku has no "many smaller projections" alternative. To keep
  each plan independently verifiable, `$all` partitioning is a *second milestone*
  inside EP-1 and EP-2, so the category path ships and is proven first.
  Date: 2026-05-20

- Decision: Persist per-member checkpoints via **structured columns**
  (`consumer_group_member`, `consumer_group_size`) on the existing
  `subscriptions` table with a composite unique key, rather than encoding the
  member into the subscription name string.
  Rationale: Structured columns are queryable (operators can see group topology)
  and keep the checkpoint key explicit. The cost is the first non-trivial DDL
  beyond `CREATE TABLE IF NOT EXISTS` and a `saveCheckpointStmt` `ON CONFLICT`
  change; both are handled idempotently in the embedded schema and consolidated in
  EP-1.
  Date: 2026-05-20

- Decision: **Defer** extracting a `kiroku-migrate` package; ship the
  `subscriptions` DDL idempotently in `kiroku-store/sql/schema.sql`.
  Rationale: Auto-memory `project_schema_migration.md` names "first non-trivial
  DDL" as the trigger to consider extracting migrations, and
  `docs/plans/partition-ready-schema.md` parked a larger DDL change for the same
  reason. The `subscriptions` extension here is small, additive, and expressible
  as idempotent `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` + a guarded unique-index
  swap, so it fits the current embedded-schema approach. Extraction remains the
  right long-term move and is logged as future work, not done here.
  Date: 2026-05-20

- Decision: Decompose into four child plans (SQL/schema, runtime, integrations,
  docs+example) with a linear `EP-1 → EP-2 → {EP-3, EP-4}` dependency chain.
  Rationale: Functional-concern boundaries; each plan yields an independently
  verifiable behavior; integrations and docs fan out only after the runtime
  exists. See Decomposition Strategy for the alternatives rejected.
  Date: 2026-05-20


## Outcomes & Retrospective

(To be filled during and after implementation.)
