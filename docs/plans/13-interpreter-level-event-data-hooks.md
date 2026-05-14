---
id: 13
slug: interpreter-level-event-data-hooks
title: "Interpreter-level event-data hooks"
kind: exec-plan
created_at: 2026-05-14T03:17:08Z
intention: "intention_01krj7mxdne8rv49ync50x58tv"
---

# Interpreter-level event-data hooks


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture


Today, every call into the kiroku event store — `appendToStream`, `appendMultiStream`,
`runTransactionAppending`, `readStreamForward`, `readAllForward`, `readCategory`, the
subscription pipeline — passes the caller's `EventData` straight through the
interpreter `runStorePool` (in `kiroku-store/src/Kiroku/Store/Effect.hs`) into the SQL
encoder, and returns `RecordedEvent` values back to the caller after the SQL decoder
runs. There is no built-in seam at which the caller can transform those values: if a
user wants to encrypt the JSON payload, compress it, or inject an OpenTelemetry trace
context into `EventData.metadata` on every append, they must do so at every call site
themselves.

For the sister project `keiro` — an event-sourced command-handling layer that lives on
top of kiroku — this matters in one specific way. `keiro` wants to inject
`keiro.span.trace_id` and `keiro.span.span_id` into `EventData.metadata` on every
append so that downstream subscribers can correlate events with the command that
produced them. `keiro`'s primary write path is its own `runCommand` wrapper, so the
trace context can be wired there. But every direct call into kiroku from outside
`runCommand` — for example, a maintenance script calling `appendToStream`
directly — bypasses that injection and produces events with no trace context.

This ExecPlan adds an optional, interpreter-level hook surface that fixes the leak.
After this change, a user wires two functions once at store setup:

```haskell
storeSettings = defaultStoreSettings
  { enrichEvent = Just $ \ed -> do
      tctx <- captureCurrentSpan        -- OpenTelemetry, OTLP, whatever
      pure (ed & #metadata %~ injectTraceContext tctx)
  , decodeHook = Just $ \re ->
      pure (re & #metadata %~ Just . redactPII)
  }
```

…and from that moment forward, **every** event that flows through any interpreter
branch — both the kiroku effectful API (`appendToStream`, reads) and the
transactional API (`runTransactionAppending`, `appendToStreamTx` when paired with
the new `enrichEventsIO` helper) and the subscription delivery pipeline — has the
hook applied. A direct `appendToStream` call gets the trace context. A subscription
handler sees the decoded form.

User-visible proof of working behavior:

1. A new HSpec test in `kiroku-store/test/Test/InterpreterHooks.hs` (created by this
   plan) installs an `enrichEvent` hook that stamps a marker key
   `{"hook":"applied"}` onto `EventData.metadata`. It calls `appendToStream` once,
   reads the event back via `readStreamForward`, and asserts the marker is present.
2. A second test installs a `decodeHook` that injects a marker key
   `{"decoded":"yes"}` into `RecordedEvent.metadata`. It calls `readAllForward` and
   subscribes via `subscribe`, asserting that **both** read paths see the marker.
3. A third test asserts no behavioural change when both hooks are `Nothing`: the
   pre-existing test suite (`Test.appendToStream`, `Test.readStreamForward`,
   `Test.subscribe`, etc.) continues to pass byte-for-byte.

The constraint that the hook runs inside the interpreter, not at the SQL level, is
non-negotiable: the hook must see the typed `EventData` / `RecordedEvent` (with
`Data.Aeson.Value` payloads and `metadata`) so callers can branch on event type and
inspect/mutate structured JSON. Plumbing this at the encoder/decoder layer (the
`Hasql.Encoders.Params` / `Hasql.Decoders.Row` in `Kiroku.Store.SQL`) would force the
hook to operate on opaque bytes, defeating the use case.

Priority is **optional** per the requirement statement: `keiro`'s `runCommand` is the
first-class write path and already gets observability there. The hook is a
nice-to-have that closes the gap for users who call kiroku directly. It is sequenced
as Block 4 in the upstream master plan.


## Progress


Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

Milestone 1 — `StoreSettings` data type and plumbing through `ConnectionSettings`
and `KirokuStore`:

- [x] Create new module `Kiroku.Store.Settings` at
      `kiroku-store/src/Kiroku/Store/Settings.hs` exporting `StoreSettings(..)`,
      `defaultStoreSettings`, `enrichEvents`, and `decodeEvents`.
      (`enrichEvents` / `decodeEvents` are added now to keep the module
      cohesive; they are dead code until wired in M2/M3.) — 2026-05-14
- [x] Add `storeSettings :: !StoreSettings` field to
      `Kiroku.Store.Connection.ConnectionSettingsM m` and update
      `defaultConnectionSettings` to seed it with `defaultStoreSettings`. — 2026-05-14
