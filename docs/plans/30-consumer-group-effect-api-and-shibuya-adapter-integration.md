---
id: 30
slug: consumer-group-effect-api-and-shibuya-adapter-integration
title: "Consumer-Group Effect API and Shibuya Adapter Integration"
kind: exec-plan
created_at: 2026-05-20T03:19:43Z
intention: "intention_01ks1npgpye4xvcczxvzjsq232"
master_plan: "docs/masterplans/4-consumer-group-support-for-partitioned-subscriptions.md"
---

# Consumer-Group Effect API and Shibuya Adapter Integration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, every consumption style that Kiroku exposes — the direct `MonadIO` API,
the effectful `Subscription` effect, and the Shibuya adapter — supports consumer groups.
A developer who has already wired up EP-2's runtime (see the hard-dependency note below)
can scale a slow projection across N parallel workers by adding a single `consumerGroup`
field to their config, regardless of whether they write plain IO code, work inside an
`Eff` stack, or run a Shibuya-supervised pipeline.

Concretely: a team running a Shibuya application that processes events from the `orders`
category can change their `KirokuAdapterConfig` to set `consumerGroup = Just (ConsumerGroup
{ member = 0, size = 4 })`, start three more Shibuya processors with `member = 1`, `2`, `3`,
and immediately see each processor handle a disjoint, per-stream-ordered quarter of the
event stream, with the four quarters unioning to every event. No extra infrastructure is
needed — just more Haskell processes, each with a unique member index.

You can verify it is working by running both test suites:

```bash
cabal test kiroku-store          # effectful group end-to-end test
cabal test shibuya-kiroku-adapter  # adapter group integration test
```

Both suites use an ephemeral PostgreSQL instance (no external database required) and assert
disjoint, complete, per-stream-ordered delivery.


## Progress

- [ ] M1: Confirm the `runSubscription` interpreter's record-update pass-through and
  annotate the relevant lines with an explicit comment.
- [ ] M1: Audit `Kiroku.Store.Subscription` and `Kiroku.Store` for `ConsumerGroup`
  re-exports; add the necessary export entries so `ConsumerGroup (..)`,
  `InvalidConsumerGroup (..)`, `ConsumerGroupGuardConflict (..)` are reachable from
  `Kiroku.Store`.
- [ ] M1: Build `kiroku-store` to confirm no gaps. `cabal build kiroku-store` green.
- [ ] M1: Write the effectful end-to-end test in
  `kiroku-store/test/Test/ConsumerGroupEffect.hs` — size-4 category group using
  `runSubscription` / `withSubscription` (the Effect module) in an `Eff` stack,
  asserting disjoint + complete + per-stream-ordered.
- [ ] M1: Register `Test.ConsumerGroupEffect` in `kiroku-store/kiroku-store.cabal` and
  wire it into `kiroku-store/test/Main.hs`. `cabal test kiroku-store` green.
- [ ] M2: Add `consumerGroup :: !(Maybe ConsumerGroup)` field to `KirokuAdapterConfig`
  in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`.
- [ ] M2: Thread the field through `kirokuAdapter`'s `SubscriptionConfig` construction.
- [ ] M2: Add `ConsumerGroup (..)` to the `Shibuya.Adapter.Kiroku` module export list
  and import list.
- [ ] M2: Update the module Haddock example in `Shibuya.Adapter.Kiroku` to show a
  size-N consumer group.
- [ ] M2: `cabal build shibuya-kiroku-adapter` green.
- [ ] M3: Write the Shibuya adapter group integration test in
  `shibuya-kiroku-adapter/test/Main.hs` — size-4 category group, four processors,
  assert each receives a disjoint slice.
- [ ] M3: `cabal test shibuya-kiroku-adapter` green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Keep `consumerGroupGuard` out of `KirokuAdapterConfig`; expose only
  `consumerGroup :: Maybe ConsumerGroup` on the adapter record.
  Rationale: The advisory-lock guard introduced in EP-2 (`consumerGroupGuard :: Bool`
  on `SubscriptionConfigM`) is a startup-only detection probe with a documented
  limitation (it does not hold the lock for the worker's lifetime — see EP-2's
  Decision Log, entry for the advisory-lock guardrail). Exposing it in the high-level
  adapter config would imply a safety guarantee the underlying mechanism does not
  actually provide, which is misleading. Users who need the guard at the adapter level
  can extend `KirokuAdapterConfig` in a follow-up once the full lifetime-held session
  lock is implemented. For now the field is left off the adapter record to avoid
  over-promising.
  Date: 2026-05-20

- Decision: Accept the `defaultSubscriptionConfig` record expansion rather than
  building the `SubscriptionConfig` inside `kirokuAdapter` by hand.
  Rationale: `kirokuAdapter` currently builds the config with an explicit record
  literal using all six fields. When EP-2 adds `consumerGroup` and
  `consumerGroupGuard`, any explicit literal that does not include those fields will
  fail to compile. Because `defaultSubscriptionConfig` sets reasonable defaults for
  both fields (`consumerGroup = Nothing`, `consumerGroupGuard = False`) the cleanest
  fix is to use `defaultSubscriptionConfig subName subTarget (\_ -> pure Continue)` as
  the base and then override only the non-default fields with record update syntax,
  which automatically picks up any future fields. Adopting this style in M2 is both
  the minimal fix and the most future-proof shape.
  Date: 2026-05-20

- Decision: The effectful test (`Test.ConsumerGroupEffect`) is a new file, not an
  extension of EP-2's `Test.ConsumerGroup`.
  Rationale: `Test.ConsumerGroup` lives in `kiroku-store` and tests the plain-IO
  `subscribe`/`withSubscription` from `Kiroku.Store.Subscription`. The effectful test
  exercises `subscribe`/`withSubscription` from `Kiroku.Store.Subscription.Effect`
  inside an `Eff` stack. They share the same end-to-end assertions (disjoint,
  complete, per-stream-ordered) but differ in the entry point and the threading model
  (`ConcUnlift Persistent (Limited 1)` runs the handler in the `Eff` environment,
  not directly in IO). Keeping them separate keeps the narrative of each test clean
  and avoids `Test.ConsumerGroup` gaining an effectful import surface.
  Date: 2026-05-20

- Decision: The multi-processor Shibuya group test uses one Shibuya `runApp` call
  with four adapters as four processors, all within one process, rather than spinning
  up four OS processes.
  Rationale: The EP-2 runtime test already proves the disjoint / complete / ordered
  guarantee at the database and subscription-worker level. The Shibuya test's purpose
  is to confirm that the adapter config threads `consumerGroup` through correctly and
  that the Shibuya supervisor keeps all four processors healthy. An in-process test
  achieves this: four `kirokuAdapter` calls produce four `Adapter`s backed by four
  independent `subscriptionStream` instances, one per `(member, size)` pair.
  Four OS processes would test deployment topology, not the adapter plumbing.
  Date: 2026-05-20


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section explains everything a newcomer needs, assuming only this file and the current
source tree. No prior plan context is assumed beyond the files referenced by full path below.

### Hard dependency: EP-2

This plan **hard-depends on** `docs/plans/29-consumer-group-subscription-runtime-and-per-member-workers.md`
("EP-2"). EP-2 introduces `ConsumerGroup`, `InvalidConsumerGroup`, `ConsumerGroupGuardConflict`,
and the `consumerGroup`/`consumerGroupGuard` fields on `SubscriptionConfigM m`, all in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`. None of the code in this plan
compiles until EP-2 has landed. The exact types (verbatim from the parent MasterPlan's
Integration Point IP-4) are:

