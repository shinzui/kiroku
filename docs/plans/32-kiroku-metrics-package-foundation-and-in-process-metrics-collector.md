---
id: 32
slug: kiroku-metrics-package-foundation-and-in-process-metrics-collector
title: "Kiroku-Metrics Package Foundation And In-Process Metrics Collector"
kind: exec-plan
created_at: 2026-05-20T04:16:54Z
intention: "intention_01ks1saptfe6j8e98dvce7mvgf"
master_plan: "docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md"
---

# Kiroku-Metrics Package Foundation And In-Process Metrics Collector

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is the first of four child plans under the MasterPlan
`docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md`. It has
no dependencies and must be completed first. The MasterPlan's Integration Points
IP-1 (the `KirokuMetrics` collector and `MetricsSnapshot` type) and IP-2 (the new
package and its build wiring) are *defined here*; the three later plans consume
them.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. Its core library is the Cabal package
`kiroku-store` (Haskell modules under `Kiroku.Store.*`, in directory
`kiroku-store/`). Today there is no way to ask the store "how much have you
done and how healthy are you?" except by wiring two callbacks the store already
offers and building your own counters by hand.

After this plan, a developer who has a running `KirokuStore` can:

1. Create an **in-process metrics collector** — an opaque handle of type
   `KirokuMetrics` — before opening the store.
2. Wire the collector into the store's two existing observation callbacks
   (`eventHandler` and `observationHandler`, both fields on
   `Kiroku.Store.Connection.ConnectionSettings`).
3. At any moment call `snapshotMetrics` to obtain an immutable, JSON-encodable
   `MetricsSnapshot` value that reflects everything the store has done so far:
   total events appended store-wide, the number of active subscribers, pool
   connection gauges, lifecycle counters (notifier reconnects, publisher pool
   errors, per-phase subscription database errors, subscriptions started /
   caught-up / stopped by reason, hard-deletes), and a per-subscription map with
   each subscription's last-known position and its **lag** behind the store's
   global position.

You can *see this working* two ways, both shipped as tests in this plan:

- A **pure unit test** that constructs a collector, feeds it a scripted sequence
  of `KirokuEvent` and `Observation` values through the callback wrappers, calls
  `snapshotMetrics`, and asserts the counters and gauges came out right.
- An **integration test** that wires the collector into a real ephemeral
  PostgreSQL-backed store (via the existing `Test.Helpers.withTestStore`-style
  fixture), appends events, runs a real subscription to completion, and asserts
  the snapshot reflects the appended count, the subscription's recorded position,
  and a non-negative lag.

This plan deliberately introduces **no web server and no HTTP** — that is EP-2
(`docs/plans/33-http-json-prometheus-and-health-endpoints-for-kiroku-metrics.md`).
It introduces **no OpenTelemetry** — that is deferred (see the MasterPlan
Decision Log). It requires **no change to `kiroku-store`** — the store already
exposes every seam the collector needs.


## Progress

- [ ] M1: `kiroku-metrics` package skeleton created and wired into `cabal.project`, `flake.nix`, `nix/haskell-overlay.nix`, and `mori.dhall`; the empty library builds under `cabal build` and `nix build`.
- [ ] M2: `Kiroku.Metrics.Types` (`MetricsSnapshot` + sub-records + `ToJSON`) and `Kiroku.Metrics.Collector` (`KirokuMetrics`, `newKirokuMetrics`, callback wrappers, `snapshotMetrics`) implemented; pure unit test passes.
- [ ] M3: Integration test wiring the collector into a real `withTestStore`, appending events and running a subscription, asserts snapshot contents; `cabal test` green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Put both the snapshot type and the collector in the new
  `kiroku-metrics` package, not in `kiroku-store`.
  Rationale: The collector only consumes `kiroku-store`'s *public* callback and
  read APIs, so it does not need to live in core; keeping it out leaves
  `kiroku-store` unchanged and dependency-light. See the MasterPlan Decision Log.
  Date: 2026-05-19

- Decision: Model pool health as a per-connection-UUID status map maintained from
  `Hasql.Pool.Observation.Observation` values, deriving current gauges
  (connecting / ready / in-use counts) and cumulative counters (established,
  terminated) from it.
  Rationale: `Observation` is `ConnectionObservation UUID ConnectionStatus`; a
  connection's status changes many times over its life, so a UUID-keyed map is the
  only way to compute an accurate "currently in use" gauge rather than a
  meaningless monotonic tally of transitions.
  Date: 2026-05-19


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Read this section even if you think you know the repository; it defines every
term used below and names every file by full path.