- [x] Add `storeSettings :: !StoreSettings` field to `Kiroku.Store.Connection.KirokuStore`
      and copy it from settings in `withStore`'s acquire phase. — 2026-05-14
- [x] Re-export `Kiroku.Store.Settings` from `Kiroku.Store` (the package's umbrella
      module). — 2026-05-14
- [x] Add the new module to the `exposed-modules:` list in
      `kiroku-store/kiroku-store.cabal`. — 2026-05-14
- [x] Run `cabal build kiroku-store:lib:kiroku-store kiroku-store:test:kiroku-store-test
      kiroku-store:bench:kiroku-store-bench` and confirm the package compiles
      with no warnings beyond pre-existing. — 2026-05-14
- [x] Run `cabal test kiroku-store` and confirm the existing suite still
      passes. (Baseline is 114 examples — see Surprises & Discoveries.) — 2026-05-14

Milestone 2 — Append-side `enrichEvent` hook:

- [x] Add internal helper `enrichEvents :: StoreSettings -> [EventData] -> IO [EventData]`
      in `Kiroku.Store.Settings`. (Landed in M1 to keep the new module cohesive;
      no callers existed before this milestone wired them up.) — 2026-05-14
- [x] Wire `enrichEvents` into `runStorePool`'s `AppendToStream` interpreter branch
      at `kiroku-store/src/Kiroku/Store/Effect.hs`, calling it **before**
      `prepareEvents`. — 2026-05-14
- [x] Wire `enrichEvents` into the `AppendMultiStream` branch in the same
      interpreter, applying per-stream over the `[EventData]` lists inside the
      `mapM`. — 2026-05-14
- [x] Wire `enrichEvents` into the transactional path via new public wrappers
      `runTransactionAppendingResource` and `runTransactionAppendingResourceNoRetry`
      in `Kiroku.Store.Transaction`. The existing `runTransactionAppending` and
      `runTransactionAppendingNoRetry` remain as the no-hook fast path (documented
      to bypass `enrichEvent` and to require manual `enrichEventsIO` if hook
      coverage is wanted). — 2026-05-14
- [x] Add public convenience `enrichEventsIO :: KirokuStore -> [EventData] -> IO
      [EventData]` exported from `Kiroku.Store.Transaction` for direct callers of
      `appendToStreamTx`. — 2026-05-14
- [x] Add unit test `Test.InterpreterHooks.appendHookFires` (under the
      `InterpreterHooks > enrichEvent` describe block) exercising the marker
      pattern from the Purpose section. Wire `Test.InterpreterHooks` into
      `kiroku-store.cabal` (test-suite `other-modules`) and `test/Main.hs`. The
      milestone adds two `enrichEvent` examples — one for `appendToStream`, one
      for `appendMultiStream`. `cabal test kiroku-store` reports
      `116 examples, 0 failures`. — 2026-05-14

Milestone 3 — Read-side and subscription-side `decodeHook`:

- [x] Add internal helper
      `decodeEvents :: StoreSettings -> Vector RecordedEvent -> IO (Vector RecordedEvent)`
      in `Kiroku.Store.Settings`. (Landed in M1 alongside `enrichEvents` for the
      same module-cohesion reason.) — 2026-05-14
- [x] Wire `decodeEvents` into each read-shaped interpreter branch in
      `runStorePool`: `ReadStreamForward`, `ReadStreamBackward`, `ReadAllForward`,
      `ReadAllBackward`, `ReadCategoryForward`. Applied after `usePool` returns
      the vector and before the value is returned from the branch. — 2026-05-14
- [x] Apply `decodeEvents` inside the subscription `EventPublisher` at
      `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` so that
      live-mode events are transformed once, in the publisher, before being
      broadcast to all subscribers. `startPublisher` gained a `StoreSettings`
      parameter; `withStore` threads it from `ConnectionSettings.storeSettings`.
      — 2026-05-14
- [x] Apply `decodeEvents` inside the subscription `Worker`'s catch-up batch fetch
      at `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` so that catch-up
      events are transformed in the same way as live events. `runWorker` gained a
      `StoreSettings` parameter; `Kiroku.Store.Subscription.subscribe` reads it
      from `KirokuStore.storeSettings` and passes it through. — 2026-05-14
- [x] Add unit test `Test.InterpreterHooks.readHookFires` covering point 2 in the
      Purpose section: both `readAllForward` and a short-lived `subscribe`
      handler see the marker. Test exercises both catch-up (warm event appended
      before `subscribe`) and live (event appended after `subscribe`) phases. —
      2026-05-14

Milestone 4 — Documentation, no-op fast-path verification, and benchmark check:

