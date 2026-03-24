# Make the Subscription effect higher-order

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this change, the subscription event handler can run inside the `Eff es` effect stack instead of being restricted to `IO`. This means a subscription handler can use any effects in the caller's stack — for example, appending events, reading state, or logging through an effect — without manually threading `liftIO` or managing unlift functions. The existing `IO`-based subscription API continues to work unchanged.

After implementation, a caller can write:

    withKirokuStore settings $ runStoreResource . runSubscriptionResource $ do
        result <- appendToStream (StreamName "order-1") NoStream [event]
        handle <- subscribe SubscriptionConfig
            { name    = SubscriptionName "my-projection"
            , target  = AllStreams
            , handler = \evt -> do
                -- This handler runs in Eff es — effects are available!
                _ <- appendToStream (StreamName "projected") AnyVersion [deriveEvent evt]
                pure Continue
            , batchSize = 100
            }
        ...

The subscription thread converts the `Eff`-based handler to `IO` via effectful's concurrent unlift mechanism, so the existing worker infrastructure (`Worker.hs`, `EventPublisher.hs`) is untouched.


## Progress

- [ ] Milestone 1: Make Subscribe higher-order — update GADT, interpreter, convenience wrappers
- [ ] Milestone 2: Add effectful subscription test, update re-exports, full validation


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Use `ConcUnlift Persistent (Limited 1)` as the unlift strategy for the subscription handler.
  Rationale: The subscription spawns an `Async` thread that outlives the `localUnliftIO` callback — `Persistent` keeps the unlift function valid beyond the callback scope. `Limited 1` is sufficient because the worker thread calls the handler sequentially from a single thread. This matches the pattern used in effectful's own `Fork` effect example for async threads.
  Date: 2026-03-24