### The repository layout

The repository root contains several Cabal packages, listed in `cabal.project`:

```text
packages:
  kiroku-store
  kiroku-store-migrations
  shibuya-kiroku-adapter
  kiroku-otel
```

This plan adds a fifth: `kiroku-metrics`. The build is GHC 9.12.2 (set by
`with-compiler: ghc-9.12.2` in `cabal.project`). There is also a Nix flake
(`flake.nix`) and a Haskell package overlay (`nix/haskell-overlay.nix`) that
declare each local package to Nix, and a `mori.dhall` project descriptor that
lists packages for tooling.

The closest existing template for a new sister package is **`kiroku-otel`**
(directory `kiroku-otel/`, Cabal file `kiroku-otel/kiroku-otel.cabal`). It is a
small library that depends on `kiroku-store` and adds an optional capability
(OpenTelemetry trace-context helpers) without changing core. Copy its structure.

### The store handle and its observation seams

`Kiroku.Store.Connection` (file `kiroku-store/src/Kiroku/Store/Connection.hs`)
defines the store handle and its settings:

- `data ConnectionSettingsM m` with fields including
  `observationHandler :: !(Maybe (Observation -> m ()))` and
  `eventHandler :: !(Maybe (KirokuEvent -> m ()))`. The `IO`-specialised alias is
  `type ConnectionSettings = ConnectionSettingsM IO`. `defaultConnectionSettings
  :: Text -> ConnectionSettings` sets both handlers to `Nothing`.
- `data KirokuStore` with fields `pool :: !Hasql.Pool.Pool`,
  `publisher :: !EventPublisher`, plus others. `withStore :: MonadUnliftIO m =>
  ConnectionSettings -> (KirokuStore -> m a) -> m a` is the bracket that opens and
  closes the store.

These two callbacks are *the* metrics source. The store calls `eventHandler`
synchronously from the originating thread for every operational event, and
`observationHandler` for every pool connection state change. Both default to
`Nothing` (no-op). The collector's job is to supply functions for these fields
that update in-memory counters.