- [ ] Add a Haddock module-level paragraph to `Kiroku.Store.Settings` describing
      `StoreSettings`'s semantics, when each hook fires, the typed value the hook
      sees, and that callers calling `appendToStreamTx` directly must use
      `enrichEventsIO` to opt in.
- [ ] Add an end-to-end usage example in `kiroku-store/README.md` (or
      `docs/HOOKS.md` if more natural) showing how to wire an OpenTelemetry
      trace-context injector.
- [ ] Add a regression test `Test.InterpreterHooks.noHookNoEffect` asserting that
      with `storeSettings = defaultStoreSettings`, the `RecordedEvent` produced
      from a round-trip is byte-identical to the input — proving the no-op
      shortcut introduces no `pure`-wrapping artefact.
- [ ] Run `cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--pattern
      append"` once before and once after the hook wiring, and record the deltas in
      Surprises & Discoveries. A regression of more than 2% on the no-hook path
      (the default) is a blocker; fix the no-op shortcut and re-measure.


## Surprises & Discoveries


Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The plan was authored against a 102-example baseline, but the current
  master is at 114 examples (the `readStreamForwardStream` suite landed
  recently). The "+3 tests → 105" acceptance arithmetic in *Validation and
  Acceptance* therefore translates to "+3 tests → 117 examples".
  Evidence: `cabal test kiroku-store` on master prints `114 examples, 0
  failures` (2026-05-14, pre-Milestone-1).
- `cabal build all` fails on master at unrelated targets (the
  `bench:kiroku-shibuya-overhead` and `test:shibuya-kiroku-adapter-test`
  packages have pre-existing breakage). The milestone-level build/test
  commands therefore target the `kiroku-store` library, test suite, and
  benchmark explicitly:
  `cabal build kiroku-store:lib:kiroku-store kiroku-store:test:kiroku-store-test kiroku-store:bench:kiroku-store-bench`
  and `cabal test kiroku-store`. (2026-05-14)


## Decision Log


Record every decision made while working on the plan.

- Decision: Place `StoreSettings` in its own module
  `Kiroku.Store.Settings` rather than extending `Kiroku.Store.Connection`.
  Rationale: `ConnectionSettings` is about pool/connection-level knobs (DSN, pool
  size, idle-in-transaction timeout). The new hooks are about per-event semantics
  applied by the interpreter and have nothing to do with the pool. Splitting them
  keeps the two concerns separately readable and lets future settings
  (encoder/decoder selection, payload-size limits, etc.) live alongside the hooks
  without bloating `Connection`.
  Date: 2026-05-14

- Decision: Hook fires inside the interpreter, before encoding on the append path
  and after decoding on the read path. Hooks operate on typed
  `EventData`/`RecordedEvent`, not on raw JSON bytes.
  Rationale: This is a stated design constraint of the request. A SQL-level hook
  could only operate on opaque bytes, defeating the encrypt/compress/inject-trace
  use case (which needs to inspect `eventType` to branch). The interpreter is the
  one place where the typed value passes through every code path uniformly.
  Date: 2026-05-14

- Decision: `enrichEvent` runs on `EventData` (before id assignment) rather than on
  `PreparedEvent` (after id assignment).
  Rationale: The user spec literally writes `enrichEvent :: Maybe (EventData ->
  IO EventData)`. The keiro use case (inject trace context into metadata) does not
  need to see the generated event id. Mutating an already-assigned id would also
  invite footguns. If a future hook genuinely needs the id, we can add a second
  hook on `PreparedEvent`.
  Date: 2026-05-14

- Decision: When the hook field is `Nothing`, skip the `IO` round-trip entirely
  (`pure events`) rather than going through `traverse pure`.
  Rationale: The hook is opt-in and most users will run with the defaults. We want
  the no-hook path to add zero allocations and zero `Vector.traverse` work so that
  the benchmark numbers are unchanged. The implementation pattern is `case
  enrichEvent ss of Nothing -> pure xs; Just f -> traverse f xs`.
  Date: 2026-05-14

- Decision: Apply `decodeHook` at the `EventPublisher` for live-mode subscriptions
  (one place, not per-subscriber) and separately at the `Worker`'s catch-up fetch
  (also one place per worker).
  Rationale: Applying it at the publisher means the cost is paid once per event,
  not once per subscriber. The publisher is the natural fan-out point and already
  decodes the rows once. The worker's catch-up fetch is a different code path
  (driven by direct SQL inside the worker thread, not the publisher), so it has to
  be wired separately. Applying at both yields uniform behaviour for catch-up and
  live events.
  Date: 2026-05-14

