# Consumer Groups

A consumer group scales a single subscription horizontally while preserving
per-stream ordering. Instead of one worker reading a category (or the whole
`$all` stream) sequentially, a group of `N` **members** splits the work: each
source stream is deterministically assigned to exactly one member, so every
event from a given stream is always processed by the same member, in order,
while the members run in parallel — one thread each, in one process or spread
across many. After following this guide you can start member `m` of a size-`N`
group, see each member receive a disjoint slice of the source whose union is the
complete stream, and resize or operate the group safely in production.

Consumer groups build directly on ordinary subscriptions; read
[Subscriptions](subscriptions.md) first. Everything there — catch-up from a
durable checkpoint, live `NOTIFY`-driven delivery, at-least-once semantics,
the overflow policy — still applies per member.

## Mental Model

Four terms are used throughout:

- **Consumer group** — a named set of members that collectively process one
  logical subscription. All members share the same `SubscriptionName`.
- **Member** — one worker (one thread) in the group. A member processes only
  the streams assigned to it.
- **Member index** — a member's zero-based position, `0 .. size - 1`. This is
  the `member` value you pass per worker.
- **Group size** — the total number of members, `N`. This is the `size` value;
  every member of the group must use the same `size`.

The **partition key** is the *originating stream*, identified by its database
surrogate id (the `stream_id` column), not the stream's name. A stream belongs
to exactly one member, determined by hashing the stream's id modulo the group
size. Because the assignment is a pure function of `(stream_id, size)`, it is
identical for every member and stable for the lifetime of a fixed-size group —
no coordinator, heartbeat, or rebalancing is involved. This is **static
membership**: you tell each worker which `(member, size)` it is, and that never
changes while the group runs. The exact hash formula and its one caveat are in
[Hash Caveat](#hash-caveat) below.

A size-1 group is exactly equivalent to an ordinary, non-partitioned
subscription: every stream hashes to the single member 0.

## Starting A Member

A member is an ordinary subscription with the `consumerGroup` field set. Build
the config with `defaultSubscriptionConfig` and override `consumerGroup`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Control.Lens ((^.))
import Data.Int (Int32)
import Kiroku.Store
import Kiroku.Store.Subscription
import Kiroku.Store.Subscription.Types (ConsumerGroup (..))

-- Run this with m = 0, 1, 2, 3 — one invocation per member.
runMember :: KirokuStore -> Int32 -> IO ()
runMember store m = do
  let cfg =
        (defaultSubscriptionConfig
          (SubscriptionName "order-projection")
          (Category (CategoryName "order"))
          handler)
          { consumerGroup = Just ConsumerGroup { member = m, size = 4 } }
  withSubscription store cfg $ \h -> do
    result <- wait h        -- block until Stop, cancel, or failure
    print result

handler :: RecordedEvent -> IO SubscriptionResult
handler event = do
  apply (event ^. #payload)   -- your projection update
  pure Continue
```

To run a full size-4 group you start four members with the **same**
`SubscriptionName` (`"order-projection"`), the same `size` (`4`), and distinct
`member` values (`0, 1, 2, 3`). Two deployment shapes work identically:

- **Same process** — call `subscribe` (or `withSubscription`) four times, once
  per thread, passing `member = 0 .. 3`. Each call returns its own handle.
- **Separate processes or hosts** — run four copies of the program, each
  configured with a different `member` (for example from an environment
  variable or `--member` flag) and the same `size`. The members coordinate
  only through PostgreSQL; they need not be co-located.

`consumerGroup` defaults to `Nothing`, which is an ordinary single-consumer
subscription, so existing callers are unaffected. The validity invariant
`size >= 1` and `0 <= member < size` is checked once, at `subscribe` time; a
violation throws `InvalidConsumerGroup` (carrying the offending `member` and
`size`) before any work starts.

The two consumer-group fields on `SubscriptionConfig`:

| Field | Default | Meaning |
| --- | --- | --- |
| `consumerGroup :: Maybe ConsumerGroup` | `Nothing` | `Nothing` = ordinary subscription. `Just (ConsumerGroup { member, size })` = this worker is member `member` of a group of `size`. |
| `consumerGroupGuard :: Bool` | `False` | When `True`, run a startup advisory-lock conflict check so a duplicate member fails fast (see [Operational Invariant](#operational-invariant)). Ignored when `consumerGroup` is `Nothing`. |

## Operational Invariant

The one rule you must uphold with static membership:

> **Exactly one live process runs each member index, and all members use the
> same `size`.**

If you violate it, the failure is silent corruption, not an error:

- **Two live processes share a member index.** Both read the same slice of
  streams and both save a checkpoint under the same `(name, member)` row, so
  whichever saves last wins; the other replays from there on its next cycle.
  Every event in that slice is processed twice. (Idempotent handlers absorb the
  duplicate work but you still waste it.)
- **A member index is missing** (you started 3 of a size-4 group), or **members
  disagree on `size`.** Some streams hash to a slot no live member owns, so
  their events are never delivered — a permanent gap, not a delay.

To catch the first case automatically, set `consumerGroupGuard = True`. At
startup the worker probes a PostgreSQL advisory lock keyed on `(name, member)`;
if another holder is detected at that instant, it throws
`ConsumerGroupGuardConflict` (carrying the `name` and `member`) instead of
silently double-processing. **This is a startup detection probe, not a
lifetime-held lock**: it reliably catches two members started concurrently, but
it cannot catch a *staggered* start where the first process has already passed
its probe and released it before the second starts. Treat the guard as a
fail-fast safety net for misconfiguration, not as a distributed lock that
guarantees single ownership. Recommended on in production; it is off by default
to keep the simple in-process case dependency-free.

## Resizing The Group

Changing `size` re-buckets every stream. A stream assigned to member 1 of a
size-4 group may be assigned to a completely different member in a size-8 group,
because the partitioning formula gives a different result for the same stream id
at a different size. Therefore a resize is a **coordinated, stop-the-world
operation**, not a rolling change:

1. **Stop all members.** Either let each member's `wait` resolve (a handler
   returning `Stop`) or `cancel` each one. Accept that boundary events replay
   under at-least-once delivery.
2. **Let in-flight work drain to checkpoints.** Each member's checkpoint is
   saved per batch; once stopped, every member has a durable position for its
   slice.
3. **Restart all members with the new `size`** — and the new member count,
   `0 .. newSize - 1`.

Do **not** run old and new `size` values at the same time. While the values are
mixed, the formula disagrees across members: some streams are claimed by two
members (the old owner and the new owner), others by none, so you get both
duplicates and gaps until every member agrees on `size` again. Treat a resize
exactly like a database migration: stop the world, change the value everywhere
atomically, restart.

## Ordering And Delivery Guarantees

- **Per-stream ordering within a member.** All events for a given stream are
  assigned to the same member, and that member processes them in global-position
  order. There is no cross-stream ordering guarantee between members — that is
  the point of partitioning — but within any single stream, order is preserved.
  Static membership makes this *stronger* than dynamic-rebalancing schemes: a
  stream's assignment never moves while `size` is constant, so there is no
  reassignment window during which ordering could be violated.
- **At-least-once delivery.** Identical to an ordinary subscription. The
  checkpoint advances per batch, not per event, so events on a batch boundary
  replay if a member is cancelled or crashes before its checkpoint is saved.
- **Idempotent handlers are required**, for exactly the same reason as ordinary
  subscriptions: a replayed event must not produce a wrong-on-replay result.
- **Per-member checkpoints.** Each member's progress is saved under
  `(subscription_name, member_index)` in the `subscriptions` table's
  `consumer_group_member` column. Member 2 restarts from its own checkpoint and
  is never confused by member 0's or member 3's progress. A non-group
  subscription is simply member 0 of size 1, so it shares the same table and
  keying with no special case.

## Hash Caveat

The stream-to-member assignment is computed in SQL at query time as:

```sql
member_of(stream_id) = (((hashtextextended(stream_id::text, 0) % size) + size) % size)
```

`hashtextextended` is PostgreSQL's native extended hash — the same hash family
used by declarative `HASH` partitioning. The double-mod `((h % N) + N) % N`
normalizes its possibly-negative result into the range `[0, N)`. The Haskell
code never computes the hash; it only passes `(member, size)` as query
parameters, so all members re-derive the assignment on the same cluster and
always agree.

The one caveat: `hashtextextended` is stable **within a single PostgreSQL
installation and major version**, but is **not guaranteed stable across major
upgrades or across different-endian platforms**. In normal operation this is a
non-issue — every member queries the same cluster, so the hash is consistent
across the whole group. Two situations need care:

- **A PostgreSQL major-version upgrade may shift hash values**, re-bucketing
  some streams. Handle it like a resize: drain and restart the whole group
  together against the upgraded cluster. Never run members against different
  PostgreSQL major versions of the same logical store at once.
- **Running the same `SubscriptionName` against two separate clusters is safe.**
  The hash is cluster-local, so independent deployments do not interfere.

## Effectful API And Shibuya Adapter

Consumer groups are reachable from all three subscription entry points; the
`ConsumerGroup` descriptor is the same in each.

**Effectful `Subscription` effect.** Set the same `consumerGroup` field on the
config you pass to the effectful `subscribe` / `withSubscription` from
`Kiroku.Store.Subscription.Effect`:

```haskell
import Kiroku.Store.Subscription.Effect (subscribe, withSubscription)
import Kiroku.Store.Subscription.Types (ConsumerGroup (..))

let cfg =
      (defaultSubscriptionConfig
        (SubscriptionName "order-projection")
        (Category (CategoryName "order"))
        handler)        -- handler :: RecordedEvent -> Eff es SubscriptionResult
        { consumerGroup = Just ConsumerGroup { member = m, size = 4 } }
```

The handler runs in your `Eff` stack, so it can use any effects in scope
(`State`, `Reader`, logging) with the same partitioning and per-member
checkpoints. One limitation to know: external cancellation of an *effectful*
group worker (throwing `AsyncCancelled` at it while it is blocked in the
interpreter's unlift) does not currently terminate cleanly. Stop effectful
members from **inside** the handler by returning `Stop`, or run multi-member
groups through the plain-IO `subscribe`/`withSubscription` API, whose cancel
path works as documented. Do not rely on external `cancel` to stop an
effectful group member.

**Shibuya adapter.** To run a whole group under Shibuya in one process, hand a
`KirokuConsumerGroupConfig` to `kirokuConsumerGroupProcessors`; one call yields
`N` policy-pinned processors (one per member, `ProcessorId "<name>-member-<m>"`)
with no manual `[0 .. N - 1]` wiring:

```haskell
import Shibuya.Adapter.Kiroku (defaultConsumerGroupConfig, kirokuConsumerGroupProcessors)

let cfg = defaultConsumerGroupConfig
            (SubscriptionName "order-projection")
            (Category (CategoryName "order"))
            4   -- group size

Right processors <- kirokuConsumerGroupProcessors store cfg handler
Right appHandle  <- runApp IgnoreFailures 100 processors
```

The group maps onto Shibuya's `PartitionedInOrder` ordering (each member is
`Serial`; the group is parallel across members). To run members in **separate**
processes instead, give each a single `kirokuAdapter` whose `consumerGroup` is
`Just (ConsumerGroup { member = m, size = 4 })` with the same `subscriptionName`.
See [Shibuya Adapter](shibuya-adapter.md) for the full adapter setup.

If a member loses its database connection while live, it enters the
`Reconnecting` state and re-catches-up from its own per-member checkpoint rather
than dying (observable via `currentState`, which returns `Just Reconnecting`,
and the `KirokuEventSubscriptionReconnecting` event). Each member is a distinct
worker with its own registry entry, keyed by `(subscriptionName, member)`, so
`subscriptionStates store` lists every member of a group separately with its own
state and `cursor`. Any events a member dead-letters
are recorded per-member in `kiroku.dead_letters` (keyed by
`consumer_group_member`).

## A Runnable Demonstration

The repository ships a self-contained example that starts an ephemeral
PostgreSQL, appends 120 events across 40 streams, runs a size-4 group, and
prints per-member counts plus disjoint and completeness checks. Run it from the
repository root with no external database:

```bash
cabal run kiroku-store:kiroku-consumer-group-example
```

You should see four member counts that sum to 120, `complete: OK`, and
`disjoint: OK`. The source lives at `kiroku-store/example/Main.hs` and is the
runnable proof of the guarantees described above.

## See Also

- [Subscriptions](subscriptions.md) — the underlying subscription mechanism
  every member builds on.
- [Shibuya Adapter](shibuya-adapter.md) — supervised multi-subscription
  processing, including consumer-group members.
- [Observability](observability.md) — subscription lifecycle events carry the
  member/size context (`SubscriptionGroupContext`).