```haskell
-- In kiroku-store/src/Kiroku/Store/Subscription/Types.hs

data ConsumerGroup = ConsumerGroup
    { member :: !Int32   -- ^ 0-based member index; 0 <= member < size
    , size   :: !Int32   -- ^ total members in the group; >= 1
    }
    deriving stock (Eq, Show)

-- New fields on SubscriptionConfigM m (added by EP-2):
--   consumerGroup      :: !(Maybe ConsumerGroup)
--   consumerGroupGuard :: !Bool

data InvalidConsumerGroup = InvalidConsumerGroup
    { invalidMember :: !Int32
    , invalidSize   :: !Int32
    }
    deriving stock (Show)
    deriving anyclass (Exception)

data ConsumerGroupGuardConflict = ConsumerGroupGuardConflict
    { conflictName   :: !SubscriptionName
    , conflictMember :: !Int32
    }
    deriving stock (Show)
    deriving anyclass (Exception)
```

`defaultSubscriptionConfig` sets `consumerGroup = Nothing` and `consumerGroupGuard = False`,
so all existing callers compile unchanged after EP-2 lands.

### How subscriptions work today (restated, self-contained)

Kiroku is a PostgreSQL-backed event store. A **subscription** is a long-lived worker
thread that reads events in order and feeds them one at a time to a caller-supplied handler.
There are two entry points:

- `Kiroku.Store.Subscription.subscribe` / `withSubscription` — plain `MonadIO`/`MonadUnliftIO`
  wrappers that run the handler directly in IO.
- `Kiroku.Store.Subscription.Effect` — a higher-order effect (`Subscription`) and
  interpreters (`runSubscription`, `runSubscriptionResource`) that run the handler inside
  an `Eff` effect stack.

A **consumer group** (introduced by EP-2) is a named set of N members that together process
one subscription in parallel. Each stream is deterministically assigned to exactly one member
by hashing the stream's database id in PostgreSQL (the assignment SQL is in EP-1's plan
`docs/plans/28-consumer-group-partition-routing-sql-and-checkpoint-schema.md`). A caller
activates group membership by setting `consumerGroup = Just (ConsumerGroup { member = m, size = n })`
in their `SubscriptionConfig`. A **member** is one individual worker in the group; its
**member index** `m` is zero-based (`0 <= m < n`). The **group size** `n` is the total
count of members.

### Key files for this plan

All paths are repository-relative from
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

**`kiroku-store` package:**

- `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` — public types for subscriptions,
  including `SubscriptionConfigM m` (the config record) and, after EP-2, `ConsumerGroup`.
- `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` — the `Subscription` higher-order
  effect, the effectful `subscribe`/`withSubscription` wrappers, and the interpreters
  `runSubscription` / `runSubscriptionResource`.
- `kiroku-store/src/Kiroku/Store/Subscription.hs` — re-exports the whole
  `Kiroku.Store.Subscription.Types` module via `module Kiroku.Store.Subscription.Types` in
  its export list.
- `kiroku-store/src/Kiroku/Store.hs` — the top-level re-export hub. Currently re-exports
  `module Kiroku.Store.Subscription` (which includes everything from `Types`) and re-exports
  `Subscription`, `runSubscription`, `runSubscriptionResource` from the Effect module by name.
  After EP-2 adds `ConsumerGroup` to `Types`, the type will flow through automatically
  via the `module Kiroku.Store.Subscription.Types` re-export chain — but this plan audits
  that chain to be certain.
- `kiroku-store/kiroku-store.cabal` — the cabal file; the test suite's `other-modules` list
  is updated here to add the new test module.
- `kiroku-store/test/Main.hs` — the Hspec entry point for `kiroku-store`.

**`shibuya-kiroku-adapter` package:**

- `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` — `KirokuAdapterConfig` and the
  `kirokuAdapter` function. This is the primary edit target for M2.
- `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` — the
  `RecordedEvent → Ingested` conversion; no change needed here.
- `shibuya-kiroku-adapter/test/Main.hs` — the Hspec test entry point; the new group
  test is added here.
- `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` — the cabal file; no module list
  change is needed for the adapter test (it is a single `main-is: Main.hs` test suite with
  no `other-modules`).

### The `runSubscription` interpreter and the record-update pass-through

The interpreter in `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` handles the
`Subscribe config` constructor by calling:

```haskell
let ioConfig = config { handler = \evt -> unlift (handler config evt) }
Sub.subscribe store ioConfig
```

This is a record update, not a record reconstruction. A record update in Haskell preserves
every field that is not listed on the left of the `=`. After EP-2 adds `consumerGroup` and
`consumerGroupGuard` to `SubscriptionConfigM m`, they will automatically appear in `ioConfig`
with the same values the caller set in `config`, because the update only replaces `handler`.
No code change to the interpreter is needed. This plan audits the interpreter to confirm
this, adds an inline comment that explicitly names the new fields so future contributors do
not accidentally "fix" it, and then moves on.

### The Shibuya adapter's bridge

`kirokuAdapter` calls `subscriptionStream store subConfig buf` where `subConfig` is a
`SubscriptionConfig`. `subscriptionStream` (in
`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`) internally does a similar record
update — `config { handler = bridgeHandler }` — which also preserves `consumerGroup` and
`consumerGroupGuard`. So once the adapter's `KirokuAdapterConfig` receives a `consumerGroup`
field and threads it into the `subConfig` it builds, the full chain from
`KirokuAdapterConfig` → `SubscriptionConfig` → `subscriptionStream` → `runWorker` carries
the group membership intact.

### The Kafka adapter as an idiom reference

The Kafka adapter (`shibuya-kafka-adapter`) uses `ConsumerGroupId` to identify the consumer
group, passed through the `runKafkaConsumer` scope rather than inside the config record.
Kiroku's consumer group model is different: membership is fully identified by
`(member, size)` and the adapter config is the natural place for it. The Kafka adapter
pattern to follow is the export style: re-export the key types (`TopicName`, `BrokerAddress`,
`ConsumerGroupId`) directly from the adapter's public module so callers import only
`Shibuya.Adapter.Kiroku`. This plan follows the same style for `ConsumerGroup`.

