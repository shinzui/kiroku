# Introduce effectful effects for infrastructure and clean up Store interpreter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this change, subscriptions and store lifecycle management are first-class effectful effects alongside the existing `Store` effect. Callers can `subscribe` to event streams and manage the `KirokuStore` handle through the effect stack rather than threading IO handles manually. The Store interpreter is also cleaned up: it calls `MonadIO`-generalized helpers directly (no redundant `Eff.liftIO` wrappers) and uses a `usePool` helper to eliminate the repetitive `Pool.use` + error-handling boilerplate that currently appears in every case branch.

After implementation, a caller can write:

    withKirokuStore settings $ runStorePool . runSubscription $ do
        result <- appendToStream (StreamName "order-1") NoStream [event]
        handle <- subscribe config
        ...

The existing `IO`-based API (`withStore`, `runStoreIO`, `subscribe`) continues to work unchanged. The new effectful API is an additional layer for callers who are already working inside `Eff es`. The test suite and benchmarks must still compile and pass.


## Progress

- [x] Milestone 1: Clean up Store interpreter — extract `usePool` helper, use `prepareEvents` directly (2026-03-24)
- [x] Milestone 2: Add `Subscription` effect with `runSubscription` interpreter (2026-03-24)
- [x] Milestone 3: Add `KirokuStoreResource` static effect for store lifecycle (2026-03-24)
- [x] Milestone 4: Wire `runStorePool` and `runSubscription` to use `KirokuStoreResource` (2026-03-24)
- [x] Milestone 5: Update `Kiroku.Store` re-exports, `.cabal` module list, test compilation (2026-03-24)
- [x] Milestone 6: Full build and test validation (2026-03-24)


## Surprises & Discoveries

- The `HardDeleteStream` branch used `Pool.use` with a transaction session (`TxSessions.transaction`), which fits the `usePool` helper perfectly — the helper works with any `Session.Session a`, including transaction sessions. No special handling needed.


## Decision Log

- Decision: The `Subscription` effect is first-order and takes `SubscriptionConfig` (the IO-defaulted alias). The handler inside the config remains `RecordedEvent -> IO SubscriptionResult`.
  Rationale: Making the subscription effect higher-order (where the handler runs in the local `Eff` stack) is significantly more complex and requires `LocalEnv` and `localSeqUnliftIO`. The subscription worker spawns an `Async` thread whose body must be `IO`, so the handler is inherently unlifted to `IO` anyway. The first-order design is practical and can be refined later if effectful handlers are needed.
  Date: 2026-03-24

- Decision: Use a static effect (`KirokuStoreResource`) for the store lifecycle rather than a dynamic effect.
  Rationale: The store handle is a piece of runtime state that is created once and read many times. Static effects are the correct effectful pattern for this: they carry a `StaticRep` that is available throughout the effect scope. A dynamic effect would add unnecessary dispatch overhead for what is essentially a reader.
  Date: 2026-03-24

- Decision: Do not create an effectful effect for the Notifier. It remains internal infrastructure.
  Rationale: The Notifier is only used inside `Connection.hs` to start the LISTEN connection. It is never called directly by users. Wrapping it in an effect would add complexity with no practical benefit. If a `Notifier` effect is needed in the future (e.g., for injectable notification sources in tests), it can be added then.
  Date: 2026-03-24

- Decision: The new effectful API (`withKirokuStore`, `runSubscription`) is additive — the existing `MonadIO`-based API (`withStore`, `subscribe`) is preserved unchanged.
  Rationale: Existing callers should not be forced to adopt effectful. The effectful layer is for callers who are already working in `Eff es` and want a more ergonomic API.
  Date: 2026-03-24

- Decision: Provide `runStorePool` in two forms — the existing one that takes `KirokuStore` as a parameter, and a new one (`runStoreResource`) that reads the store from the `KirokuStoreResource` effect.
  Rationale: Keeps the existing API stable while providing a cleaner experience for callers using the full effect stack. The parameter-based version remains useful for callers who manage the store handle themselves (e.g., in tests with `withStore`).
  Date: 2026-03-24


## Outcomes & Retrospective

All six milestones completed on 2026-03-24. All 53 existing tests pass, benchmarks compile.