- Decision: Source `StoreSettings` inside `runTransactionAppending` via the
  surrounding `KirokuStoreResource`/`KirokuStore` rather than a new
  `GetStoreSettings :: Store m StoreSettings` effect constructor.
  Rationale: The `Store` effect is the *abstract* surface — adding a constructor
  that returns interpreter-specific configuration leaks the implementation. Mock
  interpreters of `Store` would have to invent values for it. The `Transaction`
  wrapper is already an `IOE :> es`-flavored composite that depends on `Store`;
  threading the store handle (or just the `StoreSettings`) explicitly through a
  reader argument keeps the abstract effect clean. Concretely: `runTransactionAppending`
  gains a thin shim that takes the settings (resolved by the caller via the
  `KirokuStoreResource` effect when available) and the existing function becomes
  the no-hook fast path. Detailed signature is in Interfaces and Dependencies.
  Date: 2026-05-14

- Decision: Place new tests under `kiroku-store/test/Test/InterpreterHooks.hs`
  next to the existing pattern of one suite per concern
  (`Test.Concurrency`, `Test.FailureInjection`, `Test.Properties`, `Test.Transaction`).
  Rationale: Matches the existing convention so a reader can find the hook tests
  by file name. Avoids polluting the giant `Main.hs` describe blocks.
  Date: 2026-05-14


## Outcomes & Retrospective


Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation


This plan touches the `kiroku-store` cabal package — the only package in this
repository today. Its source lives under
`kiroku-store/src/Kiroku/Store/` and its test suite under
`kiroku-store/test/`. The umbrella module is `Kiroku.Store` at
`kiroku-store/src/Kiroku/Store.hs`, which re-exports every public submodule.

The relevant data types to know:

- `EventData` — what callers hand to the store on append. Fields: optional
  `eventId :: Maybe EventId`, `eventType :: EventType`, `payload :: Aeson.Value`,
  optional `metadata :: Maybe Aeson.Value`, optional `causationId :: Maybe UUID`,
  optional `correlationId :: Maybe UUID`. Defined in
  `kiroku-store/src/Kiroku/Store/Types.hs`.
- `RecordedEvent` — what comes back from reads and subscriptions. Same payload
  shape as `EventData` plus position fields (`streamVersion`, `globalPosition`,
  `originalStreamId`, `originalVersion`, `createdAt`) and a guaranteed `eventId`.
  Same file.
- `Store` — the dynamic effectful surface, defined in
  `kiroku-store/src/Kiroku/Store/Effect.hs`. Constructors include
  `AppendToStream`, `AppendMultiStream`, `ReadStreamForward`/`Backward`,
  `ReadAllForward`/`Backward`, `ReadCategoryForward`, `GetStream`,
  `LinkToStream`, `SoftDeleteStream`, `HardDeleteStream`, `UndeleteStream`,
  `RunTransaction`, `RunTransactionNoRetry`.
- `runStorePool :: KirokuStore -> Eff (Store : es) a -> Eff es a` — the
  PostgreSQL interpreter for the `Store` effect. Same file. This is the single
  point where every constructor is dispatched against the connection pool. Hooks
  fire inside this function.
- `KirokuStore` — the runtime store handle. Fields: `pool` (the `Hasql.Pool`),
  `schema`, `notifier`, `publisher`, `eventHandler`. Defined in
  `kiroku-store/src/Kiroku/Store/Connection.hs`. This plan adds a `storeSettings`
  field here.
- `ConnectionSettingsM m` — the configuration the caller hands to `withStore`.
  Defined in the same file. This plan adds a `storeSettings` field here too.
- `Kiroku.Store.Transaction` — the transactional escape hatch (the
  `runTransaction` / `appendToStreamTx` / `runTransactionAppending` surface).
  Lives at `kiroku-store/src/Kiroku/Store/Transaction.hs`. This plan modifies
  `runTransactionAppending`'s pre-IO preparation step to apply the hook.

Subscription infrastructure (relevant to Milestone 3):

- `Kiroku.Store.Subscription.EventPublisher` at
  `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`. The publisher
  runs a SELECT against the pool whenever the notifier ticks, decodes a `Vector
  RecordedEvent`, and broadcasts to all subscribers via their `subQueue`.
- `Kiroku.Store.Subscription.Worker` at
  `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`. The worker thread for
  each subscription pulls live batches from its `subQueue`, but also runs its own
  catch-up SELECT in pre-live mode to backfill from the saved checkpoint to the
  publisher's `lastPublished` position.

SQL layer (do **not** modify in this plan — the constraint says the hook fires
inside the interpreter, not at the SQL level):

- `Kiroku.Store.SQL` at `kiroku-store/src/Kiroku/Store/SQL.hs` defines
  `recordedEventRow :: D.Row RecordedEvent` (the shared decoder used by every
  read statement) and `appendEncoder` (the shared encoder for append params).
  These stay untouched.

Test infrastructure:

- `kiroku-store/test/Test/Helpers.hs` exports `withTestStore` and
  `withTestStoreSettings`. The latter takes a `ConnectionSettings ->
  ConnectionSettings` transform, which is exactly what the new tests use to
  install hooks.
- `kiroku-store/test/Main.hs` wires per-concern test modules via `import
  qualified` and calls `<Module>.spec` from inside `hspec`. New file
  `kiroku-store/test/Test/InterpreterHooks.hs` follows the same convention; wire
  it through.

Term glossary:

- *Interpreter* — the function that turns a constructor of the dynamic `Store`
  effect into actual IO/SQL work. In this codebase, `runStorePool` is the
  PostgreSQL interpreter; `runStoreResource` and `runStoreIO` are thin wrappers
  around it.
- *Hook* — a user-supplied function `a -> IO a` that the interpreter calls on
  the typed value passing through it. Optional; default no-op.
- *Trace context* — OpenTelemetry vocabulary for the `trace_id` / `span_id`
  pair (and friends) that lets distributed-tracing tools correlate spans across
  process boundaries. Stored conventionally as JSON keys inside
  `EventData.metadata`.


## Plan of Work


This work is four milestones long. Milestone 1 establishes the type and plumbs it
through the existing setup machinery (no behaviour change). Milestone 2 wires the
append-side hook. Milestone 3 wires the read-side and subscription-side hook.
Milestone 4 is documentation, no-op verification, and a benchmark sanity check.

### Milestone 1: `StoreSettings` plumbing

Scope: introduce the new type and field, with everyone defaulting to no-op. No
hook is actually called yet in this milestone — the whole purpose is to thread a
piece of configuration from `ConnectionSettings` to `KirokuStore` without
disturbing anything.

End state: `kiroku-store` builds, the existing 102-example HSpec suite passes
unchanged. A user can write
`defaultConnectionSettings cs & #storeSettings .~ defaultStoreSettings { … }` —
but nothing observes the field yet.

Commands:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal build all
cabal test all
```

Acceptance: build clean, all tests pass.

Specific edits:

1. Create `kiroku-store/src/Kiroku/Store/Settings.hs`. Exports `StoreSettings(..)`
   and `defaultStoreSettings`. The record has two fields, both `Maybe`. See
   *Interfaces and Dependencies* below for the exact signature.
2. Edit `kiroku-store/src/Kiroku/Store/Connection.hs`. Add
   `storeSettings :: !StoreSettings` to `ConnectionSettingsM m` and to
   `KirokuStore`. Update `defaultConnectionSettings` to set it. Update
   `withStore`'s `acquire` block to thread the value into the constructed
   `KirokuStore`.
3. Edit `kiroku-store/src/Kiroku/Store.hs`. Add `module Kiroku.Store.Settings` to
   the re-export list.
4. Edit `kiroku-store/kiroku-store.cabal`. Add `Kiroku.Store.Settings` to the
   library's `exposed-modules:` list (keeping alphabetical order).

### Milestone 2: append-side hook

Scope: implement `enrichEvents`, wire it into the three append paths
(`AppendToStream`, `AppendMultiStream`, and the `Kiroku.Store.Transaction`
wrapper), and write a passing test that proves it fires.

End state: with a hook installed, appended events have whatever transformation
the hook applies. Without a hook, behaviour is identical to before.

Commands:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal build all
cabal test all
```

Acceptance: new test `Test.InterpreterHooks.appendHookFires` passes; all
pre-existing tests still pass.

Specific edits:

1. Add `enrichEvents :: StoreSettings -> [EventData] -> IO [EventData]` to
   `Kiroku.Store.Settings`. Implementation: pattern-match on
   `enrichEvent settings`; `Nothing -> pure xs`; `Just f -> traverse f xs`.
2. In `runStorePool` at `kiroku-store/src/Kiroku/Store/Effect.hs:97`, the
   `AppendToStream` branch currently does:

    ```haskell
    AppendToStream (StreamName name) expected events -> do
        rejectReservedApplicationStream name
        now <- liftIO getCurrentTime
        prepared <- prepareEvents events
        …
    ```

    Insert `events' <- liftIO $ enrichEvents (store ^. #storeSettings) events`
    between the reject and the `now <-`, then change `prepareEvents events` to
    `prepareEvents events'`. The `store` binding is the interpreter's
    `KirokuStore` (the argument to `runStorePool`).
3. In the `AppendMultiStream` branch (same file, around line 145), the per-stream
   `mapM` over `ops` currently does:

    ```haskell
    \(sn, ev, evts) -> do
        prepared <- prepareEvents evts
        pure (sn, ev, prepared)
    ```

    Insert `evts' <- liftIO $ enrichEvents (store ^. #storeSettings) evts`
    before `prepareEvents`, and pass `evts'` instead of `evts`.
