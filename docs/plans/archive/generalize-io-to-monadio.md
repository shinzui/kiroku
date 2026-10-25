# Generalize IO to MonadIO m across kiroku-store

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this change, every public function in kiroku-store that currently returns `IO a` will instead be polymorphic in `MonadIO m => m a` (or `MonadUnliftIO m => m a` where bracket/catch semantics are needed). Types that embed `IO` in their fields (`EventHandler`, `SubscriptionHandle`, `ConnectionSettings`) will be parameterized by `m`. This prepares the codebase for a future effectful migration: callers can already use these functions and types in `Eff es` stacks via `liftIO`, and when effectful effects are introduced for subscriptions and connections, the polymorphic signatures will shrink the diff.

After implementation, the existing test suite and benchmarks must still compile and pass with `m` instantiated to `IO`. No user-visible behavior changes.


## Progress

- [x] Milestone 1: Add `unliftio-core` dependency to `kiroku-store.cabal` (2026-03-24)
- [x] Milestone 2: Parameterize types — `EventHandler`, `SubscriptionHandle`, `ConnectionSettings` (2026-03-24)
- [x] Milestone 3: Generalize `Kiroku.Store.Schema` (`initializeSchema`) (2026-03-24)
- [x] Milestone 4: Generalize `Kiroku.Store.Notification` (`startNotifier`, `stopNotifier`) (2026-03-24)
- [x] Milestone 5: Generalize `Kiroku.Store.Subscription.EventPublisher` (`startPublisher`, `stopPublisher`) (2026-03-24)
- [x] Milestone 6: Generalize `Kiroku.Store.Subscription.Worker` (`runWorker` and helpers) (2026-03-24)
- [x] Milestone 7: Generalize `Kiroku.Store.Subscription` (`subscribe`) (2026-03-24)
- [x] Milestone 8: Generalize `Kiroku.Store.Connection` (`withStore`) (2026-03-24)
- [x] Milestone 9: Generalize `Kiroku.Store.Effect` (`prepareEvents`, `runStoreIO`) (2026-03-24)
- [x] Milestone 10: Update `Kiroku.Store` re-exports and fix test/bench compilation (2026-03-24)
- [x] Milestone 11: Full build and test validation (2026-03-24)


## Surprises & Discoveries

- All milestones 1-10 compiled on first attempt with no issues. The type alias strategy (`type SubscriptionConfig = SubscriptionConfigM IO`) worked seamlessly — test and bench code required zero changes. GHC inferred `m ~ IO` everywhere without explicit annotations.


## Decision Log

- Decision: Use `MonadIO m` as the primary constraint, with `MonadUnliftIO m` only where `bracket` or `catch` is required.
  Rationale: `MonadIO` is sufficient for the vast majority of functions (database calls, STM, concurrency). Only `withStore` (which uses `bracket`) and `listenerLoop` (which uses `catch`) require `MonadUnliftIO`. Using the weaker constraint where possible keeps the API flexible.
  Date: 2026-03-24

- Decision: Parameterize `EventHandler`, `SubscriptionHandle`, and `ConnectionSettings` by a type variable `m` rather than leaving them monomorphic.
  Rationale: These types embed `IO` in callback/action fields. Parameterizing them by `m` allows effectful callers to provide handlers in their own monad stack. Type aliases like `type EventHandler = EventHandlerM IO` preserve backwards compatibility for callers that don't need the generality.
  Date: 2026-03-24

- Decision: Internal functions (e.g., `listenerLoop`, `publisherLoop`, `acquireOrFail`) that spawn threads, use `forever`, or do heavy concurrency will also be generalized where practical, but may remain `IO` if generalization adds no value (the thread body must be `IO` because `Async.async` takes `IO a`).
  Rationale: `Async.async` has type `IO a -> IO (Async a)`. The callback given to `async` must be `IO`. The outer function (e.g., `startNotifier`) can be `MonadIO m` by using `liftIO` to call `async`, but the thread body itself stays `IO`. This is the natural boundary.
  Date: 2026-03-24

- Decision: Keep `runStoreIO` signature as-is (it is the final unwrapper to `IO`) but generalize `prepareEvents` to `MonadIO m`.
  Rationale: `runStoreIO` is explicitly the "run everything down to IO" convenience function. Its purpose is to produce `IO`. `prepareEvents` just generates UUIDs and can be trivially generalized.
  Date: 2026-03-24


## Outcomes & Retrospective