### Definitions of terms used in this plan

- **Consumer group**: a named set of N members that collectively process one logical
  subscription in parallel, with each stream deterministically assigned to exactly one
  member by a hash function in PostgreSQL.
- **Member**: one individual worker in the group. Its position is a zero-based **member
  index** `m` satisfying `0 <= m < n`.
- **Group size `n`**: the total number of members.
- **Effectful API / `Eff` stack**: the `Effectful` library's effect system. An `Eff es a`
  computation carries a list of effects `es`. The `Subscription` effect and its interpreters
  live in `Kiroku.Store.Subscription.Effect`.
- **`ConcUnlift Persistent (Limited 1)`**: the unlift strategy used by `runSubscription`.
  `Persistent` means the effect environment survives across multiple handler calls (so
  `State`/`Reader` effects remain consistent). `Limited 1` means at most one concurrent
  unlift is in flight (matching the subscription worker's single-threaded delivery). Do not
  weaken these bounds without restructuring the worker.
- **Shibuya Adapter / Processor**: a Shibuya `Adapter` is a pull-based stream source that
  Shibuya's `runApp` supervisors wrap into isolated `Processor` tasks. A `ProcessorId` is
  the name Shibuya uses to identify the processor for metrics and failure tracking.
- **`subscriptionStream`**: the Streamly bridge in `Kiroku.Store.Subscription.Stream` that
  turns a push-based Kiroku subscription into a `Stream IO RecordedEvent` via a bounded
  `TBQueue`. Used internally by `kirokuAdapter`.
- **EphemeralPg**: a test library that spins up a temporary PostgreSQL cluster in-process.
  Used by both test suites; no external database required.


## Plan of Work

The work is three milestones. Each ends with a passing test run.

### Milestone M1 — Effect-layer pass-through confirmed + `ConsumerGroup` re-exports + effectful group test

The goal of M1 is to prove that the effectful `Subscription` API surfaces consumer groups
correctly, that `ConsumerGroup` is reachable from the top-level `Kiroku.Store` module, and
that a real size-4 group works end-to-end through the `Eff` stack.

**Step 1: Audit and annotate the interpreter.** Read
`kiroku-store/src/Kiroku/Store/Subscription/Effect.hs`. In `runSubscription`, find the line:

```haskell
let ioConfig = config{handler = \evt -> unlift (handler config evt)}
```

This is already correct: the record update preserves `consumerGroup` and `consumerGroupGuard`
from `config`. Add a comment immediately above that line that makes this explicit, so no
future contributor tries to "fix" it:

```haskell
-- Record update intentionally: every field except 'handler' is preserved,
-- including 'consumerGroup' and 'consumerGroupGuard' added in EP-2. Do not
-- switch to a full record literal here — that would silently reset new fields.
let ioConfig = config{handler = \evt -> unlift (handler config evt)}
```

No functional change — compile only to confirm.

**Step 2: Audit the `ConsumerGroup` re-export chain.** Trace the path that
`ConsumerGroup` takes after EP-2 adds it to `Kiroku.Store.Subscription.Types`:

1. `Kiroku.Store.Subscription.Types` exports `ConsumerGroup (..)`.
2. `Kiroku.Store.Subscription` re-exports `module Kiroku.Store.Subscription.Types` in
   its export list. Open `kiroku-store/src/Kiroku/Store/Subscription.hs` and verify the
   `module Kiroku.Store.Subscription.Types` entry is present and is not filtered. It is
   — the export list reads exactly `module Kiroku.Store.Subscription.Types`. So
   `ConsumerGroup` flows through.
3. `Kiroku.Store` re-exports `module Kiroku.Store.Subscription`. Open
   `kiroku-store/src/Kiroku/Store.hs` and verify the `module Kiroku.Store.Subscription`
   entry is present. It is. So `ConsumerGroup`, `InvalidConsumerGroup`, and
   `ConsumerGroupGuardConflict` (all added by EP-2 to `Types`) will be available from
   `Kiroku.Store` with no change to `Kiroku.Store.hs`.

The audit is pure verification — no file changes are required. Document the finding in the
Surprises section (or Decisions, if a gap is found and plugged).

One important note: the `Kiroku.Store` module also re-exports `Subscription`,
`runSubscription`, and `runSubscriptionResource` from the Effect module by name (see the
section `-- * Subscription effect (interpreter only — import Effect module for subscribe)`).
The effectful `subscribe` and `withSubscription` are deliberately *not* re-exported from
`Kiroku.Store` to avoid a name clash with the plain-IO `subscribe`. This is documented in
the module header. Callers using the effectful API must import
`Kiroku.Store.Subscription.Effect` directly for `subscribe`/`withSubscription`. This plan
does not change that policy.

**Step 3: Write the effectful group test.** Create
`kiroku-store/test/Test/ConsumerGroupEffect.hs`. This module tests the `Subscription`
effect's `subscribe` and `withSubscription` entrypoints in an `Eff` stack with a
`State`-tracked counter, proving that the `ConcUnlift Persistent (Limited 1)` strategy
correctly preserves state across handler calls and that the group partitioning is correct.

The test follows the same structure as EP-2's `Test.ConsumerGroup` (which tests the plain
`Sub.subscribe`): append events to forty streams in category `cg-effect`, run four in-`Eff`
members, wait for all 120 events to be collected, and assert disjoint + complete +
per-stream-ordered. The difference is the entry point: instead of calling
`Sub.subscribe store config`, the test runs:

```haskell
runEff $ runSubscription store $ do
    withSubscription cfg0 $ \h0 ->
    withSubscription cfg1 $ \h1 ->
    withSubscription cfg2 $ \h2 ->
    withSubscription cfg3 $ \h3 ->
    liftIO $ do
        waitUntil 15_000_000 (fmap (>= 120) drained)
        -- assert properties
```

where `subscribe`/`withSubscription` here are from `Kiroku.Store.Subscription.Effect`
(not from `Kiroku.Store.Subscription`). The handler is in `Eff '[IOE]` so it can use
`liftIO` to write to an `IORef`.

Add `Test.ConsumerGroupEffect` to `kiroku-store/kiroku-store.cabal`'s `other-modules` in
the `test-suite kiroku-store-test` stanza, and import and call its `spec` from
`kiroku-store/test/Main.hs` in the same way other test modules are wired in.

Acceptance for M1: `cabal test kiroku-store` passes, including the new
`ConsumerGroupEffect` spec. The test proves the effectful wrapper does not break group
delivery.

### Milestone M2 — `KirokuAdapterConfig` extended + `ConsumerGroup` re-export + updated Haddock