4. In `kiroku-store/src/Kiroku/Store/Transaction.hs`, the
   `runTransactionAppendingWith` helper has:

    ```haskell
    | otherwise = do
        prepared <- prepareEventsIO events
        now <- liftIO getCurrentTime
        let body = …
    ```

    To run the hook here, `runTransactionAppendingWith` needs access to
    `StoreSettings`. There are two viable approaches; we take the *explicit
    parameter* approach to keep the abstract `Store` effect clean (see
    Decision Log entry): add an overload that takes
    `StoreSettings` explicitly, and have the public wrappers
    `runTransactionAppending` / `runTransactionAppendingNoRetry` resolve it via
    the surrounding `KirokuStoreResource` effect when present, or fall back to
    `defaultStoreSettings` when the caller is on a bare
    `runStorePool`-only stack.

    Concretely, add a new public wrapper:

    ```haskell
    runTransactionAppendingResource ::
        (HasCallStack, IOE :> es, KirokuStoreResource :> es, Store :> es) =>
        StreamName ->
        ExpectedVersion ->
        [EventData] ->
        (AppendResult -> Tx.Transaction a) ->
        Eff es (Either StoreError a)
    runTransactionAppendingResource sn expected events k = do
        store <- getKirokuStore
        events' <- liftIO $ enrichEvents (store ^. #storeSettings) events
        runTransactionAppendingWith RunTransaction sn expected events' k
    ```

    The existing `runTransactionAppending` (which lacks the resource effect)
    becomes the no-hook fast path and is documented to bypass `enrichEvent`. The
    new variant is the recommended path for callers running under a
    `KirokuStoreResource` (which is the standard pattern in this codebase — see
    `Kiroku.Store.Effect.Resource`).
5. Add a public convenience `enrichEventsIO :: KirokuStore -> [EventData] -> IO
   [EventData]` to `Kiroku.Store.Transaction` for callers who use the lower-level
   `appendToStreamTx` directly. Trivial wrapper around `enrichEvents`.
6. Create `kiroku-store/test/Test/InterpreterHooks.hs`. Use
   `withTestStoreSettings` to install a hook that injects a marker JSON object
   into `metadata`. Append, read back, assert the marker is present.
7. Edit `kiroku-store/test/Main.hs`: add `import qualified Test.InterpreterHooks
   as InterpreterHooks` and call `InterpreterHooks.spec` from `main`.
8. Edit `kiroku-store/kiroku-store.cabal`: add `Test.InterpreterHooks` to the
   test-suite's `other-modules:` list.

### Milestone 3: read-side and subscription-side hook

Scope: implement `decodeEvents`, wire it into every read constructor in
`runStorePool` and into the subscription pipeline.

End state: with a `decodeHook` installed, events surfaced through reads and
through subscriptions are transformed by the hook before the caller sees them.