All 11 milestones completed. Every public `IO` function (except `runStoreIO` by design) is now `MonadIO m` or `MonadUnliftIO m`. Types are parameterized by `m` with `IO`-defaulted aliases. The entire library, test suite, and benchmark suite compile cleanly. No downstream code changes were needed thanks to the type alias strategy. The `unliftio-core` dependency was the only new addition. The codebase is now ready for a future effectful migration of the infrastructure layer.


## Context and Orientation

kiroku-store is a PostgreSQL event store library in Haskell. It lives under `kiroku-store/` with source in `kiroku-store/src/Kiroku/Store/`. The build system is Cabal (`kiroku-store/kiroku-store.cabal`), using GHC2024.

The codebase already uses `effectful-core` for the `Store` effect (defined in `Effect.hs`). The Store effect provides a high-level API for reading, appending, linking, and lifecycle operations. Its interpreter (`runStorePool`) uses `Eff.liftIO` to run `IO` actions within the effectful stack. The effect-layer modules (`Append.hs`, `Read.hs`, `Link.hs`, `Lifecycle.hs`) are pure effect constructors with no `IO` in their signatures — they need no changes.

The `IO` that needs generalizing lives in the **infrastructure layer**: connection management, schema initialization, LISTEN/NOTIFY, the event publisher, the subscription worker, and subscription entry point. These modules use `IO` directly for database calls via `hasql-pool`, concurrency via `async` and `stm`, and exception handling via `Control.Exception`.

Key modules and their current `IO` surface:

`kiroku-store/src/Kiroku/Store/Types.hs` — Pure data types. No `IO`. No changes needed.

`kiroku-store/src/Kiroku/Store/Error.hs` — Pure error mapping. No `IO`. No changes needed.

`kiroku-store/src/Kiroku/Store/SQL.hs` — Pure hasql statement definitions. No `IO`. No changes needed.

`kiroku-store/src/Kiroku/Store/Schema.hs` — `initializeSchema :: Pool -> Text -> IO ()`. Uses `Pool.use` and `throwIO`.

`kiroku-store/src/Kiroku/Store/Notification.hs` — `startNotifier :: Text -> Text -> IO Notifier`, `stopNotifier :: Notifier -> IO ()`. Uses `Async.async`, `newBroadcastTChanIO`, `Notifications.listen`, `catch`, `threadDelay`.

`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` — Contains `type EventHandler = RecordedEvent -> IO SubscriptionResult` and `data SubscriptionHandle` with `IO` action fields.

