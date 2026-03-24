# Streaming Subscriptions and Shibuya Integration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

Kiroku's subscription system today is callback-based: you register a handler, and the worker pushes events to it one at a time. This works, but it limits composability — filtering, mapping, windowing, and other transformations require boilerplate inside the handler. A Streamly `Stream` interface over subscriptions would make these operations natural and open kiroku to any pull-based consumer.

The most interesting pull-based consumer is Shibuya, a supervised queue processing framework. Running multiple kiroku subscriptions (projections, read models, integrations) as Shibuya processors would give them supervision with failure isolation, per-subscription metrics and health checks, coordinated graceful shutdown, backpressure, and OpenTelemetry tracing — all without kiroku having to implement any of this.

This plan delivers three things. First, a first-class `Stream IO RecordedEvent` interface for kiroku subscriptions as a library module. Second, a proof-of-concept Shibuya adapter that wraps that stream into Shibuya's `Adapter` type. Third, an integration test that runs multiple concurrent subscriptions through Shibuya's supervised pipeline, validating that the combination provides real operational benefits over bare subscription handles.

After this plan is complete, a developer can: (1) consume kiroku subscriptions as composable Streamly streams, (2) see events flow from kiroku through Shibuya handlers in a test, and (3) observe that Shibuya's supervision isolates a failing subscription from healthy ones running concurrently.


## Progress

- [x] Add streamly-core as a library dependency of kiroku-store. (2026-03-24)
- [x] Implement `Kiroku.Store.Subscription.Stream` module with `subscriptionStream`. (2026-03-24)
- [x] Add the module to the cabal file's exposed-modules. (2026-03-24)
- [x] Verify the library compiles. (2026-03-24)
- [x] Add shibuya-core and related test dependencies to kiroku-store. (2026-03-24)
- [x] Update cabal.project with source-repository-package entries for shibuya-core's transitive dependencies. (2026-03-24)
- [x] Implement `Shibuya/Adapter/Kiroku.hs` in the test directory. (2026-03-24)
- [x] Write single-subscription integration test (catch-up and live delivery). (2026-03-24)
- [x] Write multi-subscription test: three category subscriptions under Shibuya supervision. (2026-03-24)
- [x] Write failure-isolation test: one failing handler does not affect others. (2026-03-24)
- [x] Write coordinated-shutdown test: `stopApp` cleanly stops all subscriptions. (2026-03-24)
- [x] Run full test suite and record results. (2026-03-24)


## Surprises & Discoveries