> **Important constraint (carried from the store's own docs):** these callbacks
> run *synchronously on the emit-site thread* (notifier loop, publisher loop,
> subscription worker, store interpreter). A slow callback stalls that loop. The
> collector's updates must therefore be fast and non-blocking. We achieve this
> with plain STM `TVar`/`modifyTVar'` updates and no I/O — never a database call,
> network call, or unbounded data structure.

### `KirokuEvent` — the operational event taxonomy

`Kiroku.Store.Observability` (file
`kiroku-store/src/Kiroku/Store/Observability.hs`), re-exported from
`Kiroku.Store`, defines:

```haskell
data KirokuEvent
  = KirokuEventNotifierReconnecting !Int !SomeException
  | KirokuEventNotifierReconnected
  | KirokuEventPublisherPoolError !Hasql.Pool.UsageError
  | KirokuEventSubscriptionDbError !SubscriptionName !SubscriptionDbPhase !Hasql.Pool.UsageError
  | KirokuEventSubscriptionStarted !SubscriptionName !GlobalPosition
  | KirokuEventSubscriptionCaughtUp !SubscriptionName !GlobalPosition
  | KirokuEventSubscriptionStopped !SubscriptionName !GlobalPosition !SubscriptionStopReason
  | KirokuEventHardDeleteIssued !StreamName !StreamId

data SubscriptionDbPhase = LoadCheckpoint | FetchBatch | SaveCheckpoint
data SubscriptionStopReason
  = StopHandlerRequested | StopCancelled | StopOverflowed | StopWorkerCrashed !SomeException
```

`SubscriptionName` is `newtype SubscriptionName Text` (from
`Kiroku.Store.Subscription.Types`, re-exported). `GlobalPosition` is
`newtype GlobalPosition Int64` (from `Kiroku.Store.Types`). `StreamName`,
`StreamId`, `UsageError` are likewise available.

The collector maps each constructor to one or more counter increments, and for
the three `Subscription*` constructors carrying a `GlobalPosition` it also
records the position into the per-subscription map.

### `Observation` — the pool connection lifecycle

`Hasql.Pool.Observation` (re-exported from `Kiroku.Store` as `Observation (..)`,
`ConnectionStatus (..)`, `ConnectionReadyForUseReason (..)`,
`ConnectionTerminationReason (..)`) is:

```haskell
data Observation = ConnectionObservation UUID ConnectionStatus
data ConnectionStatus
  = ConnectingConnectionStatus
  | ReadyForUseConnectionStatus ConnectionReadyForUseReason
  | InUseConnectionStatus
  | TerminatedConnectionStatus ConnectionTerminationReason
```

The collector keeps `TVar (Map UUID ConnectionStatus)` and updates the status for
the observed UUID on every `Observation`, removing the UUID on
`TerminatedConnectionStatus`. From that map it derives the gauges
`poolConnecting`, `poolReady`, `poolInUse` (counts of UUIDs in each state) and the
cumulative counters `poolEstablishedTotal` (incremented when a status transitions
*into* `ReadyForUseConnectionStatus EstablishedConnectionReadyForUseReason`) and
`poolTerminatedTotal` (incremented on every `TerminatedConnectionStatus`).

### Store-level gauges read at snapshot time

Two store-level numbers are read directly from the live `KirokuStore` handle when
`snapshotMetrics` is called (not accumulated from callbacks):

- **Global position** (= total events appended store-wide, gap-free). Read with
  `Kiroku.Store.Subscription.EventPublisher.publisherPosition :: EventPublisher ->
  STM GlobalPosition` applied to `store.publisher`. The publisher advances this on
  every fetched batch, so it tracks the store's highest assigned global position.
- **Active subscriber count.** The `EventPublisher` record (exposed module
  `Kiroku.Store.Subscription.EventPublisher`, exported `EventPublisher (..)`) has
  field `subscribers :: !(TVar (IntMap Subscriber))`. The active count is
  `Data.IntMap.Strict.size` of the value read from that `TVar`.

Because these are read from the live handle, `newKirokuMetrics` takes the
`KirokuStore` as an argument and keeps a reference to it. (The handle exists by
the time you can append or subscribe, which is the only time these numbers are
meaningful.)

### Per-subscription lag and its known limitation

For each subscription name the collector tracks `lastKnownPosition` — the most
recent `GlobalPosition` seen in a `KirokuEventSubscriptionStarted`,
`...CaughtUp`, or `...Stopped` for that name. The snapshot then computes
`lag = max 0 (globalPosition − lastKnownPosition)`.

**Limitation to document (and restated in EP-2's readiness check and EP-4's
guide):** the store does *not* emit an event per processed event, only at these
lifecycle points, so `lastKnownPosition` is a *lower bound* on the
subscription's true live position and `lag` is an *upper bound* on true lag. A
subscription that is caught up and quietly processing live events shows its
position frozen at the last `CaughtUp`/`Stopped` value until the next lifecycle
event. This is acceptable for v1 and is the most that can be derived without
changing `kiroku-store`. Exposing the worker's live cursor is recorded in the
MasterPlan as possible future work.


## Plan of Work

Three milestones, each independently verifiable.

### Milestone M1 — Package skeleton and build wiring

Scope: create the `kiroku-metrics` package directory, its Cabal file, a single
placeholder library module, and register it with both build systems (cabal and
nix) and `mori.dhall`. At the end, `cabal build kiroku-metrics` and
`nix build .#kiroku-metrics` both succeed on an essentially empty library. This
milestone exists separately so the build is green before any logic is written and
so IP-2 (the package + wiring) is satisfiable on its own.

Files created:

- `kiroku-metrics/kiroku-metrics.cabal`
- `kiroku-metrics/CHANGELOG.md`
- `kiroku-metrics/src/Kiroku/Metrics.hs` (umbrella re-export module; starts
  nearly empty, grows in M2 and in later plans)

Files edited:

- `cabal.project` — add `kiroku-metrics` to the `packages:` block.
- `flake.nix` — add `kiroku-metrics = haskellPackages.kiroku-metrics;` to the
  `packages` output set.
- `nix/haskell-overlay.nix` — add a `kiroku-metrics` attribute mirroring the
  existing `kiroku-otel` line.
- `mori.dhall` — add a `Schema.Package` record for `kiroku-metrics`.

The Cabal file for M1 (web dependencies are intentionally *absent*; EP-2 adds
them):

```cabal
cabal-version:   3.0
name:            kiroku-metrics
version:         0.1.0.0
synopsis:        Metrics, health, and event-streaming HTTP endpoints for Kiroku
description:
  HTTP/JSON, Prometheus, and WebSocket endpoints exposing operational metrics for
  a running Kiroku event store, plus a WebSocket channel for streaming events out
  of the store. A sister package to @kiroku-store@; the core library never depends
  on a web framework.
author:          Nadeem Bitar
maintainer:      nadeem@gmail.com
license:         BSD-3-Clause
build-type:      Simple
category:        Database, Eventing, Observability
extra-doc-files: CHANGELOG.md

common common
  default-language:   GHC2024
  default-extensions:
    DeriveAnyClass
    DerivingStrategies
    DuplicateRecordFields
    LambdaCase
    OverloadedRecordDot
    OverloadedStrings
    RecordWildCards
  ghc-options:        -Wall

library
  import:          common
  exposed-modules:
    Kiroku.Metrics
    Kiroku.Metrics.Collector
    Kiroku.Metrics.Types
  build-depends:
    , aeson         >=2.1
    , base          >=4.18 && <5
    , containers    >=0.6
    , kiroku-store  >=0.1
    , stm
    , text          >=2.0
    , time          >=1.12
    , uuid          >=1.3
  hs-source-dirs:  src

test-suite kiroku-metrics-test
  import:         common
  type:           exitcode-stdio-1.0
  main-is:        Main.hs
  hs-source-dirs: test
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , aeson
    , base               >=4.18 && <5
    , containers
    , ephemeral-pg       >=0.2
    , hspec              >=2.10
    , kiroku-metrics
    , kiroku-store
    , stm
    , text
    , uuid
```

> Note: `OverloadedRecordDot` + `DuplicateRecordFields` lets you write
> `snapshot.store.globalPosition` etc. This matches the field-access idiom used in
> `shibuya-metrics`. `kiroku-store` itself prefers `generic-lens` labels, but the
> new package is free to use record-dot since its own records are plain.

For M1 the three library modules can be near-trivial placeholders that just
compile (e.g. `module Kiroku.Metrics.Types where`); they are filled in M2. Create
`kiroku-metrics/test/Main.hs` as a trivial passing `hspec` `main` so the
test-suite stanza builds.

Acceptance for M1: `cabal build all` succeeds; `nix build .#kiroku-metrics`
succeeds (or `nix flake check` if a full build is too slow locally — see Concrete
Steps for the exact command and fallback).

### Milestone M2 — Snapshot type, collector, callback wrappers, `snapshotMetrics`

Scope: implement the real `Kiroku.Metrics.Types` and `Kiroku.Metrics.Collector`,
and a pure unit test. At the end, a developer can build a collector, push scripted
`KirokuEvent`/`Observation` values through the wrappers, and read a correct
snapshot. This milestone delivers IP-1.

`Kiroku.Metrics.Types` defines the immutable snapshot value and its `ToJSON`
instance (no `FromJSON` is required by any consumer; omit it). Suggested shape:

```haskell
module Kiroku.Metrics.Types
  ( MetricsSnapshot (..)
  , StoreGauges (..)
  , LifecycleCounters (..)
  , SubscriptionMetrics (..)
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)

data MetricsSnapshot = MetricsSnapshot
  { store         :: !StoreGauges
  , counters      :: !LifecycleCounters
  , subscriptions :: !(Map Text SubscriptionMetrics)  -- key = SubscriptionName text
  }
  deriving stock (Eq, Show)

data StoreGauges = StoreGauges
  { globalPosition       :: !Int64  -- total events appended store-wide (gap-free) == high water mark
  , activeSubscribers    :: !Int
  , poolConnecting       :: !Int
  , poolReady            :: !Int
  , poolInUse            :: !Int
  , poolEstablishedTotal :: !Int64
  , poolTerminatedTotal  :: !Int64
  }
  deriving stock (Eq, Show)

data LifecycleCounters = LifecycleCounters
  { notifierReconnecting          :: !Int64
  , notifierReconnected           :: !Int64
  , publisherPoolErrors           :: !Int64
  , subscriptionDbErrorsLoad      :: !Int64
  , subscriptionDbErrorsFetch     :: !Int64
  , subscriptionDbErrorsSave      :: !Int64
  , subscriptionsStarted          :: !Int64
  , subscriptionsCaughtUp         :: !Int64
  , subscriptionsStoppedHandler   :: !Int64
  , subscriptionsStoppedCancelled :: !Int64
  , subscriptionsStoppedOverflow  :: !Int64
  , subscriptionsStoppedCrashed   :: !Int64
  , hardDeletesIssued             :: !Int64
  }
  deriving stock (Eq, Show)

data SubscriptionMetrics = SubscriptionMetrics
  { lastKnownPosition :: !Int64
  , lag               :: !Int64        -- max 0 (globalPosition - lastKnownPosition)
  , dbErrorCount      :: !Int64
  , lastStopReason    :: !(Maybe Text) -- "handler" | "cancelled" | "overflow" | "crashed"
  }
  deriving stock (Eq, Show)
```

Write explicit `ToJSON` instances (object with the field names above, nested
`store` / `counters` / `subscriptions`). Explicit instances keep the wire shape
stable and documented for EP-4; do not derive generically.

`Kiroku.Metrics.Collector` holds the mutable state and the read API:

```haskell
module Kiroku.Metrics.Collector
  ( KirokuMetrics
  , newKirokuMetrics
  , metricsEventHandler
  , metricsObservationHandler
  , snapshotMetrics
  ) where
```

Internal state (all `TVar`s inside an opaque `KirokuMetrics`): a `TVar` per
counter (or one `TVar` holding a strict `LifecycleCounters`-shaped record — a
single `TVar` is simpler and is fine because updates are cheap), a
`TVar (Map UUID ConnectionStatus)` for pool state, and a
`TVar (Map Text SubMutable)` for per-subscription accumulation where `SubMutable`
holds the last position, db-error count, and last stop reason. Plus a reference to
the `KirokuStore` for the snapshot-time reads.

`newKirokuMetrics :: KirokuStore -> IO KirokuMetrics` allocates the `TVar`s.

`metricsEventHandler :: KirokuMetrics -> Maybe (KirokuEvent -> IO ()) ->
(KirokuEvent -> IO ())` returns a handler that, for each `KirokuEvent`, performs
the STM updates and then calls the user's optional passthrough handler (so the
collector composes with a logger). It must call the passthrough *after* its own
update and must not swallow exceptions from it differently than the store already
does. Mapping:

- `KirokuEventNotifierReconnecting _ _` → `notifierReconnecting += 1`
- `KirokuEventNotifierReconnected` → `notifierReconnected += 1`
- `KirokuEventPublisherPoolError _` → `publisherPoolErrors += 1`
- `KirokuEventSubscriptionDbError name phase _` → bump the matching
  `subscriptionDbErrors{Load,Fetch,Save}` counter and the named subscription's
  `dbErrorCount`
- `KirokuEventSubscriptionStarted name pos` → `subscriptionsStarted += 1`; set the
  named subscription's `lastKnownPosition` to `max` of current and `pos`
- `KirokuEventSubscriptionCaughtUp name pos` → `subscriptionsCaughtUp += 1`;
  update `lastKnownPosition`
- `KirokuEventSubscriptionStopped name pos reason` → bump the by-reason stop
  counter; update `lastKnownPosition`; set `lastStopReason`
- `KirokuEventHardDeleteIssued _ _` → `hardDeletesIssued += 1`

`metricsObservationHandler :: KirokuMetrics -> Maybe (Observation -> IO ()) ->
(Observation -> IO ())` updates the pool map and the established/terminated
counters per the Context section, then calls the passthrough.

`snapshotMetrics :: KirokuMetrics -> IO MetricsSnapshot` runs one STM transaction
that reads all the collector `TVar`s *and* the two store `TVar`s
(`publisherPosition store.publisher` and `size <$> readTVar (subscribers
store.publisher)`), so the snapshot is internally consistent. It then computes the
derived `poolConnecting/poolReady/poolInUse` counts from the pool map and the
per-subscription `lag` from the global position, and returns the immutable record.