`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` — `startPublisher :: Pool -> TChan () -> IO EventPublisher`, `stopPublisher :: EventPublisher -> IO ()`. Uses `Async.async`, `newBroadcastTChanIO`, `newTVarIO`, `registerDelay`.

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` — `runWorker :: Pool -> Text -> TChan (Vector RecordedEvent) -> TVar GlobalPosition -> SubscriptionConfig -> IO ()` and several internal helpers. Uses `Pool.use`, `atomically`, handler callbacks.

`kiroku-store/src/Kiroku/Store/Subscription.hs` — `subscribe :: KirokuStore -> SubscriptionConfig -> IO SubscriptionHandle`. Uses `Async.async`, `atomically`.

`kiroku-store/src/Kiroku/Store/Connection.hs` — `withStore :: ConnectionSettings -> (KirokuStore -> IO a) -> IO a`. Uses `bracket`. Also `ConnectionSettings` has `observationHandler :: !(Maybe (Observation -> IO ()))`.

`kiroku-store/src/Kiroku/Store/Effect.hs` — `prepareEvents :: [EventData] -> IO [PreparedEvent]` (internal), `runStoreIO :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)` (convenience runner).

`kiroku-store/test/Main.hs` — Test suite using hspec. Calls `withStore`, `runStoreIO`, `subscribe`, creates `SubscriptionConfig` with `IO`-based handler.

`kiroku-store/bench/Main.hs` — Benchmark suite. Calls `withStore`, `runStoreIO`.

**Term definitions:**

- `MonadIO m` — A typeclass from `Control.Monad.IO.Class` (in `base`) for monads that can embed `IO` actions via `liftIO :: IO a -> m a`. Every function returning `IO a` can be generalized to `MonadIO m => m a` by wrapping internal IO calls with `liftIO`.

- `MonadUnliftIO m` — A typeclass from `Control.Monad.IO.Unlift` (in `unliftio-core`) for monads that support running `m` computations back in `IO`. Required for functions that pass callbacks to IO-based functions like `bracket :: IO a -> (a -> IO b) -> (a -> IO c) -> IO c` or `catch :: IO a -> (SomeException -> IO a) -> IO a`.

- `effectful` / `Eff es` — The effect system already in use for the `Store` effect. `Eff es` satisfies both `MonadIO` (when `IOE :> es`) and `MonadUnliftIO` (when `IOE :> es`), so generalized functions will work seamlessly in effectful stacks.


## Plan of Work

The work proceeds bottom-up through the module dependency graph: types first, then leaf modules, then modules that depend on them, and finally the public API re-exports and tests.

### Milestone 1 — Add `unliftio-core` dependency

Scope: Add `unliftio-core` to the library's `build-depends` in `kiroku-store.cabal`. This package provides `MonadUnliftIO` and is a minimal dependency (no transitive extras). After this milestone, `import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)` will be available.

Acceptance: `cabal build kiroku-store` succeeds with the new dependency.

Edit `kiroku-store/kiroku-store.cabal`, in the `library` stanza's `build-depends`, add `unliftio-core >= 0.2` after the `uuid` entry.

### Milestone 2 — Parameterize types

Scope: Modify `Kiroku.Store.Subscription.Types` and `Kiroku.Store.Connection` to parameterize IO-bearing types by `m`. Provide type aliases that default `m` to `IO` for backwards compatibility.

**In `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`:**

Change `EventHandler` from a type alias to a parameterized alias:

    type EventHandlerM m = RecordedEvent -> m SubscriptionResult
    type EventHandler = EventHandlerM IO

Parameterize `SubscriptionConfig` by `m`:

    data SubscriptionConfigM m = SubscriptionConfig
        { name :: !SubscriptionName
        , target :: !SubscriptionTarget
        , handler :: !(EventHandlerM m)
        , batchSize :: !Int32
        }
    type SubscriptionConfig = SubscriptionConfigM IO

Parameterize `SubscriptionHandle` by `m`:

    data SubscriptionHandleM m = SubscriptionHandle
        { cancel :: !(m ())
        , wait :: !(m (Either SomeException ()))
        }
    type SubscriptionHandle = SubscriptionHandleM IO

Update module exports to include both the parameterized types and the `IO`-defaulted aliases.

**In `kiroku-store/src/Kiroku/Store/Connection.hs`:**

Parameterize `ConnectionSettings` by `m`:

    data ConnectionSettingsM m = ConnectionSettings
        { connString :: !Text
        , poolSize :: !Int
        , schema :: !Text
        , idleInTransactionTimeout :: !Int
        , observationHandler :: !(Maybe (Observation -> m ()))
        }
        deriving stock (Generic)
    type ConnectionSettings = ConnectionSettingsM IO

Update `defaultConnectionSettings` to remain at the `IO`-defaulted alias type.

Acceptance: `cabal build kiroku-store` succeeds. No downstream modules break because the type aliases preserve the original names.

### Milestone 3 — Generalize Schema

Scope: Change `initializeSchema` from `Pool -> Text -> IO ()` to `MonadIO m => Pool -> Text -> m ()`.

In `kiroku-store/src/Kiroku/Store/Schema.hs`:

1. Add `import Control.Monad.IO.Class (MonadIO, liftIO)`.
2. Change the signature: `initializeSchema :: MonadIO m => Pool -> Text -> m ()`.
3. Wrap the body with `liftIO`: replace the bare `do` block with `liftIO $ do ...` or wrap individual IO actions.

Acceptance: `cabal build kiroku-store` succeeds. The function is callable from `IO` (no change for existing callers) and from any `MonadIO m`.

### Milestone 4 — Generalize Notification

Scope: Generalize `startNotifier` and `stopNotifier` to `MonadIO m`. Internal helpers (`listenerLoop`, `acquireOrFail`) stay `IO` because they are thread bodies passed to `Async.async`.

In `kiroku-store/src/Kiroku/Store/Notification.hs`:

1. Add `import Control.Monad.IO.Class (MonadIO, liftIO)`.
2. Change `startNotifier :: MonadIO m => Text -> Text -> m Notifier`. Wrap the body's IO actions with `liftIO`.
3. Change `stopNotifier :: MonadIO m => Notifier -> m ()`. Wrap with `liftIO`.
4. `listenerLoop` and `acquireOrFail` remain `IO` — they are only called from the async thread body.

Acceptance: `cabal build kiroku-store` succeeds.

### Milestone 5 — Generalize EventPublisher

Scope: Generalize `startPublisher` and `stopPublisher` to `MonadIO m`. Internal loop functions remain `IO`.

In `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`:

1. Add `import Control.Monad.IO.Class (MonadIO, liftIO)`.
2. Change `startPublisher :: MonadIO m => Pool -> TChan () -> m EventPublisher`. Wrap IO actions with `liftIO`.
3. Change `stopPublisher :: MonadIO m => EventPublisher -> m ()`. Wrap IO actions with `liftIO`.
4. `publisherLoop`, `waitForWakeup`, `drainTicks` remain `IO` (thread bodies).

Acceptance: `cabal build kiroku-store` succeeds.

### Milestone 6 — Generalize Subscription Worker

Scope: Generalize `runWorker` to `MonadIO m`. Internal helpers remain `IO` since they are called from thread bodies (spawned by `subscribe`). The worker itself is always invoked inside an `Async.async` callback, so the outer generalization benefits the `subscribe` call site.

In `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`:

1. Add `import Control.Monad.IO.Class (MonadIO, liftIO)`.
2. Change `runWorker :: MonadIO m => Pool -> Text -> TChan (Vector RecordedEvent) -> TVar GlobalPosition -> SubscriptionConfig -> m ()`.
3. Wrap the body with `liftIO` (since the internal functions `loadCheckpoint`, `catchUp`, `liveLoop` stay `IO`).

Acceptance: `cabal build kiroku-store` succeeds.

### Milestone 7 — Generalize Subscription entry point

Scope: Generalize `subscribe` to `MonadIO m`. The returned `SubscriptionHandle` remains `SubscriptionHandleM IO` because the cancel/wait actions are inherently `IO` (they cancel an `Async` thread).

In `kiroku-store/src/Kiroku/Store/Subscription.hs`:

1. Add `import Control.Monad.IO.Class (MonadIO, liftIO)`.
2. Change `subscribe :: MonadIO m => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle`. Wrap the body with `liftIO`.

Acceptance: `cabal build kiroku-store` succeeds.

### Milestone 8 — Generalize Connection

Scope: Generalize `withStore` to `MonadUnliftIO m`. This requires `MonadUnliftIO` because `bracket` passes callbacks.

In `kiroku-store/src/Kiroku/Store/Connection.hs`:

1. Replace `import Control.Exception (bracket)` with `import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)` and `import Control.Monad.IO.Class (liftIO)`.
2. Change `withStore :: MonadUnliftIO m => ConnectionSettings -> (KirokuStore -> m a) -> m a`.
3. Rewrite `withStore` to use `withRunInIO` to unlift the user's callback into `IO`, then call the original `bracket acquire release` pattern inside `IO`, and lift back. Alternatively, use `bracket` from `unliftio` which has the `MonadUnliftIO` signature.

The implementation:

    withStore :: MonadUnliftIO m => ConnectionSettings -> (KirokuStore -> m a) -> m a
    withStore settings action = withRunInIO $ \runInIO ->
        bracket acquire release (runInIO . action)

Here, `acquire` and `release` remain internal `IO` functions (they set up pools, notifiers, publishers — all fundamentally `IO`).

Acceptance: `cabal build kiroku-store` succeeds. `withStore` is callable from `IO` (since `IO` has a `MonadUnliftIO` instance) and from `Eff es` when `IOE :> es`.

### Milestone 9 — Generalize Effect helpers

Scope: Generalize `prepareEvents` to `MonadIO m`. Leave `runStoreIO` as `IO` (it is the terminal runner).

In `kiroku-store/src/Kiroku/Store/Effect.hs`:

1. Add `import Control.Monad.IO.Class (MonadIO, liftIO)`.
2. Change `prepareEvents :: MonadIO m => [EventData] -> m [PreparedEvent]`. Wrap `V7.genUUIDs` call with `liftIO`.
3. In `runStorePool`, the `Eff.liftIO (prepareEvents events)` call can drop the `Eff.liftIO` wrapper since `prepareEvents` is now polymorphic in `m` and `Eff` is `MonadIO` when `IOE :> es`. Alternatively, keep it — `Eff.liftIO` works because `prepareEvents` instantiated at `IO` is fine.

Acceptance: `cabal build kiroku-store` succeeds.

### Milestone 10 — Update re-exports and fix test/bench

Scope: Ensure `Kiroku.Store` re-exports the new parameterized types and aliases. Fix any compilation issues in `test/Main.hs` and `bench/Main.hs`.

In `kiroku-store/src/Kiroku/Store.hs`: Verify the re-exports cover the new type aliases. Since we used `type SubscriptionConfig = SubscriptionConfigM IO` etc., downstream code that says `SubscriptionConfig` still works.

In `kiroku-store/test/Main.hs` and `kiroku-store/bench/Main.hs`: These should compile without changes because:
- `withStore` with `m ~ IO` works (IO has `MonadUnliftIO`)
- `subscribe` with `m ~ IO` works
- `SubscriptionConfig` is aliased to `SubscriptionConfigM IO`
- `EventHandler` is aliased to `EventHandlerM IO`

If any issues arise (e.g., GHC unable to infer `m ~ IO`), add explicit type annotations.

Acceptance: `cabal build all` succeeds. `cabal test kiroku-store-test` passes.

### Milestone 11 — Full validation

Scope: Run the full test suite and verify no regressions.

Acceptance: `cabal test kiroku-store-test` passes with all tests green. `cabal build kiroku-store-bench` compiles.


## Concrete Steps

All commands are run from the working directory `kiroku-store/` (i.e., `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/`).

**Build after each milestone:**

    cabal build kiroku-store

Expected: `Build profile: ... kiroku-store-0.1.0.0 ... Build succeeded.`

**Run tests after Milestone 10:**

    cabal test kiroku-store-test

Expected: All specs pass.

**Build benchmarks:**

    cabal build kiroku-store-bench

Expected: Build succeeds.


## Validation and Acceptance

The change is purely mechanical (widening type signatures). Acceptance criteria:

1. `cabal build kiroku-store` compiles cleanly with no warnings related to the changes.
2. `cabal test kiroku-store-test` passes — all existing tests exercise the code with `m ~ IO`, proving that the generalized signatures are backwards-compatible.
3. `cabal build kiroku-store-bench` compiles.
4. Every public function that previously returned `IO a` now has a `MonadIO m` or `MonadUnliftIO m` constraint (except `runStoreIO`, which stays `IO` by design).
5. Types `EventHandlerM m`, `SubscriptionConfigM m`, `SubscriptionHandleM m`, and `ConnectionSettingsM m` are exported. The `IO`-defaulted aliases (`EventHandler`, `SubscriptionConfig`, `SubscriptionHandle`, `ConnectionSettings`) preserve backwards compatibility.


## Idempotence and Recovery

Every milestone is independently compilable. If a milestone fails partway, revert the changes to that module and retry. The type alias strategy means that downstream code is not affected until types are explicitly changed to use the parameterized variants.

The `unliftio-core` dependency addition (Milestone 1) is additive and safe to repeat.


## Interfaces and Dependencies

**New dependency:** `unliftio-core >= 0.2` — provides `Control.Monad.IO.Unlift` with `MonadUnliftIO` and `withRunInIO`. This is a lightweight package (no transitive dependencies beyond `base`). It is needed for `withStore` which uses `bracket`.

**Existing dependency:** `base` already provides `Control.Monad.IO.Class` with `MonadIO` and `liftIO`.

**Type signatures after implementation:**

In `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`:

    type EventHandlerM m = RecordedEvent -> m SubscriptionResult
    type EventHandler = EventHandlerM IO

    data SubscriptionConfigM m = SubscriptionConfig { ... handler :: !(EventHandlerM m) ... }
    type SubscriptionConfig = SubscriptionConfigM IO

    data SubscriptionHandleM m = SubscriptionHandle { ... cancel :: !(m ()), wait :: !(m (Either SomeException ())) ... }
    type SubscriptionHandle = SubscriptionHandleM IO

In `kiroku-store/src/Kiroku/Store/Connection.hs`:

    data ConnectionSettingsM m = ConnectionSettings { ... observationHandler :: !(Maybe (Observation -> m ())) ... }
    type ConnectionSettings = ConnectionSettingsM IO

    withStore :: MonadUnliftIO m => ConnectionSettingsM m -> (KirokuStore -> m a) -> m a

In `kiroku-store/src/Kiroku/Store/Schema.hs`:

    initializeSchema :: MonadIO m => Pool -> Text -> m ()

In `kiroku-store/src/Kiroku/Store/Notification.hs`:

    startNotifier :: MonadIO m => Text -> Text -> m Notifier
    stopNotifier :: MonadIO m => Notifier -> m ()

In `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`:

    startPublisher :: MonadIO m => Pool -> TChan () -> m EventPublisher
    stopPublisher :: MonadIO m => EventPublisher -> m ()

In `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`:

    runWorker :: MonadIO m => Pool -> Text -> TChan (Vector RecordedEvent) -> TVar GlobalPosition -> SubscriptionConfig -> m ()

In `kiroku-store/src/Kiroku/Store/Subscription.hs`:

    subscribe :: MonadIO m => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle

In `kiroku-store/src/Kiroku/Store/Effect.hs`:

    prepareEvents :: MonadIO m => [EventData] -> m [PreparedEvent]
    runStoreIO :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)  -- unchanged