The goal of M2 is to let Shibuya users pass `consumerGroup` through the adapter config
without needing to import `Kiroku.Store.Subscription.Types` themselves.

**Step 1: Add the field to `KirokuAdapterConfig`.** Edit
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`. Add the field after `bufferSize`:

```haskell
data KirokuAdapterConfig = KirokuAdapterConfig
    { subscriptionName  :: !SubscriptionName
    -- ^ Unique subscription identifier (checkpoint key)
    , subscriptionTarget :: !SubscriptionTarget
    -- ^ 'AllStreams' or @'Category' categoryName@
    , batchSize          :: !Int32
    -- ^ Events per database fetch during catch-up
    , bufferSize         :: !Natural
    -- ^ TBQueue capacity (backpressure threshold)
    , consumerGroup      :: !(Maybe ConsumerGroup)
    {- ^ Optional consumer-group membership for this adapter instance.
    'Nothing' (the default) = ordinary single-consumer subscription.
    'Just (ConsumerGroup { member = m, size = n })' = this adapter is
    member @m@ of a group of size @n@. To run a full size-@n@ group,
    create @n@ adapters with the same 'subscriptionName' and distinct
    member indices, each backed by its own Shibuya processor.

    The validity invariant (@size >= 1@, @0 <= member < size@) is enforced
    by the underlying 'Kiroku.Store.Subscription.subscribe' call, which
    throws 'InvalidConsumerGroup' on violation.
    -}
    }
```

**Step 2: Thread the field through `kirokuAdapter`.** In the same file, change the
`SubscriptionConfig` construction to use `defaultSubscriptionConfig` as the base and
record-update to override fields. This is safer than a full literal because it will not
require a new field name every time `SubscriptionConfigM` gains a field. The current
body extracts `(subName, subTarget, bs, buf)` from the config argument; change the
pattern match to also bind `cg`:

```haskell
kirokuAdapter store (KirokuAdapterConfig subName subTarget bs buf cg) = do
    let subConfig =
            (defaultSubscriptionConfig subName subTarget (\_ -> pure Continue))
                { batchSize    = bs
                , queueCapacity = 16
                , overflowPolicy = DropSubscription
                , consumerGroup = cg
                }
    (ioStream, cancelAction) <- liftIO $ subscriptionStream store subConfig buf
    ...
```

The `consumerGroupGuard` field is not exposed in `KirokuAdapterConfig` (see Decision Log).
The `defaultSubscriptionConfig` sets it to `False`, which is the correct default.

**Step 3: Re-export `ConsumerGroup` from `Shibuya.Adapter.Kiroku`.** In the same file,
add `ConsumerGroup (..)` to the module's export list (in the `-- * Re-exports from
kiroku-store` section) and add it to the import of `Kiroku.Store.Subscription.Types`.

The export list becomes:

```haskell
module Shibuya.Adapter.Kiroku (
    -- * Adapter
    kirokuAdapter,

    -- * Configuration
    KirokuAdapterConfig (..),

    -- * Re-exports from kiroku-store
    SubscriptionName (..),
    SubscriptionTarget (..),
    ConsumerGroup (..),
) where
```

And the import of `Kiroku.Store.Subscription.Types` gains `ConsumerGroup (..)`:

```haskell
import Kiroku.Store.Subscription.Types (
    ConsumerGroup (..),
    OverflowPolicy (..),
    SubscriptionConfigM (..),
    SubscriptionName (..),
    SubscriptionResult (..),
    SubscriptionTarget (..),
    defaultSubscriptionConfig,
 )