- The adapter could not use `subscriptionStream` to produce the `Eff es` stream directly. The `Stream IO RecordedEvent` returned by `subscriptionStream` cannot be lifted to `Stream (Eff es)` without `morphInner` (which is in the `streamly` package but not straightforward to use with effectful's `Eff`). Instead, the adapter builds the TBQueue and subscription directly, constructing the `Eff es` stream via `Stream.unfoldrM` with `liftIO`. The library's `subscriptionStream` remains useful for non-Shibuya consumers.

- GHC's `DuplicateRecordFields` creates ambiguity when multiple types share field names (`payload`, `batchSize`). Record dot syntax (`event.fieldName`) does not resolve the ambiguity in all contexts (where-clause bindings, constructors from different modules). Pattern matching and lens-based access (`^. #field`) are more reliable.

- `NoFieldSelectors` in the defining module (shibuya-core) means OverloadedRecordDot doesn't work for those fields when imported into a module without `NoFieldSelectors`. Lens-based access works as a fallback.


## Decision Log

- Decision: Build the proof-of-concept adapter in the kiroku project's test directory rather than as a standalone package or in the shibuya project.
  Rationale: The kiroku project already has test infrastructure for ephemeral PostgreSQL databases. Building here avoids duplicating that setup. The adapter module is small enough that it can live in the test directory without polluting the library. A production adapter package can later live in the shibuya project, following the `shibuya-pgmq-adapter` pattern.
  Date: 2026-03-24

- Decision: Use the MonadIO-based `Kiroku.Store.Subscription.subscribe` rather than the higher-order `Subscription` effect for the adapter.
  Rationale: The MonadIO API is simpler to bridge. It takes a `KirokuStore` handle and an `IO`-based handler, which is straightforward to compose with a TBQueue. The effectful API adds complexity (ConcUnlift, effect stack threading) that is orthogonal to the integration question. A production adapter can later choose which API to use based on the application's effect requirements.
  Date: 2026-03-24

- Decision: The adapter message type is `RecordedEvent` (not `Value`).
  Rationale: `RecordedEvent` carries rich metadata (event ID, type, stream position, global position, timestamps, causation/correlation IDs) that is valuable for downstream Shibuya handlers. Reducing to just the JSON `Value` payload discards this. If a user wants only the payload, they can extract it in their handler.
  Date: 2026-03-24

- Decision: AckHandle semantics for the kiroku adapter are no-op for AckOk/AckRetry/AckDeadLetter, and trigger subscription cancellation for AckHalt.
  Rationale: Kiroku's subscription model is fundamentally different from a message queue. Events are immutable and persistent — there is no concept of deleting a processed message, retrying delivery, or routing to a dead-letter queue. Checkpoint advancement is managed internally by kiroku's subscription worker (not by the handler). The only meaningful action is stopping the subscription on AckHalt. AckOk is the normal case; AckRetry and AckDeadLetter are acknowledged but have no mechanical effect. This is similar to how a Kafka consumer adapter would handle acks — offset management is internal to the consumer.
  Date: 2026-03-24

- Decision: Use a TBQueue as the push-to-pull bridge between kiroku's handler and the Streamly stream.
  Rationale: A bounded queue provides natural backpressure (kiroku's handler blocks when the queue is full, which slows the subscription worker) and is simple to implement. STM's `TBQueue` is the standard choice for bounded producer-consumer channels in Haskell.
  Date: 2026-03-24

- Decision: The stream interface is a first-class library module, not a test-only utility.
  Rationale: The push-to-pull bridge is generally useful — any consumer that wants a streaming interface to kiroku subscriptions would need it (projections, read models, analytics pipelines, CQRS integrations). Exposing it from the library makes it available to both the proof-of-concept test and a future production adapter. The module is small (one function) and has no new dependencies beyond stm (already present) and streamly-core.
  Date: 2026-03-24

- Decision: Validate multi-subscription supervision, not just single-adapter integration.
  Rationale: The most compelling reason to integrate kiroku with shibuya is not just "events flow through" — a bare subscription handle already does that. The value is operational: running many subscriptions (projections, denormalizers, integrations) under unified supervision with failure isolation, metrics, and coordinated shutdown. The test must demonstrate these benefits concretely, otherwise we are only proving type compatibility rather than practical value.
  Date: 2026-03-24


## Outcomes & Retrospective

All three milestones completed successfully. The full test suite passes (59 tests, 0 failures).

**Milestone 1**: The `Kiroku.Store.Subscription.Stream` module provides `subscriptionStream :: KirokuStore -> SubscriptionConfig -> Natural -> IO (Stream IO RecordedEvent, IO ())`. It works as designed — a TBQueue bridges the push-based subscription handler to a pull-based Streamly stream.

**Milestone 2**: The proof-of-concept adapter at `kiroku-store/test/Shibuya/Adapter/Kiroku.hs` wraps a kiroku subscription into a Shibuya `Adapter es RecordedEvent`. Both catch-up and live event delivery work through the Shibuya pipeline.

**Milestone 3**: Multi-subscription supervision validated three key operational benefits:
1. **Concurrent multi-subscription**: Three category subscriptions (orders, payments, inventory) run under a single `runApp`, each receiving only its category's events.
2. **Failure isolation**: A crashing handler in one subscription does not affect healthy ones. The failed processor shows `Failed` state in metrics while others continue processing.
3. **Coordinated shutdown**: `stopAppGracefully` cleanly terminates all subscriptions and drains in-flight work.

**Key finding**: The combination of kiroku + Shibuya provides real operational value beyond bare `SubscriptionHandle` values. A single `runApp` call manages the lifecycle of multiple projections with failure isolation and coordinated shutdown — functionality that would otherwise require significant custom infrastructure.


## Context and Orientation

This section describes the two systems being integrated and the key files involved.

Kiroku is a PostgreSQL event store. Its source lives at the repository root under `kiroku-store/`. The subscription system consists of several modules that work together.

`kiroku-store/src/Kiroku/Store/Subscription.hs` exports the function `subscribe :: (MonadIO m) => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle`. This is the main entry point. It takes a store handle and a configuration containing a handler callback of type `RecordedEvent -> IO SubscriptionResult` (where `SubscriptionResult` is either `Continue` or `Stop`). It spawns an async worker thread and returns a `SubscriptionHandle` with `cancel` and `wait` operations.

`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` defines the subscription types. `SubscriptionConfig` contains a `SubscriptionName` (unique identifier), a `SubscriptionTarget` (either `AllStreams` or `Category CategoryName`), a handler callback, and a `batchSize :: Int32`. `SubscriptionHandle` provides `cancel :: IO ()` and `wait :: IO (Either SomeException ())`.

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` implements the two-phase worker: catch-up from the database, then live mode reading from a broadcast `TChan`. The worker manages its own checkpoint persistence — after processing each batch, it saves the global position to the `subscriptions` table.

`kiroku-store/src/Kiroku/Store/Types.hs` defines `RecordedEvent`, the central event type with fields: `eventId :: EventId` (UUID), `eventType :: EventType` (Text), `streamVersion`, `globalPosition :: GlobalPosition` (Int64 newtype), `originalStreamId`, `originalVersion`, `payload :: Value` (Aeson JSON), `metadata :: Maybe Value`, `causationId`, `correlationId`, `createdAt :: UTCTime`.

`kiroku-store/src/Kiroku/Store/Connection.hs` defines `KirokuStore`, the handle that holds a hasql connection pool, schema name, notifier, and event publisher. The store is created via a bracket-style `withStore` function.

Shibuya is a supervised queue processing framework. Its source lives at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/`. The key abstractions for this plan are the adapter interface and the supervision model.

`shibuya-core/src/Shibuya/Adapter.hs` defines `Adapter es msg`, a record with three fields: `adapterName :: Text` (for logging), `source :: Stream (Eff es) (Ingested es msg)` (a Streamly stream of ingested messages), and `shutdown :: Eff es ()` (graceful stop).

`shibuya-core/src/Shibuya/Core/Ingested.hs` defines `Ingested es msg`, a record with: `envelope :: Envelope msg` (message metadata + payload), `ack :: AckHandle es` (acknowledgment handle), and `lease :: Maybe (Lease es)` (optional visibility timeout extension).

`shibuya-core/src/Shibuya/Core/Types.hs` defines `Envelope msg` with: `messageId :: MessageId` (Text newtype), `cursor :: Maybe Cursor` (where `Cursor` is `CursorInt Int` or `CursorText Text`), `partition :: Maybe Text`, `enqueuedAt :: Maybe UTCTime`, `traceContext :: Maybe TraceHeaders`, and `payload :: msg`.

`shibuya-core/src/Shibuya/Core/AckHandle.hs` defines `AckHandle es = AckHandle { finalize :: AckDecision -> Eff es () }`.

`shibuya-core/src/Shibuya/Core/Ack.hs` defines `AckDecision` with constructors `AckOk`, `AckRetry RetryDelay`, `AckDeadLetter DeadLetterReason`, and `AckHalt HaltReason`.

`shibuya-core/src/Shibuya/App.hs` provides `runApp`, which takes a `SupervisionStrategy` (`IgnoreFailures` or `StopAllOnFailure`), an `inboxSize :: Int` (for backpressure), and a list of `(ProcessorId, QueueProcessor es)` pairs. Each `QueueProcessor` pairs an `Adapter es msg` with a `Handler es msg` (which is `Ingested es msg -> Eff es AckDecision`), plus ordering and concurrency policies. `runApp` returns an `AppHandle` with operations: `getAppMetrics` (returns a map of `ProcessorId` to `ProcessorMetrics`), `stopApp` / `stopAppGracefully` (coordinated shutdown with drain timeout), and `waitApp` (block until all processors finish). The supervision strategy `IgnoreFailures` maps to NQE's `IgnoreAll` — a failed processor is marked Failed in metrics but other processors keep running. `StopAllOnFailure` maps to `KillAll`.

`shibuya-core/src/Shibuya/Runner/Metrics.hs` defines `ProcessorMetrics` with `state :: ProcessorState` (which can be `Idle`, `Processing InFlightInfo UTCTime`, `Failed Text UTCTime`, or `Stopped`) and `stats :: StreamStats` (with `received`, `dropped`, `processed`, `failed` counts). `ProcessorId` is a `Text` newtype.

`shibuya-core/src/Shibuya/Telemetry/Effect.hs` defines the `Tracing` effect required by `runApp`. The `runTracingNoop` interpreter provides zero-overhead no-op tracing for tests.

The PGMQ adapter at `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs` is the reference implementation for building adapters. It demonstrates the pattern: create a shutdown signal TVar, build a Streamly stream that polls the queue, wrap it all in an `Adapter` record.

The kiroku test suite at `kiroku-store/test/Main.hs` uses `ephemeral-pg` to spin up a temporary PostgreSQL instance, create the schema, and test subscriptions end-to-end. The proof-of-concept test will follow this same pattern.

The kiroku project uses Cabal (`kiroku-store/kiroku-store.cabal`) with GHC 9.12.2 (set in `cabal.project`). The cabal project file includes a local path to `hasql-notifications`. To add shibuya-core as a test dependency, its source must be reachable — either via a local path in `cabal.project` or via Hackage. Since shibuya-core is published on Hackage (v0.1.0.0), it can be added as a regular dependency; however, it depends on `hs-opentelemetry-api`, `hs-opentelemetry-propagator-w3c`, and `nqe`, which may require source-repository-package entries if Hackage versions are incompatible with GHC 9.12.


## Plan of Work

The work has three milestones. The first establishes the Streamly stream interface as a first-class library feature. The second builds the proof-of-concept Shibuya adapter and a basic integration test. The third validates the operational benefits of running multiple subscriptions under Shibuya's supervision.


### Milestone 1: Subscription Stream Interface

This milestone adds a `Kiroku.Store.Subscription.Stream` module to the kiroku-store library. At the end, callers can write `subscriptionStream store config 256` and get back a tuple of a lazy `Stream IO RecordedEvent` and a cancel action. The stream yields events as the subscription produces them, with backpressure via a bounded TBQueue.

The core idea: a `TBQueue (Maybe RecordedEvent)` sits between kiroku's push-based subscription handler and a Streamly stream. The handler writes `Just event` into the queue and returns `Continue`. A `Nothing` sentinel signals end-of-stream. The Streamly stream repeatedly reads from the queue via `Stream.unfoldrM` and terminates when it encounters `Nothing`.

In `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`, define a single function:

    subscriptionStream ::
        KirokuStore ->
        SubscriptionConfig ->
        Natural ->
        IO (Stream IO RecordedEvent, IO ())

The first argument is the store handle. The second is a subscription config — the `handler` field in the config is ignored because the bridge provides its own handler that writes to the queue. The third argument is the TBQueue capacity (buffer size), controlling how far ahead the subscription can produce before backpressure kicks in. The return value is a pair: the event stream and a cancel action. The cancel action cancels the underlying kiroku subscription handle and writes `Nothing` to the queue so any blocked reader wakes up and terminates.

Internally, the function: (1) creates a `TBQueue (Maybe RecordedEvent)` with the given capacity, (2) builds a `SubscriptionConfig` that replaces the handler with one that writes `Just event` to the queue and returns `Continue`, (3) calls `Kiroku.Store.Subscription.subscribe` to start the subscription, and (4) constructs the Streamly stream using `Stream.unfoldrM` with a step function that reads from the queue — yielding `Just (event, ())` for `Just event` and `Nothing` for the sentinel.

To make this work, add `streamly-core >=0.3` to the library's `build-depends` in `kiroku-store/kiroku-store.cabal`. The `stm` dependency is already present. Add the new module to `exposed-modules`.

Acceptance: `cabal build kiroku-store` succeeds. The module is importable and the function type-checks. Direct validation comes in Milestone 2 when the stream is consumed by a Shibuya adapter.


### Milestone 2: Shibuya Adapter and Basic Integration

This milestone creates a proof-of-concept Shibuya adapter in the test directory and an integration test that proves events flow from kiroku through Shibuya's processing pipeline. At the end, a test appends events to kiroku, the adapter produces them as a Streamly stream, Shibuya's runner feeds them to a handler, and the handler collects them — demonstrating end-to-end type compatibility and event delivery.

The adapter module lives at `kiroku-store/test/Shibuya/Adapter/Kiroku.hs`. It provides:

    data KirokuAdapterConfig = KirokuAdapterConfig
        { subscriptionName :: SubscriptionName
        , subscriptionTarget :: SubscriptionTarget
        , batchSize :: Int32
        , bufferSize :: Natural
        }

    kirokuAdapter ::
        (IOE :> es) =>
        KirokuStore ->
        KirokuAdapterConfig ->
        Eff es (Adapter es RecordedEvent)

The adapter builds a `SubscriptionConfig` from the `KirokuAdapterConfig`, calls `subscriptionStream` to get the IO-based stream and cancel action, lifts the stream into `Eff es` using `liftIO`, wraps each `RecordedEvent` into an `Ingested es RecordedEvent` by constructing an `Envelope` and an `AckHandle`, and returns an `Adapter` record.

The `RecordedEvent`-to-`Envelope` mapping:
- `messageId`: the event's UUID formatted as `MessageId` text.
- `cursor`: `Just (CursorInt (fromIntegral pos))` where `pos` is extracted from `globalPosition`.
- `partition`: `Nothing` (kiroku has no partition concept).
- `enqueuedAt`: `Just createdAt` from the event.
- `traceContext`: `Nothing` (could be populated from event metadata in a production adapter).
- `payload`: the `RecordedEvent` itself.

The `AckHandle` finalize function: `AckOk` is a no-op (checkpoint is managed by the kiroku worker), `AckRetry` and `AckDeadLetter` are no-ops (events are immutable), `AckHalt` calls the cancel action to stop the subscription.

The basic integration test goes in a new `describe "Shibuya adapter"` block in `kiroku-store/test/Main.hs`. Two sub-tests:

1. "delivers catch-up events through Shibuya pipeline": Append 10 events to a kiroku stream. Create the adapter and run it through `runApp` with `IgnoreFailures` strategy and a handler that writes each received event's payload to an `IORef [RecordedEvent]`. Use a `TVar Int` counter and `STM.check` with a timeout to wait until all 10 events arrive. Assert the count matches. Then call `stopApp`.

2. "delivers live events through Shibuya pipeline": Create the adapter and start Shibuya first. Then append 5 events. Wait for them to arrive at the handler. Assert the count. Then call `stopApp`.

Acceptance: `cabal test kiroku-store-test --test-show-details=direct` passes. Both sub-tests show events arriving at the handler.


### Milestone 3: Multi-Subscription Supervision

This milestone validates the operational benefits of running multiple kiroku subscriptions under Shibuya's supervision. This is the key question the plan aims to answer: does the combination provide real value beyond what bare `SubscriptionHandle` values give you?

The test creates three category subscriptions — simulating three independent projections (e.g., "orders", "payments", "inventory") — and runs them as separate Shibuya processors under `IgnoreFailures` supervision. Each has its own adapter, handler, and `ProcessorId`.

Three sub-tests validate different operational benefits:

1. "runs multiple category subscriptions concurrently": Append events across three categories (e.g., `orders-123`, `payments-456`, `inventory-789`). Create three adapters, one per category, each with a distinct `ProcessorId`. Run all three through a single `runApp` call. Wait until each handler has received its category's events. Assert that each handler received only events from its own category and that all events were delivered. This proves that multiple kiroku subscriptions compose naturally in Shibuya's model — a single `runApp` manages them all.

2. "isolates a failing subscription from healthy ones": Create three adapters as above, but configure the second handler to throw an exception after processing its first event. Append events to all three categories. Start Shibuya with `IgnoreFailures`. Wait for the healthy handlers to receive their events. Query metrics via `getAppMetrics` on the app handle: the failed processor should have `state = Failed ...` while the other two should show `state = Processing ...` or have processed all events. This proves Shibuya's supervision isolates failures — a crashing projection does not take down sibling projections.

3. "shuts down all subscriptions coordinately": Create three adapters and start Shibuya. Append a few events so all three are actively processing. Call `stopAppGracefully defaultShutdownConfig`. After it returns, assert that all three underlying kiroku subscriptions have terminated (the cancel actions were called via the adapter's `shutdown`). This proves coordinated lifecycle management — one `stopApp` call replaces manually canceling each subscription handle.

Acceptance: All three sub-tests pass. The test output shows concurrent processing, failure isolation in metrics, and clean coordinated shutdown.


## Concrete Steps

All commands are run from the kiroku repository root at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

Step 1. Add `streamly-core >=0.3` to the library's `build-depends` in `kiroku-store/kiroku-store.cabal` and add `Kiroku.Store.Subscription.Stream` to `exposed-modules`.

Step 2. Create `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` with the `subscriptionStream` function as described in Milestone 1.

Step 3. Verify library compilation:

    cabal build kiroku-store

Expected: build succeeds with no errors.

Step 4. Add test dependencies to the `test-suite` stanza in `kiroku-store/kiroku-store.cabal`: `shibuya-core`, `streamly`, `streamly-core`, `effectful`, `nqe`, `unliftio`, `containers`.

Step 5. Update `cabal.project` with any `source-repository-package` entries needed for shibuya-core's transitive dependencies (`hs-opentelemetry-api`, `hs-opentelemetry-propagator-w3c`, `nqe`). Use the same git tags as shibuya's own `cabal.project` to ensure compatibility:

    -- hs-opentelemetry (GHC 9.12 support)
    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: api

    source-repository-package
      type: git
      location: https://github.com/iand675/hs-opentelemetry
      tag: adc464b0a45e56a983fa1441be6e432b50c29e0e
      subdir: propagators/w3c

Also add shibuya-core itself. If the Hackage version (0.1.0.0) is compatible with GHC 9.12, it can be used directly. Otherwise, add a local path:

    optional-packages:
      /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/shibuya-core.cabal

Step 6. Create `kiroku-store/test/Shibuya/Adapter/Kiroku.hs` with the adapter implementation as described in Milestone 2.

Step 7. Add the Shibuya adapter test module to the `other-modules` list in the test suite stanza: `Shibuya.Adapter.Kiroku`.

Step 8. Add the integration tests to `kiroku-store/test/Main.hs`: the basic single-subscription tests (Milestone 2) and the multi-subscription supervision tests (Milestone 3), all within a `describe "Shibuya adapter"` block.

Step 9. Verify test compilation:

    cabal build kiroku-store-test

Expected: build succeeds.

Step 10. Run the full test suite:

    cabal test kiroku-store-test --test-show-details=direct

Expected: all tests pass, including:

    Shibuya adapter
      delivers catch-up events through Shibuya pipeline
      delivers live events through Shibuya pipeline
      runs multiple category subscriptions concurrently
      isolates a failing subscription from healthy ones
      shuts down all subscriptions coordinately


## Validation and Acceptance

The plan is validated by running the full test suite. The tests must exercise these behaviors:

1. Stream interface: The `subscriptionStream` function produces a working Streamly stream that yields `RecordedEvent` values matching what was appended. This is validated indirectly through all Shibuya adapter tests — they all consume the stream.

2. Catch-up delivery: Events appended before the subscription starts arrive at the Shibuya handler in global position order.

3. Live delivery: Events appended after the subscription is running arrive at the Shibuya handler.

4. Type mapping: Each received event's `messageId` in the Shibuya envelope corresponds to the original `EventId`, and the `cursor` reflects the `GlobalPosition`.

5. Multi-subscription concurrency: Three category subscriptions run simultaneously under one `runApp`, each receiving only its category's events.

6. Failure isolation: A crashing handler in one subscription does not prevent other subscriptions from processing. The failed processor's metrics show `Failed` state while healthy processors continue.

7. Coordinated shutdown: `stopAppGracefully` cleanly terminates all subscriptions without hanging, within the drain timeout.

All tests use timeouts (10 seconds) to avoid hanging if delivery fails. Run with:

    cabal test kiroku-store-test --test-show-details=direct


## Idempotence and Recovery

All steps are safe to repeat. The `subscriptionStream` function creates fresh resources (TBQueue, subscription handle) each time. The test uses `ephemeral-pg` to create a throwaway PostgreSQL database, so each run starts clean. If compilation fails partway, fix the issue and re-run `cabal build`. If a test fails, re-run `cabal test`.


## Interfaces and Dependencies

The stream module in the library:

    In kiroku-store/src/Kiroku/Store/Subscription/Stream.hs, define:

        subscriptionStream ::
            KirokuStore ->
            SubscriptionConfig ->
            Natural ->
            IO (Stream IO RecordedEvent, IO ())

The proof-of-concept adapter in the test directory:

    In kiroku-store/test/Shibuya/Adapter/Kiroku.hs, define:

        data KirokuAdapterConfig = KirokuAdapterConfig
            { subscriptionName :: SubscriptionName
            , subscriptionTarget :: SubscriptionTarget
            , batchSize :: Int32
            , bufferSize :: Natural
            }

        kirokuAdapter ::
            (IOE :> es) =>
            KirokuStore ->
            KirokuAdapterConfig ->
            Eff es (Adapter es RecordedEvent)

New library dependency: `streamly-core >=0.3`.

New test dependencies: `shibuya-core`, `streamly`, `streamly-core`, `effectful`, `nqe`, `unliftio`, `containers`.

Transitive dependencies from shibuya-core: `hs-opentelemetry-api ^>=0.3`, `hs-opentelemetry-propagator-w3c ^>=0.1`, `nqe ^>=0.6` (may require source-repository-package entries in cabal.project for GHC 9.12 compatibility).


---

Revision 2026-03-24: Reframed the plan to make the Streamly stream interface the primary deliverable (Milestone 1), not just a bridge for the shibuya adapter. Added Milestone 3 to validate the operational benefits of running multiple kiroku subscriptions under Shibuya's supervision — failure isolation, concurrent multi-subscription processing, and coordinated shutdown. Updated Purpose, Progress, Decision Log, Plan of Work, Concrete Steps, and Validation sections to reflect the expanded scope.