> Reading the store `TVar`s in the *same* `atomically` block as the collector
> `TVar`s is what makes the snapshot a coherent point-in-time view. `publisherPosition`
> already returns an `STM GlobalPosition`, and `subscribers` is a `TVar`, so both
> compose into one transaction.

Unit test (`kiroku-metrics/test/...`, an `hspec` spec): construct a collector
with a *fake* store. Because `newKirokuMetrics` needs a `KirokuStore` for the
snapshot-time reads, the cleanest test seam is to make the two store reads go
through a tiny internal accessor. Implement `newKirokuMetrics` in terms of a
private `newKirokuMetricsWith :: STM GlobalPosition -> STM Int -> IO
KirokuMetrics` (the position-reader and the subscriber-count-reader), with the
public `newKirokuMetrics store = newKirokuMetricsWith (publisherPosition
store.publisher) (IntMap.size <$> readTVar (subscribers store.publisher))`. Export
`newKirokuMetricsWith` from an `Internal` sub-module (or via an explicit export)
so the unit test can pass `pure (GlobalPosition n)` and `pure k` without a real
store. Feed scripted events, snapshot, assert.

Acceptance for M2: `cabal test kiroku-metrics` runs the unit spec and it passes;
the asserted snapshot matches the scripted inputs (e.g. after two
`KirokuEventNotifierReconnecting` and one `...Reconnected`, the snapshot shows
`notifierReconnecting == 2`, `notifierReconnected == 1`; after a
`KirokuEventSubscriptionStarted "p" 5` with a fake global position of 12, the
`subscriptions` map has `"p"` with `lastKnownPosition == 5` and `lag == 7`).