Commands:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal build all
cabal test all
```

Acceptance: new test `Test.InterpreterHooks.readHookFires` passes (covers both
`readAllForward` and `subscribe`); pre-existing tests still pass.

Specific edits:

1. Add `decodeEvents :: StoreSettings -> Vector RecordedEvent -> IO (Vector
   RecordedEvent)` to `Kiroku.Store.Settings`. Same no-op shortcut as
   `enrichEvents`.
2. In `runStorePool`, wrap the existing return value of each read branch with
   the hook. Pattern, for example for `ReadStreamForward`:

    ```haskell
    ReadStreamForward (StreamName name) (StreamVersion startVer) limit -> do
        evs <- usePool (store ^. #pool) $
            Session.statement (name, startVer, limit) SQL.readStreamForwardStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    ```

    Repeat for `ReadStreamBackward`, `ReadAllForward`, `ReadAllBackward`,
    `ReadCategoryForward`.
3. In `Kiroku.Store.Subscription.EventPublisher`, locate the function that
   decodes a fresh batch from the catch-up SELECT (it pattern-matches on the
   `Right vec` branch of the pool call). Apply `decodeEvents` to that vector
   before forwarding to subscribers. The publisher already has access to the
   `KirokuStore` via its setup args, but it currently stores only the pool —
   plumb `StoreSettings` through `startPublisher` (already a private function)
   so the publisher loop can read the hook.
4. In `Kiroku.Store.Subscription.Worker`, locate the worker's catch-up SQL fetch
   (it uses statements similar to the read interpreter). Apply `decodeEvents`
   to the resulting vector. The worker is constructed by `subscribe` and
   already takes a `KirokuStore`, so `StoreSettings` is reachable.
5. Extend `Test.InterpreterHooks` with `readHookFires`. Append three events
   through a hook-less interpreter, then re-open the store with a `decodeHook`
   installed via `withTestStoreSettings`, and assert both `readAllForward` and
   a short-lived `subscribe` see the transformed values.

### Milestone 4: documentation, no-op verification, benchmark sanity

Scope: write user-facing docs, add the strict no-op test, and run a benchmark
diff.

End state: a future user can read the `Kiroku.Store.Settings` Haddock and the
end-to-end example and wire a hook in one sitting. The no-op test guards against
silent overhead regressions on the default path.

Commands:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal haddock kiroku-store --haddock-html
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--pattern append"
```

Acceptance: Haddock builds clean. Benchmark diff against the pre-Milestone-1
baseline (capture one in advance using `just bench-baseline`) is within ±2% on
the default no-hook path.

Specific edits:

1. Write the `Kiroku.Store.Settings` module-level Haddock.
2. Add an end-to-end example to `kiroku-store/README.md` (preferred to a new
   docs file — the README is short and welcoming new readers there is the
   higher-leverage move).
3. Add `Test.InterpreterHooks.noHookNoEffect`.
4. Run benchmarks before-and-after; if a regression appears, profile the no-op
   shortcut path (most likely cause: an accidental `traverse pure` instead of
   the `case`-based shortcut). Document the finding in Surprises & Discoveries.


## Concrete Steps


All commands assume `cwd =
/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

Initial build and test (to confirm the working tree is green before edits):

```bash
cabal build all
cabal test all
```

Expected last line for the test suite:

```text
Finished in N.NNN seconds
102 examples, 0 failures
```

(Number may differ; the important part is `0 failures`.)

Capture a benchmark baseline now (used in Milestone 4):

```bash
just bench-baseline
```

This writes `kiroku-store/bench/results/baseline.csv`. Do not commit it; the
checkpoint is for the duration of this plan only.

Then proceed milestone by milestone. After each milestone:

```bash
cabal build all
cabal test all
```

Both must succeed before moving on. Commit at every milestone boundary with a
message body that names the milestone and an `ExecPlan:` trailer:

```text
feat(store): plumb StoreSettings through ConnectionSettings and KirokuStore

Milestone 1 of the interpreter-level hook ExecPlan. Adds the
Kiroku.Store.Settings module and threads a no-op StoreSettings field
through ConnectionSettings into KirokuStore. No behaviour change yet.

ExecPlan: docs/plans/13-interpreter-level-event-data-hooks.md
Intention: intention_01krj7mxdne8rv49ync50x58tv
```

Milestone-4 benchmark check:

```bash
cabal bench kiroku-store:kiroku-store-bench \
    --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 2 --pattern append"
```

Acceptance: command exits 0. A non-zero exit indicates the no-op path regressed;
diagnose before merging.


## Validation and Acceptance


The work is complete when all of the following are true and demonstrable from a
fresh clone:

1. `cabal build all` succeeds with no new warnings.
2. `cabal test all` succeeds. The expected delta is `+3` tests
   (`appendHookFires`, `readHookFires`, `noHookNoEffect`) bringing the total to
   `105 examples, 0 failures`.
3. With both hooks `Nothing` (the default), every existing test passes
   unchanged. This is the regression test: the hook surface is fully opt-in.
4. The new `Test.InterpreterHooks.appendHookFires` test:

    ```haskell
    it "applies enrichEvent to appended events" $ do
        let inject ed = pure $ ed & #metadata .~ Just (Aeson.object [("hook", Aeson.String "applied")])
            tweak cs = cs & #storeSettings .~
                defaultStoreSettings { enrichEvent = Just inject }
        withTestStoreSettings tweak $ \store -> do
            _ <- runStoreIO store $ appendToStream
                (StreamName "hook-1") NoStream
                [makeEvent "X" (Aeson.object [])]
            evs <- runStoreIO store $ readStreamForward
                (StreamName "hook-1") (StreamVersion 0) 10
            case evs of
                Right v | V.length v == 1 ->
                    (V.head v ^. #metadata) `shouldBe`
                        Just (Aeson.object [("hook", Aeson.String "applied")])
                other -> expectationFailure (show other)
    ```

    runs and passes. (Sketch — adapt to the test module's actual imports.)
5. The new `Test.InterpreterHooks.readHookFires` test installs a `decodeHook`
   that injects a marker into `metadata` and asserts both `readAllForward` and a
   short-lived `subscribe` handler see the marker.
6. The Milestone-4 benchmark diff is within ±2% on the no-hook append path.

User-visible end-to-end demonstration (reproducible by a novice from this
plan alone):

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
just up                    # bring up postgres via process-compose
cabal test kiroku-store --test-options "--match \"InterpreterHooks\""
```

Expected output ends with:

```text
3 examples, 0 failures
```


## Idempotence and Recovery


All steps are additive and safe to re-run. The schema is unchanged by this
plan — no migration to roll back. The only mutable state introduced is in
`KirokuStore` (a non-IO record field), which is set at acquire and never
mutated thereafter.

If a milestone's tests fail, re-read the milestone's *Specific edits* section,
verify each step was applied (in particular that the `liftIO` is at the right
level — interpreter branches are `Eff es a` not `IO a`, so `enrichEvents` /
`decodeEvents` must be wrapped in `liftIO`), and re-run `cabal test all`.

If the benchmark in Milestone 4 regresses, the cause is almost certainly that
the `Nothing` branch of `enrichEvents` or `decodeEvents` is taking a `traverse
pure` path instead of a direct `pure xs`. Inspect the case-match — the no-op
shortcut must avoid any list/vector traversal.

If `KirokuStoreResource`-dispatching of the new `runTransactionAppendingResource`
doesn't resolve in some callers (e.g., a `runStoreIO`-only stack), fall back to
the existing `runTransactionAppending` and call `enrichEventsIO` explicitly.
This is documented in the Haddock for `runTransactionAppending`.


## Interfaces and Dependencies


No new libraries are required. All new code uses what `kiroku-store` already
depends on (`effectful-core`, `hasql`, `aeson`, `vector`, `text`,
`generic-lens`).

### New module: `Kiroku.Store.Settings`

```haskell
module Kiroku.Store.Settings (
    StoreSettings (..),
    defaultStoreSettings,
    enrichEvents,
    decodeEvents,
) where

import Data.Vector (Vector)
import qualified Data.Vector as V
import GHC.Generics (Generic)
import Kiroku.Store.Types (EventData, RecordedEvent)

-- | Interpreter-level hooks for cross-cutting concerns at the
-- event-data boundary. All fields default to 'Nothing' (no-op).
data StoreSettings = StoreSettings
    { enrichEvent :: !(Maybe (EventData -> IO EventData))
    , decodeHook :: !(Maybe (RecordedEvent -> IO RecordedEvent))
    }
    deriving stock (Generic)

defaultStoreSettings :: StoreSettings
defaultStoreSettings = StoreSettings { enrichEvent = Nothing, decodeHook = Nothing }

enrichEvents :: StoreSettings -> [EventData] -> IO [EventData]
enrichEvents ss xs = case enrichEvent ss of
    Nothing -> pure xs
    Just f -> traverse f xs

decodeEvents :: StoreSettings -> Vector RecordedEvent -> IO (Vector RecordedEvent)
decodeEvents ss xs = case decodeHook ss of
    Nothing -> pure xs
    Just f -> V.mapM f xs
```

### Changes to `Kiroku.Store.Connection`

Add field to `ConnectionSettingsM m`:

```haskell
, storeSettings :: !StoreSettings
```

Add field to `KirokuStore`:

```haskell
, storeSettings :: !StoreSettings
```

Update `defaultConnectionSettings` and `withStore`'s `acquire` block to thread
the value.

### Changes to `Kiroku.Store.Effect.runStorePool`

Reach into `store ^. #storeSettings` from every branch that touches events.
Append branches call `enrichEvents` before `prepareEvents`. Read branches call
`decodeEvents` on the resulting vector before returning.

### Changes to `Kiroku.Store.Transaction`

Add new wrapper:

```haskell
runTransactionAppendingResource ::
    (HasCallStack, IOE :> es, KirokuStoreResource :> es, Store :> es) =>
    StreamName -> ExpectedVersion -> [EventData] ->
    (AppendResult -> Tx.Transaction a) ->
    Eff es (Either StoreError a)

runTransactionAppendingResourceNoRetry ::
    (HasCallStack, IOE :> es, KirokuStoreResource :> es, Store :> es) =>
    StreamName -> ExpectedVersion -> [EventData] ->
    (AppendResult -> Tx.Transaction a) ->
    Eff es (Either StoreError a)

enrichEventsIO :: KirokuStore -> [EventData] -> IO [EventData]
```

The existing `runTransactionAppending` / `runTransactionAppendingNoRetry` remain,
documented as the no-hook fast path.

### Changes to `Kiroku.Store.Subscription.EventPublisher` and `Worker`

`startPublisher` gains a `StoreSettings` argument (or the call sites use the
field already on `KirokuStore` — depending on internal threading). Same for
`runWorker` / catch-up fetch. Both apply `decodeEvents` to decoded vectors
before forwarding events to subscribers / handlers.

### Re-exports from `Kiroku.Store`

```haskell
module Kiroku.Store.Settings,
```

added to the umbrella module so users get `StoreSettings(..)`,
`defaultStoreSettings`, `enrichEvents`, `decodeEvents` from
`import Kiroku.Store`.