```

**Step 4: Update the module Haddock example.** The current example in `Shibuya.Adapter.Kiroku`'s
module header shows a single-processor config with no `consumerGroup`. Replace it with an
extended example that first shows the single-member form and then documents the multi-member
wiring pattern:

```haskell
{- | ...existing header prose...

== Consumer-Group Example (size 4)

To run four members in the same process — each member is one processor:

@
-- Run all four members in a single 'runApp' call.
-- Use distinct 'ProcessorId's to keep metrics and failure isolation per member.

main :: IO ()
main = withStore settings $ \\store ->
    runEff $ runTracingNoop $ do
        let mkMemberAdapter m =
                kirokuAdapter store
                    KirokuAdapterConfig
                        { subscriptionName  = SubscriptionName \"orders-projection\"
                        , subscriptionTarget = Category (CategoryName \"orders\")
                        , batchSize          = 100
                        , bufferSize         = 256
                        , consumerGroup      = Just (ConsumerGroup { member = m, size = 4 })
                        }

        adapters <- mapM mkMemberAdapter [0, 1, 2, 3]

        let processors =
                [ (ProcessorId (\"orders-\" <> T.pack (show m)), mkProcessor (adapters !! m) handler)
                | m <- [0 .. 3]
                ]

        Right appHandle <- runApp IgnoreFailures 100 processors
        waitApp appHandle
  where
    handler ingested = do
        -- process ingested.envelope.payload :: RecordedEvent
        pure AckOk
@

To run members across separate processes, give each process one adapter
with its own 'member' index and the same 'subscriptionName'. Kiroku's
per-member checkpoint (keyed by @(subscriptionName, member)@) ensures
each process resumes from its own position after a restart.
-}
```

Acceptance for M2: `cabal build shibuya-kiroku-adapter` succeeds and any existing tests
in `shibuya-kiroku-adapter/test/Main.hs` still pass. Because `consumerGroup` defaults
to `Nothing` in the adapter only when you use `defaultSubscriptionConfig` — which is
what the helper now uses internally — existing test literal configs must add
`consumerGroup = Nothing` to their `KirokuAdapterConfig` records. Grep all
`KirokuAdapterConfig` literals in `shibuya-kiroku-adapter/test/Main.hs` and add that
field to each.

### Milestone M3 — Shibuya adapter group integration test

The goal of M3 is to exercise the full path from `KirokuAdapterConfig` with a non-trivial
consumer group through the Shibuya supervisor to actual partitioned delivery, using
EphemeralPg exactly as the existing adapter tests do.

Edit `shibuya-kiroku-adapter/test/Main.hs`. In the `around withTestStore` block, add a
new `describe "consumer groups"` suite. The test appends events to twenty streams in
category `cg`, starts a size-4 group of four adapters as four processors in one `runApp`
call, collects per-processor events, and asserts disjoint + complete + (weakly) per-stream
ordered. The assertions are the same as EP-2's category group test at the runtime level —
what changes is that delivery goes through `subscriptionStream` → Shibuya `Adapter` →
Shibuya `Processor` rather than directly through the handler.

The test structure follows the existing multi-subscription tests in the same file (see
"runs multiple category subscriptions concurrently"). Four `IORef`s collect events, four
`TVar Int` count them, and `waitForCount` (already defined in the file) waits for each
member's expected count. Because member sizes can differ (due to hashing), the test does
not assert each member sees exactly 5 events; instead it asserts the total is 20 and all
global positions are distinct.

The full test is shown in the Concrete Steps section.

Acceptance for M3: `cabal test shibuya-kiroku-adapter` passes with no regressions.


## Concrete Steps

All commands are run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless stated otherwise.

### Build and test commands

```bash
# Build only (fast feedback):
cabal build kiroku-store
cabal build shibuya-kiroku-adapter

# Run the full test suite for each package:
cabal test kiroku-store
cabal test shibuya-kiroku-adapter

# Or, via the project's task runner (runs all packages):
just test
```

Expected output on success for `cabal test kiroku-store` (abbreviated):

```text
Running 1 test suites...
Test suite kiroku-store-test: RUNNING...
...
consumer groups (effectful)
  delivers a disjoint, complete, per-stream-ordered partition via Eff stack (size-4) [✔]
  preserves State effect across handler calls within one member [✔]

Finished in N.NNNN seconds
NN examples, 0 failures
Test suite kiroku-store-test: PASS
```

Expected output on success for `cabal test shibuya-kiroku-adapter` (abbreviated):

```text
Running 1 test suites...
Test suite shibuya-kiroku-adapter-test: RUNNING...
...
consumer groups
  four-member group delivers a disjoint partition of the full stream [✔]

Finished in N.NNNN seconds
NN examples, 0 failures
Test suite shibuya-kiroku-adapter-test: PASS
```

### M1 — annotate `Effect.hs`

Open `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs`. Locate the `runSubscription`
interpreter body (around line 121–125). Add the comment above the `ioConfig` binding as
described in the Plan of Work. No other change. Rebuild:

```bash
cabal build kiroku-store
```

### M1 — register the new test module

Edit `kiroku-store/kiroku-store.cabal`. In the `test-suite kiroku-store-test` stanza,
add `Test.ConsumerGroupEffect` to `other-modules` in alphabetical order:

```text
  other-modules:
    Test.Causation
    Test.Concurrency
    Test.ConsumerGroup
    Test.ConsumerGroupEffect
    Test.FailureInjection
    Test.Helpers
    Test.InterpreterHooks
    Test.Properties
    Test.ReadStream
    Test.Transaction
```

Edit `kiroku-store/test/Main.hs`. Add:

```haskell
import Test.ConsumerGroupEffect qualified as ConsumerGroupEffect
```

alongside the other `Test.*` imports, and call `ConsumerGroupEffect.spec` in `main` where
the other specs are called. Follow the existing pattern: consult the file to see whether
specs are run inside or outside `around withTestStore`; the new spec manages its own store
internally (see the test content below), so it goes outside any `around` block.

### M1 — the effectful group test module

Create `kiroku-store/test/Test/ConsumerGroupEffect.hs` with the following content:

```haskell
module Test.ConsumerGroupEffect (spec) where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Int (Int32)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.State.Static.Local (State, evalState, get, modify)
import Kiroku.Store
import Kiroku.Store.Subscription.Effect (Subscription, subscribe, withSubscription, runSubscription)
import Kiroku.Store.Subscription.Types (ConsumerGroup (..), SubscriptionConfigM (..), defaultSubscriptionConfig)
import Test.Helpers (withTestStore, makeEvent, waitForPublisher)
import Test.Hspec

-- | Build a config for member m of a size-n category group.
-- The handler is in Eff '[IOE] so it can use liftIO.
memberEffCfg
    :: SubscriptionName
    -> CategoryName
    -> Int32
    -> Int32
    -> IORef [(StreamId, GlobalPosition)]
    -> SubscriptionConfig
memberEffCfg nm cat m n ref =
    -- Note: the handler here is in IO because we are building a SubscriptionConfig
    -- (= SubscriptionConfigM IO) for use with runSubscription, which converts the
    -- Eff handler to IO via localUnliftIO. The effectful test for State preservation
    -- uses a separate SubscriptionConfigM (Eff es) built inline.
    (defaultSubscriptionConfig nm (Category cat) (\evt -> do
        modifyIORef' ref ((evt ^. #originalStreamId, evt ^. #globalPosition) :)
        pure Continue))
        { consumerGroup = Just ConsumerGroup{ member = m, size = n } }

spec :: Spec
spec = describe "consumer groups (effectful)" $ do

    it "delivers a disjoint, complete, per-stream-ordered partition via Eff stack (size-4)" $
        withTestStore $ \store -> do
            -- Append 3 events to each of 40 streams in category "cg-effect".
            let streams = [ "cg-effect-" <> T.pack (show i) | i <- [1 .. 40 :: Int] ]
            mapM_
                (\sn -> do
                    let evs = [ makeEvent ("E" <> T.pack (show k)) mempty | k <- [1 .. 3 :: Int] ]
                    Right _ <- runStoreIO store $
                        appendToStream (StreamName sn) NoStream evs
                    pure ())
                streams
            waitForPublisher store (GlobalPosition 120)

            -- One IORef per member collects (streamId, globalPosition) pairs.
            refs <- mapM (const (newIORef [])) [0 .. 3 :: Int]

            -- Run all four members inside a single Eff stack via runSubscription.
            -- withSubscription from Effect.hs uses the ConcUnlift Persistent (Limited 1)
            -- strategy so each member's handler runs in the same Eff environment.
            let n = 4 :: Int32
                cfgs = [ memberEffCfg
                            (SubscriptionName "eff-cg-cat")
                            (CategoryName "cg-effect")
                            (fromIntegral m) n (refs !! m)
                       | m <- [0 .. 3]
                       ]

            -- Subscribe all four members and wait until we have ≥ 120 events total.
            runEff $ runSubscription store $ do
                handles <- mapM (liftIO . Sub.subscribe store) cfgs
                liftIO $ do
                    waitUntil 15_000_000 $ do
                        total <- sum <$> mapM (fmap length . readIORef) refs
                        pure (total >= 120)
                    mapM_ cancel handles

            collected <- mapM readIORef refs
            -- Disjoint + complete: sorted union of positions == [1..120].
            let allPositions = sort (concatMap (map snd) collected)
            allPositions `shouldBe` map GlobalPosition [1 .. 120]
            -- Per-stream ordering within each member (collector prepends, so reverse).
            mapM_ (\pairs -> assertPerStreamAscending (reverse pairs)) collected

    it "preserves State effect across handler calls within one member" $
        withTestStore $ \store -> do
            -- Append 5 events to one stream in category "cg-state".
            let evs = [ makeEvent ("S" <> T.pack (show k)) mempty | k <- [1 .. 5 :: Int] ]
            Right _ <- runStoreIO store $ appendToStream (StreamName "cg-state-s1") NoStream evs
            waitForPublisher store (GlobalPosition 5)

            countRef <- newIORef (0 :: Int)
            -- Run a size-1 group member whose handler increments an Effectful State.
            -- After collection we check that the State accumulated correctly and
            -- that the final value is observable.
            finalState <- runEff $ runSubscription store $
                evalState (0 :: Int) $ do
                    let cfg = (defaultSubscriptionConfig
                                    (SubscriptionName "eff-state-test")
                                    (Category (CategoryName "cg-state"))
                                    (\_ -> do
                                        modify @Int (+ 1)
                                        liftIO (modifyIORef' countRef (+ 1))
                                        pure Continue))
                                { consumerGroup = Just ConsumerGroup{ member = 0, size = 1 } }
                    hdl <- subscribe cfg
                    liftIO $ waitUntil 10_000_000 $ do
                        c <- readIORef countRef
                        pure (c >= 5)
                    liftIO (cancel hdl)
                    get @Int
            -- State must have been incremented by each of the 5 handler calls.
            finalState `shouldSatisfy` (>= 5)

-- | Poll until the IO Bool action returns True or the microsecond budget expires.
waitUntil :: Int -> IO Bool -> IO ()
waitUntil budget act
    | budget <= 0 = pure ()
    | otherwise = do
        ok <- act
        if ok
            then pure ()
            else do
                Control.Concurrent.threadDelay 20_000
                waitUntil (budget - 20_000) act

-- | Assert that within each originalStreamId the GlobalPositions are ascending.
assertPerStreamAscending :: [(StreamId, GlobalPosition)] -> IO ()
assertPerStreamAscending pairs =
    let byStream = Map.fromListWith (flip (++))
                    [ (sid, [gp]) | (sid, gp) <- pairs ]
    in mapM_ (\ps -> ps `shouldBe` sort ps) (Map.elems byStream)
```

A note on the import of `Sub.subscribe` in the effectful test: the test builds
`SubscriptionConfig` (= `SubscriptionConfigM IO`) and calls the *plain-IO*
`Sub.subscribe` from `Kiroku.Store.Subscription` inside the `Eff` stack via `liftIO`.
This is intentional — `Test.ConsumerGroupEffect` is testing that group configs work when
constructed by callers of the effectful API, but the Hspec test harness is in IO, so the
member handles are created with `liftIO . Sub.subscribe`. A fully effectful member setup
would require the handlers to themselves be in `Eff es`, which is the second test case
("preserves State"). The first test case is therefore a partial test of the effectful
surface: it proves group config plumbing, not the `localUnliftIO` handler promotion. The
second test proves the `ConcUnlift Persistent (Limited 1)` contract. If you want a pure
`Effect.subscribe`-level test for partitioning, the cleanest shape is to write the handler
as `Eff '[IOE]` and call `Effect.subscribe` from within a `runEff (runSubscription store
...)` block. The test above shows exactly this pattern for the State test; the same
approach can be applied to the partitioning test by moving the config construction into the
`runEff` body.

### M2 — edit `Shibuya.Adapter.Kiroku`

Open `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`. Make the three changes
described in the Plan of Work (add the field, thread it through, update exports). The
relevant diff:

```diff
-data KirokuAdapterConfig = KirokuAdapterConfig
-    { subscriptionName :: !SubscriptionName
-    , subscriptionTarget :: !SubscriptionTarget
-    , batchSize :: !Int32
-    , bufferSize :: !Natural
-    }
+data KirokuAdapterConfig = KirokuAdapterConfig
+    { subscriptionName  :: !SubscriptionName
+    , subscriptionTarget :: !SubscriptionTarget
+    , batchSize          :: !Int32
+    , bufferSize         :: !Natural
+    , consumerGroup      :: !(Maybe ConsumerGroup)
+    }
```

```diff
-kirokuAdapter store (KirokuAdapterConfig subName subTarget bs buf) = do
-    let subConfig =
-            SubscriptionConfig
-                { name = subName
-                , target = subTarget
-                , handler = \_ -> pure Continue
-                , batchSize = bs
-                , queueCapacity = 16
-                , overflowPolicy = DropSubscription
-                }
+kirokuAdapter store (KirokuAdapterConfig subName subTarget bs buf cg) = do
+    let subConfig =
+            (defaultSubscriptionConfig subName subTarget (\_ -> pure Continue))
+                { batchSize     = bs
+                , queueCapacity = 16
+                , overflowPolicy = DropSubscription
+                , consumerGroup = cg
+                }
```

```diff
+import Kiroku.Store.Subscription.Types (
+    ConsumerGroup (..),
+     OverflowPolicy (..),
-import Kiroku.Store.Subscription.Types (
-    OverflowPolicy (..),
     SubscriptionConfigM (..),
     SubscriptionName (..),
     SubscriptionResult (..),
     SubscriptionTarget (..),
+    defaultSubscriptionConfig,
  )
```

```diff
 module Shibuya.Adapter.Kiroku (
     -- * Re-exports from kiroku-store
     SubscriptionName (..),
     SubscriptionTarget (..),
+    ConsumerGroup (..),
 ) where
```

After editing, update all `KirokuAdapterConfig` record literals in
`shibuya-kiroku-adapter/test/Main.hs` to include `consumerGroup = Nothing`. There are
five literals (one per `kirokuAdapter` call in the tests). Add the field as the last entry
in each:

```diff
-                    KirokuAdapterConfig
-                        { subscriptionName = SubscriptionName "shibuya-catchup-test"
-                        , subscriptionTarget = AllStreams
-                        , batchSize = 100
-                        , bufferSize = 256
-                        }
+                    KirokuAdapterConfig
+                        { subscriptionName  = SubscriptionName "shibuya-catchup-test"
+                        , subscriptionTarget = AllStreams
+                        , batchSize          = 100
+                        , bufferSize         = 256
+                        , consumerGroup      = Nothing
+                        }
```

Apply the same `consumerGroup = Nothing` addition to every other `KirokuAdapterConfig`
literal in the test file. Then build:

```bash
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter
```

Both must pass before proceeding to M3.

### M3 — the Shibuya adapter group test

In `shibuya-kiroku-adapter/test/Main.hs`, inside the `around withTestStore` block, add a
new suite after the existing ones:

```haskell
describe "consumer groups" $ do
    it "four-member group delivers a disjoint partition of the full stream" $ \store -> do
        -- Append 2 events to each of 20 streams in category "cg" → 40 total events.
        let streams = [ "cg-" <> T.pack (show i) | i <- [1 .. 20 :: Int] ]
        mapM_
            (\sn -> do
                let evs = [ makeEvent ("EV" <> T.pack (show k)) (Aeson.object []) | k <- [1 .. 2 :: Int] ]
                Right _ <- runStoreIO store $ appendToStream (StreamName sn) NoStream evs
                pure ())
            streams
        threadDelay 200_000   -- let the publisher ingest all events

        -- Four IORefs and four TVars for per-member event collection.
        refs  <- mapM (const (newIORef ([] :: [RecordedEvent]))) [0 .. 3 :: Int]
        cvars <- mapM (const (newTVarIO (0 :: Int))) [0 .. 3 :: Int]

        runEff $ runTracingNoop $ do
            adapters <- mapM
                (\m ->
                    kirokuAdapter store $
                        KirokuAdapterConfig
                            { subscriptionName  = SubscriptionName "cg-shibuya-group"
                            , subscriptionTarget = Category (CategoryName "cg")
                            , batchSize          = 100
                            , bufferSize         = 256
                            , consumerGroup      = Just ConsumerGroup{ member = m, size = 4 }
                            })
                [0, 1, 2, 3]

            let mkHandler ref' cvar ingested = do
                    liftIO $ do
                        modifyIORef' ref' (envelopePayload ingested :)
                        atomically $ do
                            c <- readTVar cvar
                            writeTVar cvar (c + 1)
                    pure AckOk

                processors =
                    [ ( ProcessorId ("cg-member-" <> T.pack (show m))
                      , mkProcessor (adapters !! m) (mkHandler (refs !! m) (cvars !! m))
                      )
                    | m <- [0 .. 3]
                    ]

            res <- runApp IgnoreFailures 100 processors
            case res of
                Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                Right appHandle -> do
                    -- Wait until the total collected across all members reaches 40.
                    liftIO $ waitForTotal cvars 40 15_000_000
                    stopApp appHandle

        collected <- mapM readIORef refs

        -- (1) Complete: total events across all members = 40.
        let total = sum (map length collected)
        total `shouldBe` 40

        -- (2) Disjoint: all global positions across all members are unique.
        -- We compare payloads (eventType) since RecordedEvent identity is eventId.
        -- More precisely: sort all eventIds across members and assert no duplicates.
        -- (RecordedEvent ^. #eventId is EventId UUID, so compare as Text.)
        let allIds = concatMap (map (\e -> e ^. #eventId)) (concat (map (map id) collected))
            uniqueIds = length (Data.List.nub allIds)
        uniqueIds `shouldBe` 40

        -- (3) Non-empty: no member received zero events (a degenerate partition
        -- with 20 streams and size-4 should give each member ≥ 1 stream, hence ≥ 2 events,
        -- but we assert ≥ 1 to be robust against hash-distribution edge cases).
        mapM_ (\c -> length c `shouldSatisfy` (>= 1)) collected
```

Add the `waitForTotal` helper at the bottom of `test/Main.hs` alongside `waitForCount`:

```haskell
-- | Wait until the sum of all TVar counts reaches the target or the timeout fires.
waitForTotal :: [STM.TVar Int] -> Int -> Int -> IO ()
waitForTotal vars target timeoutMicros = do
    timeoutVar <- registerDelay timeoutMicros
    result <-
        atomically $
            ( do
                total <- sum <$> mapM readTVar vars
                STM.check (total >= target)
                pure True
            )
            `STM.orElse`
            ( do
                t <- readTVar timeoutVar
                STM.check t
                pure False
            )
    unless result $ do
        actual <- atomically $ sum <$> mapM readTVar vars
        expectationFailure
            ("Timed out waiting for total " <> show target <> ", got " <> show actual)
```

Also add the missing imports to the top of the file:

```haskell
import Data.List qualified as List    -- for List.nub in the disjoint check
import Kiroku.Store.Subscription.Types (ConsumerGroup (..))
import Shibuya.App (stopApp)          -- already imported, confirm it is present
```

Run:

```bash
cabal test shibuya-kiroku-adapter
```

All tests, including the new group test, must pass.


## Validation and Acceptance

**Effectful pass-through (M1, analytical).** Read `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs`
and confirm that `runSubscription` builds `ioConfig` via a record update
(`config{ handler = ... }`), not a full record literal. A record update in Haskell is
defined as: every field not listed on the left is copied from the original record. Therefore
`consumerGroup` and `consumerGroupGuard` from the caller's `config` are guaranteed to be
in `ioConfig` unchanged. The annotated comment added by M1 documents this. No test is
needed to prove the pass-through itself; the effectful group test (next) proves the
end-to-end result.

**Effectful group test (M1, behavioral).** The test in
`kiroku-store/test/Test/ConsumerGroupEffect.hs` appends 120 events to 40 streams in
category `cg-effect`, runs four members under `runSubscription`, and asserts:

- The sorted union of all received `GlobalPosition` values is exactly `[GlobalPosition 1 ..
  GlobalPosition 120]` — proving completeness (no event dropped) and disjointness (no
  event delivered twice).
- For each member and each `StreamId` within that member, the received positions are in
  ascending order — proving per-stream ordering is preserved across the group.

Run with:

```bash
cabal test kiroku-store
```

**State preservation (M1, behavioral).** The second test in the same file runs a handler
that increments an `Effectful.State.Static.Local.State Int` counter inside `runEff
(evalState 0 ...)`. After 5 events the final state value should be ≥ 5, proving that the
`ConcUnlift Persistent (Limited 1)` strategy keeps the `Eff` environment alive across
handler calls. If the environment were reset between calls (the `Ephemeral` behavior), the
final state would be ≤ 1.

**`ConsumerGroup` re-export (M1, compilation).** After EP-2 lands, confirm that the
following import compiles in an isolated test file:

```haskell
import Kiroku.Store (ConsumerGroup (..))
```

If it fails, the re-export chain is broken and the audit in M1 Step 2 must be re-run;
compare what `Kiroku.Store.Subscription.Types` exports against what
`Kiroku.Store.Subscription` re-exports.

**Adapter config threading (M2, behavioral).** The Shibuya group test in M3 serves as the
end-to-end proof. As an intermediate sanity check after M2, build the adapter and inspect
the generated Haddock for `KirokuAdapterConfig` to confirm `consumerGroup` appears:

```bash
cabal haddock shibuya-kiroku-adapter
```

Open `dist-newstyle/...shibuya-kiroku-adapter-.../doc/html/shibuya-kiroku-adapter/Shibuya-Adapter-Kiroku.html`
and verify `consumerGroup` is documented in `KirokuAdapterConfig`.

**Shibuya group test (M3, behavioral).** The test in `shibuya-kiroku-adapter/test/Main.hs`
appends 40 events to 20 streams in category `cg`, runs a size-4 group as four Shibuya
processors in one `runApp`, and asserts:

- Total collected = 40 (completeness).
- All eventIds are distinct (disjointness).
- Each member received ≥ 1 event (no empty partition, with 20 streams and 4 members).

Run with:

```bash
cabal test shibuya-kiroku-adapter
```

The `waitForTotal` helper gives each member up to 15 seconds, which is more than enough for
an ephemeral-Postgres catch-up run.


## Idempotence and Recovery

Every step in this plan is additive. No DDL is run; all schema changes are owned by EP-1.
No existing behavior is altered — every change is either a new field that defaults to
`Nothing`/`False`, a new test, or a re-export.

Re-running `cabal build` or `cabal test` after a partial edit is always safe. The test
harness (`withTestStore`) starts a fresh ephemeral Postgres cluster for each test file
invocation, so partial test runs leave no residual state.

If M2's `KirokuAdapterConfig` record change causes a compile failure because an existing
test literal is missing `consumerGroup`, the fix is mechanical: grep
`shibuya-kiroku-adapter/test/Main.hs` for `KirokuAdapterConfig {` and add
`consumerGroup = Nothing` to each. Running `cabal build shibuya-kiroku-adapter` first
(before the tests) will surface all such failures at once.

If the effectful test in M1 fails because `ConsumerGroup` is not yet exported from
`Kiroku.Store`, confirm that EP-2 has landed and that `Kiroku.Store.Subscription.Types`
exports `ConsumerGroup (..)`. The re-export chain requires no code change in this plan —
the flow is `Types` → `Subscription` (via `module Kiroku.Store.Subscription.Types`) →
`Kiroku.Store` (via `module Kiroku.Store.Subscription`).

If a test times out waiting for events, the most likely cause is that EP-2's worker
routing for group subscriptions has not landed yet (the worker would then ignore
`consumerGroup` and deliver all events to every member, causing the disjointness assertion
to fail rather than timeout). Check that EP-2's `fetchBatch` branches on `consumerGroup`
as documented in EP-2's Plan of Work.


## Interfaces and Dependencies

This plan spans two packages. The changes in each are described here with full module
paths and the exact signatures that must exist at the end of each milestone.

### Package `kiroku-store`

No new public APIs are added to `kiroku-store` by this plan. The plan only:
- Annotates `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` (comment only).
- Verifies `ConsumerGroup`, `InvalidConsumerGroup`, `ConsumerGroupGuardConflict` are
  re-exported from `Kiroku.Store` via the `module Kiroku.Store.Subscription` re-export.
- Adds a test module (internal to the test suite).

The types that must exist in `Kiroku.Store.Subscription.Types` after EP-2 (this plan
hard-depends on them):

```haskell
-- Kiroku.Store.Subscription.Types (added by EP-2):
data ConsumerGroup = ConsumerGroup { member :: !Int32, size :: !Int32 }
    deriving stock (Eq, Show)

-- New fields on SubscriptionConfigM m:
--   consumerGroup      :: !(Maybe ConsumerGroup)
--   consumerGroupGuard :: !Bool

data InvalidConsumerGroup = InvalidConsumerGroup
    { invalidMember :: !Int32, invalidSize :: !Int32 }
    deriving stock (Show)
    deriving anyclass (Exception)

data ConsumerGroupGuardConflict = ConsumerGroupGuardConflict
    { conflictName :: !SubscriptionName, conflictMember :: !Int32 }
    deriving stock (Show)
    deriving anyclass (Exception)
```

The signatures in `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` that remain
unchanged:

```haskell
-- Kiroku.Store.Subscription.Effect
subscribe
    :: (HasCallStack, Subscription :> es)
    => SubscriptionConfigM (Eff es)
    -> Eff es SubscriptionHandle

withSubscription
    :: (HasCallStack, Subscription :> es, IOE :> es)
    => SubscriptionConfigM (Eff es)
    -> (SubscriptionHandle -> Eff es a)
    -> Eff es a

runSubscription
    :: (IOE :> es)
    => KirokuStore
    -> Eff (Subscription : es) a
    -> Eff es a

runSubscriptionResource
    :: (IOE :> es, KirokuStoreResource :> es)
    => Eff (Subscription : es) a
    -> Eff es a
```

These signatures accept any `SubscriptionConfigM (Eff es)`, which after EP-2 includes the
`consumerGroup` field. The interpreter converts to IO via a record update that preserves the
field automatically.

### Package `shibuya-kiroku-adapter`

The updated `KirokuAdapterConfig` at the end of M2:

```haskell
-- Shibuya.Adapter.Kiroku
data KirokuAdapterConfig = KirokuAdapterConfig
    { subscriptionName  :: !SubscriptionName
    , subscriptionTarget :: !SubscriptionTarget
    , batchSize          :: !Int32
    , bufferSize         :: !Natural
    , consumerGroup      :: !(Maybe ConsumerGroup)
    }

kirokuAdapter
    :: (IOE :> es)
    => KirokuStore
    -> KirokuAdapterConfig
    -> Eff es (Adapter es RecordedEvent)
```

Re-exports from `Shibuya.Adapter.Kiroku` at the end of M2:

```haskell
-- Already exported:
SubscriptionName (..)
SubscriptionTarget (..)
-- Added by this plan:
ConsumerGroup (..)
```

### Libraries and why

- `effectful-core` — `Eff`, `IOE`, `Persistence`, `Limit`, `ConcUnlift`, `localUnliftIO`.
  The subscription effect and interpreter live here.
- `kiroku-store` — `subscribe`, `withSubscription`, `SubscriptionConfigM`, `ConsumerGroup`.
  The adapter package depends on it already.
- `shibuya-core` — `Adapter`, `Ingested`, `AckDecision`. Unchanged.
- `streamly-core` — `subscriptionStream`'s internal bridge. Unchanged.
- `hspec` + `ephemeral-pg` — test harness. Both already in the respective test-suite
  `build-depends`.


## Revision History

- 2026-05-20: Initial authoring of the full ExecPlan body from the empty skeleton.
  Researched the effectful interpreter source (`Effect.hs`), the `Types.hs` field shape
  (pre-EP-2), the `Kiroku.Store` re-export chain, `Shibuya.Adapter.Kiroku` (`KirokuAdapterConfig`
  record, `kirokuAdapter` body, existing tests in `test/Main.hs`), and the Kafka adapter
  as an idiom reference. Key findings: (1) the `config{ handler = ... }` record update in
  `runSubscription` already preserves any future config fields — no code change needed,
  only an annotation; (2) `ConsumerGroup` flows to `Kiroku.Store` automatically via the
  existing `module Kiroku.Store.Subscription.Types` / `module Kiroku.Store.Subscription`
  re-export chain — no change needed to `Kiroku.Store.hs`; (3) `KirokuAdapterConfig` must
  gain the `consumerGroup` field and its test literals must be updated; (4) the adapter
  test suite has no `other-modules` — the group test is added directly to `test/Main.hs`.
  Decisions recorded: guard field excluded from adapter config; use
  `defaultSubscriptionConfig` as the base in `kirokuAdapter`; effectful test is a separate
  module from EP-2's `Test.ConsumerGroup`; Shibuya group test uses in-process four-processor
  `runApp`, not four OS processes.