### Milestone M3 — Integration test against a real store

Scope: prove the collector works wired into a real store, end to end. At the end,
an integration spec opens an ephemeral PostgreSQL-backed store with the collector
installed, appends events, runs a subscription, and asserts the snapshot.

The test fixture mirrors `kiroku-store/test/Test/Helpers.hs`
(`withTestStoreSettings`): it uses `EphemeralPg.withCached` to get a connection
string, builds `defaultConnectionSettings`, and *transforms it to install the
collector's callbacks* before calling `withStore`. The wrinkle is ordering:
`newKirokuMetrics` needs the `KirokuStore`, but the callbacks must be set on
`ConnectionSettings` *before* `withStore` creates the store. Resolve this with the
`newKirokuMetricsWith` seam: create the collector from STM readers that read the
store's publisher, but obtain the publisher via an `MVar`/`IORef` filled inside
`withStore`'s body — or, more simply, install callbacks that forward into a
collector created lazily. The recommended concrete approach, written out in
Concrete Steps, is:

1. Create the collector with placeholder STM readers backed by an `IORef (Maybe
   KirokuStore)` (readers return `GlobalPosition 0` / `0` until the ref is set).
2. Build `ConnectionSettings` with `eventHandler = Just (metricsEventHandler coll
   Nothing)` and `observationHandler = Just (metricsObservationHandler coll
   Nothing)`.
3. Inside `withStore $ \store -> ...`, write `store` into the `IORef` so the
   snapshot-time readers see the live publisher.

This ordering dance is exactly the kind of integration concern the test exists to
prove out; document the chosen approach in this plan's Decision Log when you
implement it, because EP-4's example program will reuse the same pattern.

Test body: append, say, 5 events to one stream; run a subscription that returns
`Stop` after the 5th event (or use the `waitForPublisher` pattern from
`Test.Helpers`); call `snapshotMetrics`; assert `store.globalPosition >= 5`,
`counters.subscriptionsStarted == 1`, the `subscriptions` map contains the
subscription name with `lag >= 0`, and (if the handler ran to `Stop`)
`counters.subscriptionsStoppedHandler == 1`.