**What was delivered:**
- `usePool` helper reduced the Store interpreter from ~150 lines to ~100 lines by eliminating repetitive `Pool.use` + error-handling boilerplate.
- `Subscription` effect with `runSubscription` and `runSubscriptionResource` interpreters.
- `KirokuStoreResource` static effect with `withKirokuStore` and `getKirokuStore`.
- `runStoreResource` interpreter that reads from `KirokuStoreResource`.
- All new types and interpreters re-exported from `Kiroku.Store` (except the effectful `subscribe` wrapper, which must be imported from `Kiroku.Store.Subscription.Effect` to avoid name clash).

**Backwards compatibility:** The existing `MonadIO`-based API (`withStore`, `subscribe`, `runStoreIO`) is unchanged. No test or benchmark modifications were needed.


## Context and Orientation

kiroku-store is a PostgreSQL event store library in Haskell, located under `kiroku-store/` with source in `kiroku-store/src/Kiroku/Store/`. The build system is Cabal (`kiroku-store/kiroku-store.cabal`) using GHC2024. The library depends on `effectful-core >= 2.4` for its effect system.

The prior plan `docs/plans/generalize-io-to-monadio.md` widened all public `IO` signatures to `MonadIO m` or `MonadUnliftIO m` and parameterized types by `m`. This plan builds on that work.

**Effectful concepts used in this plan:**

An "effect" in effectful is a GADT with kind `Effect = (Type -> Type) -> Type -> Type`. Effects are classified by their `DispatchOf` type family: `Dynamic` effects are dispatched at runtime via a handler function (like `Store`), while `Static` effects carry a fixed representation value (like `IOE`).

An "interpreter" consumes an effect from the stack. For dynamic first-order effects, `interpret_ :: EffectHandler_ e es -> Eff (e : es) a -> Eff es a` takes a handler function that pattern-matches on each operation. For static effects, `evalStaticRep :: StaticRep e -> Eff (e : es) a -> Eff es a` installs the representation.

`IOE` is the IO effect. When `IOE :> es`, the `Eff es` monad has `MonadIO` and `MonadUnliftIO` instances, so `liftIO` works and `Pool.use` calls can be lifted.

`send` dispatches a dynamic effect operation. The convenience modules (`Append.hs`, `Read.hs`, etc.) wrap each `Store` GADT constructor in a function that calls `send`.

**Current module layout:**

`kiroku-store/src/Kiroku/Store/Effect.hs` — Defines the `Store` effect (12 operations, dynamic dispatch) and two interpreters: `runStorePool` (interprets against PostgreSQL via hasql-pool, requires `IOE :> es` and `Error StoreError :> es`) and `runStoreIO` (convenience runner that peels everything down to `IO (Either StoreError a)`). The interpreter uses `Eff.liftIO` to call `Pool.use`, `getCurrentTime`, and `prepareEvents`. There is no `usePool` helper; every case branch repeats the `Eff.liftIO $ Pool.use ... >> case result of Left -> throwError ...` pattern.

`kiroku-store/src/Kiroku/Store/Append.hs`, `Read.hs`, `Link.hs`, `Lifecycle.hs` — Thin wrappers that `send` each `Store` operation. Pure effect constructors with no `IO`.

`kiroku-store/src/Kiroku/Store/Connection.hs` — Defines `KirokuStore` (holds pool, schema, notifier, publisher), `ConnectionSettingsM m` (parameterized by monad), and `withStore :: MonadUnliftIO m => ConnectionSettings -> (KirokuStore -> m a) -> m a`. The `withStore` function uses `bracket` to acquire a pool, initialize the schema, start the notifier and publisher, and release them in reverse order.

`kiroku-store/src/Kiroku/Store/Subscription.hs` — `subscribe :: MonadIO m => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle`. Spawns an async worker thread.