- Decision: The `Subscribe` constructor becomes `Subscribe :: SubscriptionConfigM m -> Subscription m SubscriptionHandle` (higher-order because `m` appears in the config's handler field).
  Rationale: `SubscriptionConfigM m` is already parameterized by monad `m` and carries `handler :: RecordedEvent -> m SubscriptionResult`. Making the GADT use `SubscriptionConfigM m` instead of `SubscriptionConfig` (which is `SubscriptionConfigM IO`) naturally promotes the effect to higher-order with zero new types. Callers using `IO` handlers pass `SubscriptionConfig` (unchanged alias); callers using `Eff es` handlers pass `SubscriptionConfigM (Eff es)`.
  Date: 2026-03-24

- Decision: Keep `SubscriptionHandle` as `SubscriptionHandleM IO` (cancel/wait remain IO actions).
  Rationale: The async thread is managed by the Haskell runtime. Canceling and waiting on it are inherently IO operations regardless of what monad the handler runs in. There is no benefit to lifting these into the effect stack.
  Date: 2026-03-24

- Decision: The interpreter switches from `interpret_` (first-order) to `interpret` (higher-order) to gain access to `LocalEnv` for unlifting.
  Rationale: `interpret_` does not pass the `LocalEnv` to the handler. The higher-order `Subscribe` operation needs `localUnliftIO` to convert the `Eff`-based handler to `IO`, which requires the `LocalEnv`.
  Date: 2026-03-24

- Decision: Document that the subscription handle must be canceled before the effect scope exits.
  Rationale: The unlift function captures the effect environment. If the `Eff` computation finishes (e.g., `runEff` returns) while the subscription thread is still running, the environment becomes invalid. This is the same lifecycle constraint as the existing `IO` API where subscriptions must be canceled before `withStore` exits. No new risk is introduced.
  Date: 2026-03-24


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan builds on the work in `docs/plans/effectful-infrastructure-effects.md`, which introduced a first-order `Subscription` effect alongside the existing `MonadIO`-based subscription API. The relevant modules are:

`kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` — The current first-order `Subscription` effect. Defines the `Subscription` GADT with a single `Subscribe` constructor, a `subscribe` convenience wrapper that calls `send`, and two interpreters: `runSubscription` (takes `KirokuStore` parameter) and `runSubscriptionResource` (reads store from `KirokuStoreResource`). Both use `interpret_` (first-order interpreter) and delegate to `Sub.subscribe` from the infrastructure layer.

`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` — Defines the monad-parameterized types. `SubscriptionConfigM m` holds the subscription name, target, handler (`EventHandlerM m = RecordedEvent -> m SubscriptionResult`), and batch size. `SubscriptionConfig` is the IO-defaulted alias `SubscriptionConfigM IO`. `SubscriptionHandleM m` holds cancel/wait actions. `SubscriptionHandle` is `SubscriptionHandleM IO`.

`kiroku-store/src/Kiroku/Store/Subscription.hs` — The `MonadIO`-based `subscribe` function. Takes a `KirokuStore` and `SubscriptionConfig`, spawns an `Async` thread running the worker, returns a `SubscriptionHandle`. This is the infrastructure layer that the effectful interpreter delegates to.

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` — The worker loop with two phases: catch-up (queries database in batches) and live (reads from a `TChan` broadcast). Calls `handler config event` for each event. The handler is `RecordedEvent -> IO SubscriptionResult` because the config is `SubscriptionConfig` (IO-defaulted).

`kiroku-store/src/Kiroku/Store/Effect/Resource.hs` — The `KirokuStoreResource` static effect carrying a `KirokuStore` handle. Provides `getKirokuStore` and `withKirokuStore`.

`kiroku-store/src/Kiroku/Store.hs` — Public re-export module. Re-exports `Subscription`, `runSubscription`, and `runSubscriptionResource` (but not the effectful `subscribe` to avoid name clash).

`kiroku-store/test/Main.hs` — hspec test suite. Subscription tests start at line 549 and use the `IO`-based API (`subscribe store cfg` with `IO` handlers).

**Effectful concepts used in this plan:**

A "first-order" effect is one whose GADT constructors do not mention the monad parameter `m` in their arguments. A "higher-order" effect is one where `m` appears in at least one constructor's arguments — for example, `Subscribe :: SubscriptionConfigM m -> Subscription m SubscriptionHandle` is higher-order because `SubscriptionConfigM m` contains a field `handler :: RecordedEvent -> m SubscriptionResult`.

First-order effects are interpreted with `interpret_ :: EffectHandler_ e es -> Eff (e : es) a -> Eff es a`, which provides no access to the caller's environment. Higher-order effects are interpreted with `interpret :: EffectHandler e es -> Eff (e : es) a -> Eff es a`, where the handler receives a `LocalEnv localEs es` — a snapshot of the effect environment at the call site.

`localUnliftIO` uses the `LocalEnv` to create an unlifting function that converts `Eff localEs r` to `IO r`. Its signature (from `Effectful.Dispatch.Dynamic`):

    localUnliftIO
        :: (HasCallStack, SharedSuffix es handlerEs, IOE :> es)
        => LocalEnv localEs handlerEs
        -> UnliftStrategy
        -> ((forall r. Eff localEs r -> IO r) -> IO a)
        -> Eff es a

The `UnliftStrategy` controls how the unlift function behaves across threads. `ConcUnlift Persistent (Limited 1)` means: the unlift function persists beyond the callback scope (`Persistent`), and at most one thread uses it at a time (`Limited 1`). `Persistence` is a data type with constructors `Ephemeral` and `Persistent`. `Limit` is a data type with constructors `Limited !Int` and `Unlimited`.

`SharedSuffix es handlerEs` is a constraint that ensures the two effect stacks share a common polymorphic tail. It is automatically satisfied when effect stacks are polymorphic (the normal case). A compile-time error occurs if used with monomorphic stacks like `Eff '[IOE] a`.


## Plan of Work

The work is split into two milestones. The first makes the effect higher-order. The second validates with tests and updates re-exports.

### Milestone 1 — Make Subscribe higher-order

Scope: Change the `Subscribe` constructor in the `Subscription` GADT to accept `SubscriptionConfigM m` instead of the IO-fixed `SubscriptionConfig`. Switch the interpreter from `interpret_` to `interpret` and use `localUnliftIO` with `ConcUnlift Persistent (Limited 1)` to convert the `Eff`-based handler to `IO` before delegating to the infrastructure layer.

In `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs`:

Change the GADT constructor from:

    Subscribe :: SubscriptionConfig -> Subscription m SubscriptionHandle

to:

    Subscribe :: SubscriptionConfigM m -> Subscription m SubscriptionHandle

This makes the effect higher-order because `SubscriptionConfigM m` carries `handler :: RecordedEvent -> m SubscriptionResult`.

Update the `subscribe` convenience wrapper. The signature changes from:

    subscribe :: (HasCallStack, Subscription :> es) => SubscriptionConfig -> Eff es SubscriptionHandle

to:

    subscribe :: (HasCallStack, Subscription :> es) => SubscriptionConfigM (Eff es) -> Eff es SubscriptionHandle

This allows callers to pass a config whose handler uses any effects available in `es`.

Update the `runSubscription` interpreter. Replace `interpret_` with `interpret` to receive the `LocalEnv`. Inside the handler for `Subscribe config`, use `localUnliftIO env (ConcUnlift Persistent (Limited 1))` to obtain an unlift function, convert the config's handler from `Eff localEs` to `IO`, then delegate to the existing `Sub.subscribe` infrastructure function. The new signature:

    runSubscription ::
        (IOE :> es) =>
        KirokuStore ->
        Eff (Subscription : es) a ->
        Eff es a
    runSubscription store = interpret $ \env -> \case
        Subscribe config ->
            localUnliftIO env (ConcUnlift Persistent (Limited 1)) $ \unlift -> do
                let ioConfig = config { handler = \evt -> unlift (handler config evt) }
                Sub.subscribe store ioConfig

The `localUnliftIO` callback runs in `IO` and returns the `SubscriptionHandle`. The `unlift` function persists beyond the callback, so the async worker thread can continue to use it.

The imports change: add `interpret` and `localUnliftIO` from `Effectful.Dispatch.Dynamic`, add `UnliftStrategy (..)`, `Persistence (..)`, `Limit (..)` from `Effectful`, and add `SubscriptionConfigM` (in addition to `SubscriptionConfig`) from `Types`.

Update `runSubscriptionResource` — it just wraps `runSubscription`, so no logic change needed. Only the type of `action` changes because `Subscription` is now higher-order, but since `runSubscriptionResource` delegates to `runSubscription` which handles the unlifting, no changes to its body are needed.

At the end of this milestone, `cabal build kiroku-store` succeeds. The existing test suite compiles but does not yet exercise the effectful handler path (the IO-based tests construct `SubscriptionConfig` which is `SubscriptionConfigM IO`, and the interpreter's `unlift` is `id` for `IO` actions... actually no, the unlift converts `Eff localEs r` to `IO r`, not `IO r` to `IO r`).

Wait — there is an important subtlety. The existing tests use the `IO`-based `Kiroku.Store.Subscription.subscribe` directly, not the effectful `subscribe`. So they are unaffected by this change. The effectful `subscribe` wrapper is only used when the caller imports `Kiroku.Store.Subscription.Effect`.

However, the `Subscription` effect's `Subscribe` constructor now expects `SubscriptionConfigM m` where `m ~ Eff localEs`. A caller passing `SubscriptionConfig` (which is `SubscriptionConfigM IO`) would need `m ~ IO`, not `m ~ Eff localEs`. Since the GADT binds `m` to the local effect monad, the caller must provide a config where the handler matches the monad of the effect stack.

This means callers who want `IO` handlers with the effectful API need to `liftIO` inside their handler:

    subscribe SubscriptionConfig
        { handler = \evt -> liftIO (myIOHandler evt)
        , ...
        }

This is acceptable and idiomatic for effectful. The `IO`-based API (`Kiroku.Store.Subscription.subscribe`) remains for callers who don't want the effect stack.

Acceptance: `cabal build kiroku-store` succeeds. The existing test suite compiles and passes (tests use the IO-based API, not the effectful one).

### Milestone 2 — Add effectful subscription test, update re-exports, full validation

Scope: Add a test that exercises the higher-order subscription path — a handler that runs in `Eff es` and uses effects from the stack. Update re-exports if needed. Run the full test suite.

In `kiroku-store/test/Main.hs`, add a new test inside the `subscribe` describe block that:

1. Appends events to a stream using `runStoreIO`.
2. Creates a subscription using the effectful API with a handler that runs in `Eff es` (using `IORef` operations via `liftIO` to count events — this proves the handler runs through the unlift path rather than being pure `IO`).
3. Uses `runEff` to peel the effect stack.
4. Verifies all events were received.

The test imports `Kiroku.Store.Subscription.Effect` (qualified or selective) to get the effectful `subscribe`. It constructs a `SubscriptionConfigM (Eff es)` where the handler uses `liftIO` (proving it runs in `Eff`, not raw `IO`).

A more interesting test would have the handler use a non-IO effect (like `State`), but `State` is from `effectful` (not `effectful-core`) and may not be a dependency. Using `liftIO` inside the `Eff` handler is sufficient to prove the unlift mechanism works — the handler type is `RecordedEvent -> Eff es SubscriptionResult` where `IOE :> es`, and it exercises the `localUnliftIO` + `ConcUnlift Persistent` path.

Update `kiroku-store/src/Kiroku/Store.hs` if needed — the re-exports of `Subscription`, `runSubscription`, and `runSubscriptionResource` should still work since the types are compatible.

Acceptance: `cabal test kiroku-store-test` passes with all tests green including the new effectful subscription test. `cabal build all` succeeds.


## Concrete Steps

All commands run from the working directory `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/`.

**Build after Milestone 1:**

    cabal build kiroku-store

Expected: `Build succeeded.`

**Run tests after Milestone 2:**

    cabal test kiroku-store-test

Expected: All specs pass, including the new effectful subscription test.

**Build all targets after Milestone 2:**

    cabal build all

Expected: Library, tests, and benchmarks all build.


## Validation and Acceptance

1. `cabal build kiroku-store` compiles cleanly after Milestone 1.
2. `cabal test kiroku-store-test` passes — all existing IO-based subscription tests are unchanged and still pass, proving backward compatibility. The new effectful subscription test proves that an `Eff es` handler works through the `localUnliftIO` + `ConcUnlift Persistent` unlift path.
3. `cabal build all` succeeds — benchmarks and tests compile.
4. The `Subscription` GADT's `Subscribe` constructor accepts `SubscriptionConfigM m` (higher-order).
5. The `subscribe` convenience wrapper accepts `SubscriptionConfigM (Eff es)`.
6. The `runSubscription` interpreter uses `interpret` + `localUnliftIO` with `ConcUnlift Persistent (Limited 1)`.
7. The existing `MonadIO`-based API (`Kiroku.Store.Subscription.subscribe`) is unchanged.


## Idempotence and Recovery

Both milestones are independently compilable. If Milestone 1 fails partway, revert changes to `Subscription/Effect.hs` and retry. If the `ConcUnlift Persistent` strategy causes issues (e.g., resource leaks or runtime errors), the prototype can be rolled back by restoring the first-order `Subscribe` constructor and `interpret_`. The existing `IO`-based API is never modified.


## Interfaces and Dependencies

**No new dependencies.** The library already has `effectful-core >= 2.4` which provides `interpret`, `localUnliftIO`, `LocalEnv`, `UnliftStrategy(..)`, `Persistence(..)`, and `Limit(..)` from `Effectful.Dispatch.Dynamic` and `Effectful`.

**Changed module:**

`kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` — Updated `Subscription` GADT, `subscribe` wrapper, `runSubscription` and `runSubscriptionResource` interpreters.

**Type signatures after implementation:**

In `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs`:

    -- GADT (changed from first-order to higher-order)
    data Subscription :: Effect where
        Subscribe :: SubscriptionConfigM m -> Subscription m SubscriptionHandle

    type instance DispatchOf Subscription = Dynamic

    -- Convenience wrapper (now accepts Eff-parameterized config)
    subscribe :: (HasCallStack, Subscription :> es) => SubscriptionConfigM (Eff es) -> Eff es SubscriptionHandle

    -- Interpreters (unchanged signatures, new implementation)
    runSubscription :: (IOE :> es) => KirokuStore -> Eff (Subscription : es) a -> Eff es a
    runSubscriptionResource :: (IOE :> es, KirokuStoreResource :> es) => Eff (Subscription : es) a -> Eff es a