Acceptance for M3: `cabal test kiroku-metrics` runs both specs green.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless stated. The Nix dev
shell provides `cabal`, GHC 9.12.2, and PostgreSQL; enter it with `nix develop`
if not already inside (the prompt's `PG_CONNECTION_STRING` is set there).

### M1 steps

1. Create the package tree:

   ```bash
   mkdir -p kiroku-metrics/src/Kiroku/Metrics kiroku-metrics/test
   ```

2. Write `kiroku-metrics/kiroku-metrics.cabal` with the M1 contents shown in the
   Plan of Work.

3. Write `kiroku-metrics/CHANGELOG.md` (one line: `# Revision history for
   kiroku-metrics` plus an `## 0.1.0.0` heading).

4. Write placeholder modules so the library and test build:

   ```haskell
   -- kiroku-metrics/src/Kiroku/Metrics/Types.hs
   module Kiroku.Metrics.Types () where
   ```
   ```haskell
   -- kiroku-metrics/src/Kiroku/Metrics/Collector.hs
   module Kiroku.Metrics.Collector () where
   ```
   ```haskell
   -- kiroku-metrics/src/Kiroku/Metrics.hs
   module Kiroku.Metrics () where
   ```
   ```haskell
   -- kiroku-metrics/test/Main.hs
   module Main (main) where
   main :: IO ()
   main = putStrLn "kiroku-metrics: no tests yet"
   ```

5. Edit `cabal.project` `packages:` block to add `kiroku-metrics`:

   ```text
   packages:
     kiroku-store
     kiroku-store-migrations
     shibuya-kiroku-adapter
     kiroku-otel
     kiroku-metrics
   ```

6. Edit `flake.nix`, in the `packages = { ... }` set, add:

   ```nix
   kiroku-metrics = haskellPackages.kiroku-metrics;
   ```

7. Edit `nix/haskell-overlay.nix`, add after the `kiroku-otel` line:

   ```nix
   kiroku-metrics = dontCheck (doJailbreak (final.callCabal2nix "kiroku-metrics" ../kiroku-metrics { }));
   ```

8. Edit `mori.dhall`, add to the `packages` list a record mirroring `kiroku-otel`:

   ```dhall
   , Schema.Package::{ name = "kiroku-metrics"
     , type = Schema.PackageType.Library
     , language = Schema.Language.Haskell
     , path = Some "kiroku-metrics"
     , description = Some "Metrics, health, and event-streaming HTTP endpoints for Kiroku"
     }
   ```

9. Build:

   ```bash
   cabal build all
   ```

   Expected: `kiroku-metrics-0.1.0.0` configures and the library + test-suite
   compile. Then verify the Nix wiring:

   ```bash
   nix build .#kiroku-metrics
   ```

   Expected: a `result` symlink and exit 0. If a full Nix build is too slow in
   your environment, at minimum run `nix flake check --no-build` to confirm the
   flake evaluates with the new attribute; record which you ran in Progress.

10. Commit (see commit-message format below).

### M2 steps

1. Replace the three placeholder modules with the real implementations described
   in Plan of Work M2. Keep `Kiroku.Metrics` (umbrella) re-exporting
   `Kiroku.Metrics.Types` and `Kiroku.Metrics.Collector` so downstream plans can
   `import Kiroku.Metrics` for everything.

2. Add the unit spec. Suggested file
   `kiroku-metrics/test/Test/CollectorSpec.hs` and a `hspec` `main` in
   `kiroku-metrics/test/Main.hs` that runs it.

3. Run:

   ```bash
   cabal test kiroku-metrics
   ```

   Expected transcript (abridged):

   ```text
   Collector
     counts notifier reconnect events            [✔]
     records subscription position and lag       [✔]
     tracks pool connection gauges from observations [✔]
   Finished in 0.01 seconds
   3 examples, 0 failures
   ```

### M3 steps

1. Add the integration spec (suggested
   `kiroku-metrics/test/Test/IntegrationSpec.hs`) using `EphemeralPg` and
   `Kiroku.Store`'s `withStore` + `appendToStream` + `withSubscription`, wiring the
   collector via the `IORef (Maybe KirokuStore)` pattern from Plan of Work M3.

2. Run `cabal test kiroku-metrics`; expect both specs green. The integration spec
   needs PostgreSQL available (the dev-shell `ephemeral-pg` provides it, exactly as
   the `kiroku-store` test-suite uses).

### Commit messages

Every commit on this plan carries all three trailers:

```text
feat(kiroku-metrics): scaffold package and build wiring

MasterPlan: docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md
ExecPlan: docs/plans/32-kiroku-metrics-package-foundation-and-in-process-metrics-collector.md
Intention: intention_01ks1saptfe6j8e98dvce7mvgf
```


## Validation and Acceptance

The plan is complete when all of the following hold:

1. `cabal build all` succeeds with the new package present.
2. `nix build .#kiroku-metrics` succeeds (or `nix flake check` evaluates with the
   new attribute, with the full build deferred — note which in Progress).
3. `cabal test kiroku-metrics` runs the unit spec and the integration spec, both
   green.
4. The public surface exists with these exact signatures (checked by the fact
   that EP-2 will import them):

   ```haskell
   data KirokuMetrics
   newKirokuMetrics          :: KirokuStore -> IO KirokuMetrics
   metricsEventHandler       :: KirokuMetrics -> Maybe (KirokuEvent  -> IO ()) -> (KirokuEvent  -> IO ())
   metricsObservationHandler :: KirokuMetrics -> Maybe (Observation -> IO ()) -> (Observation -> IO ())
   snapshotMetrics           :: KirokuMetrics -> IO MetricsSnapshot
   data MetricsSnapshot
   instance ToJSON MetricsSnapshot
   ```

5. A behavioral check beyond compilation: the integration spec demonstrates that
   after appending N events the snapshot's `store.globalPosition` is at least N,
   and that running a subscription increments `counters.subscriptionsStarted` and
   populates the `subscriptions` map — i.e. the collector observes *real* store
   activity, not just scripted inputs.


## Idempotence and Recovery

All steps are safe to repeat. Creating the package directory and files is
idempotent (overwrite on re-run). The edits to `cabal.project`, `flake.nix`,
`nix/haskell-overlay.nix`, and `mori.dhall` are additive single lines/records;
if a previous attempt half-applied them, re-running leaves exactly one entry —
check for and remove duplicates before committing. If `nix build` fails because a
dependency (e.g. `uuid`) is not in the GHC package set, add a `callHackageDirect`
or `doJailbreak` entry in `nix/haskell-overlay.nix` mirroring the existing
patterns there; record any such addition in Surprises & Discoveries. The unit and
integration tests can be run repeatedly; `EphemeralPg.withCached` manages its own
throwaway database.


## Interfaces and Dependencies

New package `kiroku-metrics`, library modules:

- `Kiroku.Metrics.Types` — `MetricsSnapshot (..)`, `StoreGauges (..)`,
  `LifecycleCounters (..)`, `SubscriptionMetrics (..)`, and their `ToJSON`
  instances. No web dependency.
- `Kiroku.Metrics.Collector` — `KirokuMetrics` (opaque), `newKirokuMetrics`,
  `metricsEventHandler`, `metricsObservationHandler`, `snapshotMetrics`, and the
  test seam `newKirokuMetricsWith :: STM GlobalPosition -> STM Int -> IO
  KirokuMetrics` (exported for tests; may live in a `.Internal` module).
- `Kiroku.Metrics` — umbrella re-export.

Libraries used and why: `stm` (the `TVar`s holding counters and maps; matches the
store's concurrency model and keeps callbacks non-blocking), `containers`
(`Data.Map.Strict` for the per-subscription and per-UUID maps,
`Data.IntMap.Strict.size` for the subscriber count), `aeson` (snapshot JSON),
`text`, `time` (reserved for any timestamping; the snapshot may carry a
`generatedAt` if desired — optional), `uuid` (the `Observation` connection id key),
`kiroku-store` (the store handle, callback types, `publisherPosition`, the
`EventPublisher` record). Test-only: `hspec`, `ephemeral-pg`.

Consumed-from dependencies (all already public in `kiroku-store`):

- `Kiroku.Store` re-exports: `KirokuStore (..)`, `ConnectionSettings`,
  `defaultConnectionSettings`, `withStore`, `KirokuEvent (..)`,
  `SubscriptionDbPhase (..)`, `SubscriptionStopReason (..)`, `Observation (..)`,
  `ConnectionStatus (..)`, `ConnectionReadyForUseReason (..)`,
  `ConnectionTerminationReason (..)`, `GlobalPosition (..)`, `SubscriptionName`.
- `Kiroku.Store.Subscription.EventPublisher`: `EventPublisher (..)` (for the
  `subscribers` field), `publisherPosition`.

This plan must leave `kiroku-store` itself unchanged.

Downstream consumers (later plans): EP-2
(`docs/plans/33-http-json-prometheus-and-health-endpoints-for-kiroku-metrics.md`)
imports `KirokuMetrics`, `snapshotMetrics`, and the `MetricsSnapshot` records to
render JSON/Prometheus/health; EP-3
(`docs/plans/34-websocket-endpoint-for-live-metrics-and-event-streaming-out-of-the-store.md`)
imports them for the WebSocket metrics channel. Keep the snapshot record fields
and the four public collector functions stable; additive fields are fine, renames
are breaking and must be reflected in the MasterPlan Integration Points IP-1.