`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` — `SubscriptionConfigM m`, `SubscriptionHandleM m`, `EventHandlerM m`, with IO-defaulted aliases.

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` — `runWorker :: MonadIO m => ... -> m ()`. Internal worker loop with catch-up and live phases.

`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` — `startPublisher`, `stopPublisher` (both `MonadIO m`). Internal event broadcaster.

`kiroku-store/src/Kiroku/Store/Notification.hs` — `startNotifier`, `stopNotifier` (both `MonadIO m`). Internal LISTEN/NOTIFY infrastructure.

`kiroku-store/src/Kiroku/Store/Schema.hs` — `initializeSchema :: MonadIO m => Pool -> Text -> m ()`. Runs embedded DDL.

`kiroku-store/src/Kiroku/Store/Store.hs` — Public re-export module.

`kiroku-store/src/Kiroku/Store/SQL.hs` — Pure hasql statement definitions.

`kiroku-store/src/Kiroku/Store/Error.hs` — `StoreError` type and error-mapping helpers.

`kiroku-store/src/Kiroku/Store/Types.hs` — Domain types (StreamName, EventData, RecordedEvent, etc.).

`kiroku-store/test/Main.hs` — hspec test suite. Uses `withStore`, `runStoreIO`, `subscribe`.

`kiroku-store/bench/Main.hs` — Benchmark suite. Uses `withStore`, `runStoreIO`.


## Plan of Work

The work is split into six milestones. Each milestone is independently compilable and verifiable.

### Milestone 1 — Clean up Store interpreter

Scope: Extract a `usePool` helper that encapsulates the `liftIO $ Pool.use pool session >> case of Left -> throwError; Right -> pure` pattern. Use `prepareEvents` directly (it is now `MonadIO m`, and `Eff es` satisfies `MonadIO` when `IOE :> es`, so the `Eff.liftIO` wrapper is redundant). This milestone touches only `kiroku-store/src/Kiroku/Store/Effect.hs`.

At the end of this milestone, the interpreter is shorter and easier to read. Every `Eff.liftIO $ Pool.use ...` followed by a `case Left/Right` is replaced by a single call to `usePool`. The `prepareEvents` calls drop their `Eff.liftIO` wrappers.

The `usePool` helper is defined inside `Effect.hs` as a local helper (not exported). Its signature:

    usePool ::
        (IOE :> es, Error StoreError :> es) =>
        Pool ->
        Session.Session a ->
        Eff es a

It calls `liftIO (Pool.use pool session)`, then maps `Left usageErr` to `throwError (ConnectionError ...)` and `Right a` to `pure a`. Operations that need custom error mapping (like `AppendToStream` which maps to `WrongExpectedVersion` etc.) continue to use `liftIO` directly and handle errors themselves.

In `runStorePool`, each case branch that follows the standard `liftIO Pool.use ... >> case Left -> throwError ConnectionError; Right -> pure` pattern is replaced with `usePool (store ^. #pool)`. This applies to: `ReadStreamForward`, `ReadStreamBackward`, `ReadAllForward`, `ReadAllBackward`, `GetStream`, `LinkToStream`, `ReadCategoryForward`, `SoftDeleteStream`, `HardDeleteStream`, `UndeleteStream`.

The `AppendToStream` and `AppendMultiStream` branches have custom error handling (they call `mapUsageError` and `emptyResultError`), so they keep their existing `liftIO`/error-handling structure but the `prepareEvents` call drops its `Eff.liftIO` wrapper.

The `getCurrentTime` calls also drop `Eff.liftIO` since `getCurrentTime :: IO UTCTime` can be called via `liftIO getCurrentTime` which is equivalent. Actually, `Eff.liftIO` and `liftIO` are the same thing (both from `MonadIO`) — the cleanup is about `prepareEvents` where the `Eff.liftIO` wrapper is now redundant because `prepareEvents` is itself `MonadIO m => ... -> m a`.

Acceptance: `cabal build kiroku-store` succeeds. The interpreter behavior is identical.

### Milestone 2 — Add Subscription effect

Scope: Define a `Subscription` effect with a `Subscribe` operation. Provide an interpreter `runSubscription` that delegates to the existing `subscribe` infrastructure function. Create a new module `kiroku-store/src/Kiroku/Store/Effect/Subscription.hs` and a convenience module `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` for the `send`-based wrapper.

The effect definition lives in `kiroku-store/src/Kiroku/Store/Effect/Subscription.hs`:

    data Subscription :: Effect where
        Subscribe :: SubscriptionConfig -> Subscription m SubscriptionHandle

    type instance DispatchOf Subscription = Dynamic

    runSubscription ::
        (IOE :> es) =>
        KirokuStore ->
        Eff (Subscription : es) a ->
        Eff es a
    runSubscription store = interpret_ $ \case
        Subscribe config -> liftIO $ subscribeIO store config

Where `subscribeIO` is the existing `subscribe` function from `Kiroku.Store.Subscription`, renamed for clarity (or we import it qualified). Actually, we can just call it directly: `Kiroku.Store.Subscription.subscribe store config` since `subscribe :: MonadIO m => ...` and `Eff es` is `MonadIO` when `IOE :> es`.

The convenience wrapper uses `send`:

    subscribe :: (HasCallStack, Subscription :> es) => SubscriptionConfig -> Eff es SubscriptionHandle
    subscribe config = send (Subscribe config)

This shadows the existing `Kiroku.Store.Subscription.subscribe` on purpose — callers using the effectful API import this one; callers using the MonadIO API import the other.

The module layout choice: rather than a deeply nested `Effect/Subscription.hs`, place the effect and interpreter together in a new module `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs`. This keeps subscription-related code together. The module exports the effect type, the `send` wrapper, and the interpreter.

Acceptance: `cabal build kiroku-store` succeeds. The new module compiles. The `Subscription` effect is usable in an `Eff es` stack.

### Milestone 3 — Add KirokuStoreResource static effect

Scope: Define a static effect `KirokuStoreResource` that carries a `KirokuStore` handle. Provide `withKirokuStore` that brackets the store lifecycle and installs the effect. Provide `getKirokuStore` to retrieve the handle. Create a new module `kiroku-store/src/Kiroku/Store/Effect/Resource.hs`.

The effect definition:

    data KirokuStoreResource :: Effect
    type instance DispatchOf KirokuStoreResource = Static WithSideEffects
    newtype instance StaticRep KirokuStoreResource = KirokuStoreResource KirokuStore

    getKirokuStore :: (KirokuStoreResource :> es) => Eff es KirokuStore
    getKirokuStore = do
        KirokuStoreResource store <- getStaticRep
        pure store

    withKirokuStore ::
        (IOE :> es) =>
        ConnectionSettings ->
        Eff (KirokuStoreResource : es) a ->
        Eff es a
    withKirokuStore settings action = withEffToIO SeqUnlift $ \unlift ->
        withStore settings $ \store ->
            unlift (evalStaticRep (KirokuStoreResource store) action)

The `withKirokuStore` function uses `withEffToIO` to unlift back to `IO`, calls the existing `withStore` bracket for lifecycle management, then installs the `KirokuStoreResource` representation and runs the inner action.

The `SeqUnlift` strategy is used because the inner action runs in the same thread as the bracket. If concurrent unlifting is needed later, callers can use `withUnliftStrategy` before calling `withKirokuStore`.

Acceptance: `cabal build kiroku-store` succeeds.

### Milestone 4 — Wire interpreters to use KirokuStoreResource

Scope: Add alternative interpreter entry points that read the store from `KirokuStoreResource` instead of taking it as a parameter. This provides a smoother experience when the full effect stack is in use.

In `kiroku-store/src/Kiroku/Store/Effect.hs`, add:

    runStoreResource ::
        (IOE :> es, Error StoreError :> es, KirokuStoreResource :> es) =>
        Eff (Store : es) a ->
        Eff es a
    runStoreResource action = do
        store <- getKirokuStore
        runStorePool store action

In `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs`, add:

    runSubscriptionResource ::
        (IOE :> es, KirokuStoreResource :> es) =>
        Eff (Subscription : es) a ->
        Eff es a
    runSubscriptionResource action = do
        store <- getKirokuStore
        runSubscription store action

These are thin wrappers but they enable the composable pattern shown in the Purpose section.

Acceptance: `cabal build kiroku-store` succeeds.

### Milestone 5 — Update module list, re-exports, test compilation

Scope: Register the new modules in `kiroku-store.cabal`. Update `Kiroku.Store` re-exports to include the new effect types and interpreters. Verify tests and benchmarks compile.

In `kiroku-store/kiroku-store.cabal`, add to `exposed-modules`:

    Kiroku.Store.Effect.Resource
    Kiroku.Store.Subscription.Effect

In `kiroku-store/src/Kiroku/Store.hs`, add re-exports for the new modules. Since `Kiroku.Store.Subscription.Effect` exports a `subscribe` function that conflicts with `Kiroku.Store.Subscription.subscribe`, the re-export module should NOT re-export the effectful `subscribe` directly — callers must import `Kiroku.Store.Subscription.Effect` explicitly to get the effectful version. The `Kiroku.Store` module continues to re-export the `MonadIO`-based `subscribe`.

However, the new types (`Subscription`, `KirokuStoreResource`) and interpreters (`runSubscription`, `runStoreResource`, `withKirokuStore`, `getKirokuStore`) should be re-exported from `Kiroku.Store` since they don't conflict.

Acceptance: `cabal build all` succeeds. Tests and benchmarks compile without changes.

### Milestone 6 — Full validation

Scope: Run the full test suite and verify no regressions. The tests use `withStore` and `runStoreIO` which are unchanged. No new tests are added in this plan (the effects are additive and the existing tests exercise the underlying infrastructure).

Acceptance: `cabal test kiroku-store-test` passes with all tests green. `cabal build kiroku-store-bench` compiles.


## Concrete Steps

All commands run from the working directory `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/`.

**Build after each milestone:**

    cabal build kiroku-store

Expected: `Build succeeded.`

**Build all targets after Milestone 5:**

    cabal build all

Expected: Library, tests, and benchmarks all build.

**Run tests after Milestone 5:**

    cabal test kiroku-store-test

Expected: All specs pass.


## Validation and Acceptance

1. `cabal build kiroku-store` compiles cleanly after every milestone.
2. `cabal test kiroku-store-test` passes — all existing tests exercise the unchanged `IO`-based API, proving the refactored interpreter is backwards-compatible.
3. `cabal build kiroku-store-bench` compiles.
4. The `Store` interpreter in `Effect.hs` uses a `usePool` helper for standard pool operations and calls `prepareEvents` without `Eff.liftIO` wrapper.
5. The `Subscription` effect type and `runSubscription` interpreter are exported.
6. The `KirokuStoreResource` static effect, `withKirokuStore`, `getKirokuStore`, `runStoreResource`, and `runSubscriptionResource` are exported.
7. The existing `MonadIO`-based API (`withStore`, `subscribe`, `runStoreIO`) continues to work unchanged.


## Idempotence and Recovery

Every milestone is independently compilable. If a milestone fails partway, revert the changes to the affected modules and retry. New modules can be deleted and recreated. The existing API is never modified in a breaking way — all changes are additive.


## Interfaces and Dependencies

**No new dependencies.** The library already has `effectful-core >= 2.4` which provides everything needed: `Effect`, `DispatchOf`, `Static`, `Dynamic`, `interpret_`, `evalStaticRep`, `getStaticRep`, `send`, `withEffToIO`, `SeqUnlift`.

**New modules:**

`kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` — Subscription effect, interpreter, `send` wrapper.

`kiroku-store/src/Kiroku/Store/Effect/Resource.hs` — KirokuStoreResource static effect, `withKirokuStore`, `getKirokuStore`.

**New type signatures after implementation:**

In `kiroku-store/src/Kiroku/Store/Effect.hs`:

    -- Existing (unchanged)
    runStorePool :: (IOE :> es, Error StoreError :> es) => KirokuStore -> Eff (Store : es) a -> Eff es a
    runStoreIO :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)

    -- New
    runStoreResource :: (IOE :> es, Error StoreError :> es, KirokuStoreResource :> es) => Eff (Store : es) a -> Eff es a

    -- Internal helper (not exported)
    usePool :: (IOE :> es, Error StoreError :> es) => Pool -> Session.Session a -> Eff es a

In `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs`:

    data Subscription :: Effect where
        Subscribe :: SubscriptionConfig -> Subscription m SubscriptionHandle
    type instance DispatchOf Subscription = Dynamic

    subscribe :: (HasCallStack, Subscription :> es) => SubscriptionConfig -> Eff es SubscriptionHandle
    runSubscription :: (IOE :> es) => KirokuStore -> Eff (Subscription : es) a -> Eff es a
    runSubscriptionResource :: (IOE :> es, KirokuStoreResource :> es) => Eff (Subscription : es) a -> Eff es a

In `kiroku-store/src/Kiroku/Store/Effect/Resource.hs`:

    data KirokuStoreResource :: Effect
    type instance DispatchOf KirokuStoreResource = Static WithSideEffects
    newtype instance StaticRep KirokuStoreResource = KirokuStoreResource KirokuStore

    getKirokuStore :: (KirokuStoreResource :> es) => Eff es KirokuStore
    withKirokuStore :: (IOE :> es) => ConnectionSettings -> Eff (KirokuStoreResource : es) a -> Eff es a
