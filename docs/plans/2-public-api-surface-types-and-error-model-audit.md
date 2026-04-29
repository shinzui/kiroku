---
id: 2
slug: public-api-surface-types-and-error-model-audit
title: "Public API surface, types and error model audit"
kind: exec-plan
created_at: 2026-04-29T14:06:18Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
master_plan: "docs/masterplans/1-production-readiness-review-of-kiroku-store.md"
---

# Public API surface, types and error model audit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`kiroku-store` exposes a Haskell API that consuming services will write code against: the public types in `kiroku-store/src/Kiroku/Store/Types.hs`, the `Store` effect and its operations in `kiroku-store/src/Kiroku/Store/Effect.hs` and the four operation modules (`Append.hs`, `Read.hs`, `Link.hs`, `Lifecycle.hs`), the `StoreError` type and its constructors in `kiroku-store/src/Kiroku/Store/Error.hs`, and the connection bracket and effect-resource integration in `Connection.hs` and `Effect/Resource.hs`. Once consumers depend on this surface, every type rename, every error-constructor change, and every effect-shape adjustment becomes a breaking change that ripples through call sites.

After this plan, the package has a written audit of every public type, function signature, error constructor, and effect operation, classifying each as "stable", "needs-revision-before-prod", or "deferred-with-rationale". Every must-fix issue has landed: in particular, the multi-stream error attribution bug (`Effect.hs:179-184` maps every conflict to the *first* stream's name regardless of which one conflicted), the over-coarse `ConnectionError` catch-all (`Error.hs:25` and lines 41-65 collapse acquisition timeouts, session errors, statement errors, and arbitrary server errors into a single text-bag), the missing `withSubscription` bracket helper, and the missing or implicit lifecycle contract for the higher-order `Subscription` effect. Documentation gaps in Haddocks are filled.

A reader can verify the change by reading the new audit document, building the package with `-Wall -Werror -Wmissing-export-lists -Wmissing-deriving-strategies` (per `kiroku-store/kiroku-store.cabal`), running `cabal test kiroku-store`, and confirming that the `shibuya-kiroku-adapter` still compiles against the API.


## Progress

- [x] Milestone 1: Audit findings document (2026-04-29)
  - [x] Inventory the entire public surface (every export from `Kiroku.Store` and the modules it re-exports) — 34 findings F1–F34
  - [x] For each item, record purpose, contract (preconditions, postconditions, error cases), and severity classification
  - [x] Cross-check `shibuya-kiroku-adapter/src/` for actual usage patterns and identify ergonomics issues from real call sites — adapter findings folded into F25/F27 (subscription bridge) and F16 (`KirokuStore (..)` field access)
  - [x] Record findings inline in Surprises & Discoveries with file:line references
- [ ] Milestone 2: Land must-fix corrections
  - [ ] **F1** — fix the multi-stream error attribution bug in `Effect.hs:160-164`
  - [ ] **F25** — add a `withSubscription` bracket (and `Eff` equivalent), wire into `bracket`, regression-test that throwing inside the body cancels the worker
  - [ ] **F19** — refine `StoreError` with `PoolAcquisitionTimeout`, `ConnectionLost`, `UnexpectedServerError` constructors (additive; keep `ConnectionError` as catch-all)
  - [ ] **F20** — change `DuplicateEvent` to take `Maybe EventId` so the `UUID.nil` fallback is explicit
  - [ ] **F22** — add `deriving anyclass (Exception)` to `StoreError`
  - [ ] **F18** — re-export `SchemaInitError` from `Kiroku.Store` so consumers do not have to import `Kiroku.Store.Schema`
  - [ ] **F26** — add `defaultSubscriptionConfig`
  - [ ] **F30–F33 (D-series)** — Haddock additions for under-documented public symbols (types, effect wrappers, `withStore` lifecycle, subscription rationale)
  - [ ] **F12, F21, F23** — Haddock-only entries (linked-event semantics, constraint-name dependency, idempotent-retry guidance)
  - [ ] Confirm `cabal build kiroku-store kiroku-store-test` and `cabal build shibuya-kiroku-adapter` are both green; run `cabal test kiroku-store`
  - [ ] Update the MasterPlan's Exec-Plan Registry status and Progress section
  - [ ] Defer (record only): F2 (empty-list edges — should-fix downgraded to defer if M2 budget is tight; will be revisited if any consumer reports surprise), F3 (split `Store` GADT), F8 (`Ord EventId`), F9 (`AnyVersion` rename), F13 (`LinkResult.globalPosition`), F16 (`KirokuStore (..)`), F24 (`Error.hs` exports)


## Surprises & Discoveries

### EP-2 audit (2026-04-29) — public-API findings F1–F28

Severity scale: **must-fix** (lands in M2 before production), **should-fix**
(lands in M2 unless explicitly deferred), **defer** (recorded with rationale,
not landed), **cross-plan** (owned by another EP), **no-issue** (no change
recommended; recorded for completeness).

#### Effect-layer correctness

  * **F1 (must-fix). Multi-stream error attribution.**
    `kiroku-store/src/Kiroku/Store/Effect.hs:160-164` — on `Left usageErr` from
    the multi-stream transaction the interpreter unconditionally maps the error
    against the *first* stream's `(name, expected)`:

        Left usageErr -> case ops of
            ((StreamName firstName, firstExpected, _) : _) ->
                throwError (mapUsageError firstName firstExpected usageErr)

    User-visible symptom: a multi-stream call with
    `[("a", AnyVersion, ..), ("b", NoStream, ..)]` where `b` already exists
    raises a `23505` (`ix_streams_stream_name`) inside the transaction; the
    interpreter routes it through `mapUsageError "a" AnyVersion`, so the
    consumer observes `StreamAlreadyExists "a"` even though `a` was fine. Or,
    when the conflict is a generic unique-violation that falls through the
    constraint-name match, it surfaces as
    `WrongExpectedVersion (StreamName "a") AnyVersion (StreamVersion 0)` — the
    wrong stream, the wrong expected version, *and* the wrong actual version.
    Severity: **must-fix**. Fix proposal in M2 description below.

  * **F2 (should-fix). Empty-list edge cases are unspecified.**
    `appendToStream name expected []`, `appendMultiStream []`, and
    `linkToStream name []` have no documented semantics. Reading the
    interpreter: `appendToStream name expected []` builds an empty-vector
    `AppendParams`, the CTE matches 0 rows, and the empty-result fallback
    (`emptyResultError`) maps to `WrongExpectedVersion (StreamVersion 0)` for
    `ExactVersion`, `StreamNotFound` for `StreamExists`, `StreamAlreadyExists`
    for `NoStream`, and `StreamNotFound` for `AnyVersion`. None of these
    represents the caller's intent ("no events to append"). Severity:
    **should-fix** — either reject empty lists at the wrapper layer with a
    structured error or document the semantics on each function's Haddock and
    the `Store` GADT constructors.

  * **F3 (defer). `Store` GADT has 12 constructors — projection-only consumers cannot constrain the effect.**
    `Effect.hs:46-58` mixes append/read/lifecycle/link in a single effect. A
    projection that only reads still gets the full `Store :> es` constraint
    (so it could `HardDeleteStream` if it wanted). Splitting into
    `Store` + `StoreLifecycle` (or introducing a read-only `StoreReader` that
    is a subset projected from `Store`) would tighten the constraint. Severity:
    **defer-with-rationale** — additive split is possible later without
    breaking; not worth the v0.1 churn before any consumer requests it.

  * **F4 (no-issue). Effect-resource interaction.**
    `Effect/Resource.hs` — `KirokuStoreResource` is a static effect with
    `Static WithSideEffects`; the choice is correct (the handle is acquired
    once via `withStore`, must not be mocked, and `Static` matches that
    lifecycle). The dynamic `runStorePool` and the static `runStoreResource`
    coexist cleanly. Worth a short Haddock note (folded into D-series below)
    explaining the choice. Severity: **no-issue**.

  * **F5 (no-issue). `prepareEvents` UUIDv7 generation lives in the interpreter.**
    `Effect.hs:245-265` — moved from `Append.hs` per a comment at the top of
    the helper section. Internal helper, not exported. No issue.

  * **F6 (cross-plan, EP-1 already addressed). Multi-stream pre-lock pass.**
    `Effect.hs:130-135` already includes the deterministic `SELECT ... FOR
    UPDATE` pre-pass that EP-1 F4 mandated. Confirmed in the working tree.
    No EP-2 work required.

  * **F7 (no-issue). `runStoreIO` is a beginner-level convenience.**
    `Effect.hs:196-200` specializes to `'[Store, Error StoreError, IOE]`.
    Common pattern; no issue.

#### Type-design

  * **F8 (defer). `Ord EventId` orders by UUID byte order, not generation time.**
    `Types.hs:32-33`. Even with UUIDv7 the byte layout is timestamp-dominant
    only in the high bytes; two UUIDs generated within the same millisecond
    can reverse order. Consumers who put `EventId` into a `Map` or `Set` and
    expect time order will be surprised. Severity: **defer-with-rationale** —
    keep `Ord EventId` for `Set`/`Map` correctness but add a Haddock warning
    that it is not a temporal order, and direct readers to
    `RecordedEvent.globalPosition` for time-ordering.

  * **F9 (defer). `ExpectedVersion.AnyVersion` naming.**
    `Types.hs:53-54`. The Haddock comment "Create or append, don't care" is
    accurate; the rename to `CreateOrAppend` would be a breaking change with
    minor ergonomic payoff. Severity: **defer-with-rationale** — keep the
    name, refine the Haddock so the upsert semantics are obvious without
    reading SQL.

  * **F10 (no-issue). `EventData` and `RecordedEvent` field overlap.**
    Both records use `eventId`, `eventType`, `payload`, `metadata`,
    `causationId`, `correlationId` (`Types.hs:58-98`). The cabal `common`
    stanza enables `DuplicateRecordFields` + `OverloadedLabels`, and every
    use site (`test/Main.hs`, `shibuya-kiroku-adapter/src/.../Convert.hs`)
    accesses fields via `^. #eventId`-style labels via
    `Data.Generics.Labels ()`. No ambiguity in practice. Severity: **no-issue**.

  * **F11 (no-issue). `StreamInfo.id` shadows `Prelude.id`.**
    `Types.hs:73`. With `OverloadedLabels` the `^. #id` accessor resolves to
    the field; `Prelude.id` is still available qualified or via
    `Data.Function.id`. Worth a one-line Haddock note (folded into D-series).

  * **F12 (should-fix-haddock). `RecordedEvent.streamVersion` vs `originalVersion`.**
    `Types.hs:82-97`. For events read from a stream the source event was
    appended to, `streamVersion == originalVersion`. For events read from a
    target stream that *links* the event, `streamVersion` is the target's
    version and `originalVersion` is the source's. The two adjacent comments
    (lines 86 and 91) describe the fields separately; a combined paragraph
    would help newcomers reason about linked-event reads. Severity:
    **should-fix-haddock**.

  * **F13 (defer). `LinkResult` lacks a global position.**
    `Types.hs:108-113`. Linking an existing event into a target stream does
    not advance `$all` (the event row already exists with a `global_position`
    assigned at original-append time); the `LinkResult` has no obvious
    `globalPosition` to report. A consumer that wants "subscribe-from-after-link"
    must follow up with a `readStreamForward` call on the target. Severity:
    **defer-with-rationale** — there is no semantically-correct global
    position for a `LinkResult`; the missing field is a feature, not a bug.

#### Connection settings

  * **F14 (cross-plan, EP-4). `ConnectionSettings.schema` is dead for SQL but live for LISTEN.**
    `Connection.hs:34-35` documents the field as "Schema name for multi-tenant
    isolation". In practice the schema is only used by the Notifier
    (`Notification.hs:45` constructs the LISTEN channel name from it); every
    SQL statement in `SQL.hs` references unqualified table names. Multi-tenant
    isolation is impossible. Severity: **cross-plan, EP-4** — EP-4 owns the
    decision to either wire the schema through SQL or remove the field.

  * **F15 (cross-plan, EP-5). No `statement_timeout` in `defaultConnectionSettings`.**
    `Connection.hs:47-79` sets `idle_in_transaction_session_timeout` via the
    pool's init session but does not set `statement_timeout`. A runaway query
    on a worker thread can hold a pool slot indefinitely. Severity:
    **cross-plan, EP-5** — operational tuning belongs to EP-5.

  * **F16 (defer). `KirokuStore (..)` exposes the data constructor.**
    `Connection.hs:1-7`. The `Store.hs` re-export uses `KirokuStore (..)` (it
    re-exports the whole module), so consumers can pattern-match on
    `pool`, `schema`, `notifier`, `publisher`. The adapter uses `^. #pool`
    nowhere, but `subscriptionStream`/`subscribe` poke `^. #pool`,
    `^. #schema`, `^. #publisher`, `^. #notifier` directly. Hiding the
    constructor would force callers to use accessor functions; a deliberate
    escape hatch is fine for v0.1 but worth documenting. Severity:
    **defer-with-rationale** — keep the open constructor for now, add a
    Haddock note acknowledging the stability cost.

  * **F17 (no-issue). `withStore` uses `MonadUnliftIO`.**
    `Connection.hs:67`. Standard choice, matches `bracket`. Add a short
    Haddock noting the rationale.

  * **F18 (should-fix). `SchemaInitError` is in an exposed module not re-exported from `Kiroku.Store`.**
    `kiroku-store.cabal` lists `Kiroku.Store.Schema` and `Kiroku.Store.Notification`
    as `exposed-modules`, but `Kiroku.Store` does not re-export them. A
    consumer who wants to catch `SchemaInitError` (thrown via
    `throwIO` from `initializeSchema`, propagating out of `withStore`) must
    `import Kiroku.Store.Schema` directly. Either re-export
    `SchemaInitError` from `Kiroku.Store.Connection` (or top-level
    `Kiroku.Store`) or move the modules to `other-modules`. Severity:
    **should-fix**.

#### Error model

  * **F19 (should-fix). `ConnectionError` collapses four failure modes.**
    `Error.hs:23-25`, `Error.hs:38-65`. Pool acquisition timeout, connection
    errors, statement-error fallthrough, and server errors with codes other
    than `23505`/`23503` all map to `ConnectionError !Text`. Consumers
    cannot programmatically choose between retry, escalate, and fail-fast.
    Proposal (additive): introduce
    `PoolAcquisitionTimeout`, `ConnectionLost !Text`,
    `UnexpectedServerError !Text !Text` (code, message) constructors;
    keep `ConnectionError !Text` as the catch-all so existing
    pattern-matches do not break (they fall through to the catch-all).
    Severity: **should-fix**.

  * **F20 (should-fix). `extractEventId` falls back to `EventId UUID.nil`.**
    `Error.hs:87-92`. When the PostgreSQL detail string fails to parse, we
    fabricate a `UUID.nil`-valued `EventId`, which a consumer cannot
    distinguish from a real "all-zeroes" UUID (vanishingly unlikely in
    practice but not impossible if someone hand-crafts an event id).
    Proposal: change the constructor to `DuplicateEvent !(Maybe EventId)`
    where `Nothing` means "we know there's a duplicate but couldn't recover
    the id from the server detail." This is a breaking change but mechanical
    for callers. Severity: **should-fix**.

  * **F21 (should-fix-haddock). `mapUniqueViolation` depends on stable PostgreSQL constraint names.**
    `Error.hs:75-92` matches on the literal strings `"events_pkey"` and
    `"ix_streams_stream_name"`. If a future schema migration renames a
    constraint, the mapping silently falls through to "generic unique
    violation → `WrongExpectedVersion (StreamVersion 0)`," which is
    wrong. Severity: **should-fix-haddock** — document the dependency in
    `Error.hs`, and add a comment in `kiroku-store/sql/schema.sql` near each
    constraint warning that the name is load-bearing. (Cross-plan with
    EP-1's owner of `schema.sql`.)

  * **F22 (should-fix). `StoreError` does not derive `Exception`.**
    `Error.hs:18-25`. Compare to `SchemaInitError` (`Schema.hs:19-21`) which
    does. Consumers cannot `throwIO` a `StoreError` directly; they have to
    wrap it. Adding `deriving anyclass (Exception)` is purely additive.
    Severity: **should-fix**.

  * **F23 (cross-plan, F11 from EP-1). `WrongExpectedVersion` is returned on a successful retry.**
    Mirrored from MasterPlan: `ExactVersion` retry of an already-succeeded
    append (caller-supplied `event_id`, network blip on the first attempt)
    produces `WrongExpectedVersion`, not `DuplicateEvent`. EP-2 decision: do
    *not* introduce a new constructor. Document on `appendToStream`'s
    Haddock that `WrongExpectedVersion` after a transient failure means
    *either* a real concurrent writer raced *or* your previous attempt
    succeeded; the recovery is the same in both cases (re-read and decide).
    Severity: **should-fix-haddock**.

  * **F24 (defer). `mapUsageError` and `emptyResultError` are exported.**
    `Error.hs:1-6`. The module comment says "Internal helpers used by Effect
    module." They are exported because the interpreter in `Effect.hs` lives
    in a different module. A future cleanup could move them to a
    `Kiroku.Store.Error.Internal` module so consumers cannot accidentally
    depend on them. Severity: **defer**.

#### Subscription API

  * **F25 (must-fix). `withSubscription` bracket is missing.**
    `Subscription.hs:28-39` returns a `SubscriptionHandle` with
    `cancel`/`wait`. The implicit contract — "must cancel before scope exits"
    — is documented in a Haddock note on `Subscription/Effect.hs:43-47` but
    no bracket helper exists. Forgetting to cancel leaks the worker thread
    and (for the `Eff` variant) leaves an `Eff` environment alive past its
    scope. Severity: **must-fix-before-production**.

    Proposal: add `withSubscription :: KirokuStore -> SubscriptionConfig -> (SubscriptionHandle -> IO a) -> IO a` to
    `Kiroku.Store.Subscription` (and an `Eff`-based equivalent in
    `Subscription.Effect`) that wires `cancel`/`waitCatch` into a `bracket`.
    Re-export both from `Kiroku.Store`. Land a regression test that throws
    inside the body and asserts the worker thread exits.

  * **F26 (should-fix). `SubscriptionConfig` lacks a smart constructor / default.**
    `Subscription/Types.hs:45-51`. Every test in `test/Main.hs` writes
    `batchSize = 100` literally; the adapter passes it from its own config.
    Add `defaultSubscriptionConfig :: SubscriptionName -> SubscriptionTarget -> EventHandler -> SubscriptionConfig` with
    `batchSize = 100`. Severity: **should-fix**.

  * **F27 (cross-plan, EP-3). `subscriptionStream` discards `wait`.**
    `Subscription/Stream.hs:33-67`. The bridge returns
    `(Stream IO RecordedEvent, IO ())` — the cancel action — but no way to
    observe a worker-thread crash. If the underlying `SubscriptionHandle`'s
    worker dies, the Streamly stream hangs on an empty queue. The adapter
    inherits this. Severity: **cross-plan, EP-3** — EP-3 owns subscription
    robustness, so the fix (returning a `wait`-style observer or wiring the
    worker's `Either SomeException ()` into the stream's termination) lives
    there.

  * **F28 (no-issue). `Subscribe` constructor exposed via `Subscription (..)` re-export.**
    `Subscription/Effect.hs:3-13` re-exports the GADT with `(..)` so
    `Subscribe` is visible to direct importers; `Kiroku.Store` re-exports
    only `Subscription` without `(..)`, hiding the constructor. Slight
    asymmetry but harmless: the only thing a consumer can do with the
    constructor is call `send (Subscribe cfg)`, which the convenience
    wrapper already does. Severity: **no-issue**.

  * **F29 (no-issue). `ConcUnlift Persistent (Limited 1)` is correct for the higher-order Subscription effect.**
    `Subscription/Effect.hs:67-71`. `Persistent` keeps the effect environment
    alive across handler invocations from the worker thread (which calls the
    handler many times); `Limited 1` because the worker is single-threaded.
    Add a Haddock note explaining this so future readers do not relax the
    bounds. Severity: **no-issue** (documentation gap covered by D-series).

#### Documentation gaps (D-series, all should-fix-haddock)

  * **F30 (should-fix-haddock). Public types lack one-paragraph contracts.**
    `StreamName`, `StreamId`, `EventId`, `EventType`, `StreamVersion`,
    `GlobalPosition`, `ExpectedVersion` (each constructor),
    `EventData` (each field), `RecordedEvent` (each field), `StreamInfo`
    (each field), `AppendResult`, `LinkResult`, `CategoryName` —
    `Types.hs` has Haddocks on the records but not on the four
    `ExpectedVersion` constructors, and the newtypes have no Haddock at all.
    Adding a one-line Haddock per public symbol is mechanical and high-value.

  * **F31 (should-fix-haddock). Effect-wrapper Haddocks are one-line.**
    `Append.hs`, `Lifecycle.hs`, `Link.hs`, `Read.hs` each carry a single
    `-- |` line per function. Add per-function paragraphs documenting:
    preconditions (e.g., `linkToStream` requires the source events to exist
    and not be hard-deleted), postconditions (e.g., `appendToStream` events
    are visible to subsequent reads in the same connection — read-your-own-
    writes), and error cases. Use `kiroku-store/test/Main.hs` as the
    primary source of truth for the contract.

  * **F32 (should-fix-haddock). `withStore` lifecycle is undocumented.**
    `Connection.hs:67-102`. Document the acquire order (pool → schema init →
    Notifier → Publisher) and release order (Publisher → Notifier → pool),
    the schema-initialisation idempotency, and the exception types a caller
    may have to catch (`SchemaInitError` from schema init).

  * **F33 (should-fix-haddock). Subscription effects lack a "why static + dynamic" note.**
    `Effect/Resource.hs` (static) and `Effect.hs` (dynamic) coexist; the
    rationale (static for the resource handle, dynamic for the operations
    so consumers can mock) belongs in module-level Haddocks.

#### Cabal / build-flag note

  * **F34 (no-issue, but the EP-2 plan body is inaccurate).**
    `kiroku-store/kiroku-store.cabal` does not enable `-Wall -Werror
    -Wmissing-export-lists -Wmissing-deriving-strategies` in the `common
    common` stanza. The EP-2 plan body says verification builds with those
    flags; the build actually succeeds without them being on. Adding them
    would surface real issues (e.g., the `ConnectionError` catch-all may
    leave incomplete-pattern warnings if F19's additive constructors are
    landed). Severity: **no-issue here** — flagged for **EP-5**'s
    operational hardening since the right place to enable production warning
    flags is alongside CI configuration.

### Summary by severity

  * **Must-fix (3):** F1 (multi-stream attribution), F25 (`withSubscription`
    bracket).
  * **Should-fix (10):** F2 (empty-list edges), F12 (linked-event Haddock),
    F18 (`SchemaInitError` re-export), F19 (`ConnectionError` refinement),
    F20 (`extractEventId` nil fallback), F21 (constraint-name dependency
    Haddock), F22 (`StoreError` derives `Exception`), F23 (idempotent-retry
    Haddock), F26 (`defaultSubscriptionConfig`), and the D-series F30–F33
    (Haddock additions, treated collectively as one should-fix bundle).
  * **Defer-with-rationale (7):** F3, F8, F9, F13, F16, F24, plus
    F11/F17/F28/F29 (no-issue, but a Haddock-only follow-up bundled into
    the D-series).
  * **Cross-plan (4):** F6 (already done by EP-1), F14 (EP-4), F15 (EP-5),
    F23/F11 (already mirrored from EP-1's audit), F27 (EP-3).
  * **No-issue (5):** F4, F5, F7, F10, F11, F28, F29, F34.

### Cross-plan items mirrored to MasterPlan

The MasterPlan's Surprises & Discoveries section is updated with a
"EP-2 audit (2026-04-29)" subsection capturing F14 (→ EP-4), F15 (→ EP-5),
F18 (touches the cabal file's exposed-modules list — coordinate with EP-4
schema work), F25 (touches `Subscription.hs` shared with EP-3), and F27
(→ EP-3).


## Decision Log

- Decision: Treat `shibuya-kiroku-adapter` as a real-world consumer reference for ergonomics findings; do not modify it as part of this plan, but read it to confirm or refute usage assumptions.
  Rationale: The MasterPlan scopes the adapter as out-of-scope as a target. Reading it is the cheapest way to validate that the API works for its intended audience.
  Date: 2026-04-29

- Decision: For the multi-stream error attribution fix (F1), parse the PostgreSQL `ServerError` detail string to recover the actual offending stream when the conflict is a `23505` unique violation on `ix_streams_stream_name`; fall back to the existing first-stream behaviour with a documented "(unknown stream within multi-stream)" caveat for any other usage error.
  Rationale: The transaction interface returns a single `Either UsageError result` — there is no per-statement attribution at the hasql layer without restructuring the transaction. Parsing the `Key (stream_name)=(value)` detail recovers the stream for the most common conflict (a concurrent `NoStream` on an existing stream); other conflicts are rare enough that the imprecise mapping is acceptable for v0.1 and easy to refine later. The alternative (rebuild the multi-stream interpreter to thread per-statement try/catch) is a structural refactor that EP-2's M2 budget cannot absorb without delaying every other must-fix.
  Date: 2026-04-29

- Decision: Refine `StoreError` additively (add `PoolAcquisitionTimeout`, `ConnectionLost`, `UnexpectedServerError` constructors) and keep `ConnectionError !Text` as a catch-all so existing exhaustive pattern matches keep compiling. Pattern matches that explicitly enumerate cases will get incomplete-pattern warnings under `-Wall`, which is the desired signal.
  Rationale: The shibuya-kiroku-adapter does not pattern-match on `StoreError` at all (it forwards via the IO subscribe path); the test suite matches on specific constructors but always includes a fallback `other ->` arm. Additive constructors are the safe path. A future major-version bump can collapse `ConnectionError` if the additive constructors prove sufficient.
  Date: 2026-04-29

- Decision: Make `DuplicateEvent` take `Maybe EventId` (breaking change) rather than continuing to fabricate `UUID.nil`.
  Rationale: A consumer cannot distinguish a real all-zeroes event id from the fabricated one. The breakage is mechanical: every pattern match `DuplicateEvent eid -> ...` becomes `DuplicateEvent (Just eid) -> ...` plus a `Nothing` branch. The test suite has exactly one matcher (`Left (DuplicateEvent _)`) which is unaffected.
  Date: 2026-04-29

- Decision: Keep the `Store` GADT a single 12-constructor effect for v0.1 (defer F3).
  Rationale: Splitting into `Store` + `StoreLifecycle` is a structural change that benefits projection-only consumers. None exist yet (the in-tree consumer is the adapter, which uses the IO `subscribe` path and not the `Store` effect at all). An additive split via a `StoreReader` projection can land in a later release without breaking; doing it now is speculative scope.
  Date: 2026-04-29

- Decision: Defer F2 (empty-list edge cases) to a documentation-only Haddock note rather than introducing a structured rejection.
  Rationale: The current behaviour is well-defined (the SQL CTE returns 0 rows; `emptyResultError` maps to a constructor that depends on `ExpectedVersion`); it is just non-obvious. A consumer who calls `appendToStream _ _ []` is making a programming mistake, not exercising a contract. A Haddock warning is the right level of intervention for v0.1.
  Date: 2026-04-29

- Decision: Defer F8 (`Ord EventId` time-ordering surprise), F9 (`AnyVersion` rename), F13 (`LinkResult.globalPosition`), F16 (`KirokuStore (..)` open data constructor) with rationale recorded inline above. None of these is reachable from a hot path or production-blocking; all are renames or additions that are easier to land later than to undo now.
  Date: 2026-04-29


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The reader is assumed to have only the working tree and this file. All necessary context is repeated below.

`kiroku-store` is a Haskell event-store library backed by PostgreSQL 18. Its public surface is re-exported from `Kiroku.Store` (`kiroku-store/src/Kiroku/Store.hs`), which re-exports the following modules:

- `Kiroku.Store.Types` — domain types: `StreamName`, `StreamId`, `EventId`, `EventType`, `StreamVersion`, `GlobalPosition`, `ExpectedVersion`, `EventData`, `RecordedEvent`, `StreamInfo`, `AppendResult`, `LinkResult`, `CategoryName`. All are newtype wrappers or records with `deriving stock (Eq, Show, Generic)`.
- `Kiroku.Store.Connection` — `KirokuStore`, `ConnectionSettings`, `defaultConnectionSettings`, `withStore`. The store handle holds a `Pool`, a schema name, a `Notifier`, and an `EventPublisher`.
- `Kiroku.Store.Effect` — the `Store :: Effect` GADT (12 operations) plus three interpreters: `runStorePool`, `runStoreResource`, `runStoreIO`.
- `Kiroku.Store.Effect.Resource` — `KirokuStoreResource` static effect plus `withKirokuStore`.
- `Kiroku.Store.Error` — `StoreError` with constructors `WrongExpectedVersion`, `StreamNotFound`, `StreamAlreadyExists`, `DuplicateEvent`, `ConnectionError`. Helper functions `mapUsageError` and `emptyResultError` are exported for the interpreter.
- `Kiroku.Store.Append` — `appendToStream`, `appendMultiStream`.
- `Kiroku.Store.Lifecycle` — `softDeleteStream`, `hardDeleteStream`, `undeleteStream`.
- `Kiroku.Store.Link` — `linkToStream`.
- `Kiroku.Store.Read` — `readStreamForward`, `readStreamBackward`, `readAllForward`, `readAllBackward`, `readCategory`, `getStream`.
- `Kiroku.Store.Subscription` — `subscribe` (the IO-based variant) plus `module Kiroku.Store.Subscription.Types`.
- Plus a select set of `hasql-pool` `Observation` types re-exported for the observation-handler API: `Observation`, `ConnectionStatus`, `ConnectionReadyForUseReason`, `ConnectionTerminationReason`.
- `Kiroku.Store.Subscription.Effect` is *not* re-exported from `Kiroku.Store` (a Haddock note on `Store.hs` lines 5-9 explains why: it would clash with `Kiroku.Store.Subscription.subscribe`). The adapter and the test suite import it explicitly.

The `Store` effect uses `effectful`'s dynamic dispatch (`type instance DispatchOf Store = Dynamic`). The 12 constructors are: `AppendToStream`, `AppendMultiStream`, `LinkToStream`, `ReadStreamForward`, `ReadStreamBackward`, `ReadAllForward`, `ReadAllBackward`, `ReadCategoryForward`, `GetStream`, `SoftDeleteStream`, `HardDeleteStream`, `UndeleteStream`. The `Subscription` effect is higher-order: it carries `SubscriptionConfigM (Eff es)`, and its interpreter uses `localUnliftIO env (ConcUnlift Persistent (Limited 1))` to convert the caller's `Eff` handler to `IO` for the subscription worker thread.

Dependencies declared in `kiroku-store.cabal`: `aeson >= 2.1`, `async >= 2.2`, `base >= 4.18 && < 5`, `bytestring`, `effectful-core >= 2.4`, `file-embed`, `generic-lens >= 2.2`, `hasql >= 1.10`, `hasql-notifications >= 0.2`, `hasql-pool >= 1.2`, `hasql-transaction >= 1.1`, `lens >= 5.2`, `mmzk-typeid >= 0.6`, `stm`, `streamly-core >= 0.3`, `text >= 2.0`, `time >= 1.12`, `unliftio-core >= 0.2`, `uuid >= 1.3`, `vector >= 0.13`.

The package uses `GHC2024` defaults, with `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` enabled. Field accessors are accessed via `Data.Generics.Labels` (see `import Data.Generics.Labels ()` and the `^. #fieldName` idiom throughout).

`shibuya-kiroku-adapter` is the only in-tree consumer. Its sources are at `shibuya-kiroku-adapter/src/`. It implements an adapter layer for the `shibuya` framework. Read it to validate ergonomics findings, but do not modify it as part of this plan.

The test suite at `kiroku-store/test/Main.hs` (887 lines) exercises every public function and demonstrates the intended usage patterns via hspec specs. It is the second-best documentation source after Haddocks.


## Plan of Work

### Milestone 1 — Audit findings document

Goal: produce a written audit of the entire public surface, classifying every export and every contract by severity.

What will exist at the end: a complete pass through every module re-exported by `Kiroku.Store`, plus the explicitly-imported `Kiroku.Store.Subscription.Effect`. For each public symbol, the audit records: (1) signature; (2) intended contract (preconditions, postconditions, error cases); (3) actual behaviour as measured by reading the implementation; (4) severity if discrepancy exists. The output is structured as a list of findings in the Surprises & Discoveries section.

Verification: every export from every re-exported module appears in at least one finding (even if the finding is "no issue identified"). Confirmation that the audit is complete is done by listing exports with `cabal repl kiroku-store` followed by `:browse Kiroku.Store` and walking the output.

### Milestone 2 — Land must-fix corrections

Goal: land code changes for every must-fix finding, with regression tests where applicable. Document deferred decisions in the Decision Log.

Specific fixes that this milestone is expected to address (subject to confirmation in Milestone 1):

- Multi-stream error attribution: in `kiroku-store/src/Kiroku/Store/Effect.hs`, modify the `AppendMultiStream` arm so that on a `Left usageErr` the error is reported against the stream the planner attributes the error to, not always the first stream. One approach: run each per-stream `Tx.statement` with its own try/catch within the transaction (using `hasql-transaction`'s combinator API) and collect a `(StreamName, ExpectedVersion, UsageError)` for the first failure. A simpler approach: keep the current behaviour but document that on multi-stream conflicts the reported stream is the *first* in the input list and the actual offender requires inspection of the database; reject this approach unless the effort to fix is too high.
- `StoreError` refinement: coordinate with EP-1 on whether new constructors are needed for SQL-layer distinctions. Likely additions: `PoolAcquisitionTimeout` (currently mapped to `ConnectionError "Connection pool acquisition timeout"`), `TransientDatabaseError !Text` (for connection drops, distinct from logic errors), `UnknownServerError !Text !Text` (preserving code and message). Care: every existing `case ... of` that matches `ConnectionError` becomes incomplete.
- `withSubscription` bracket: add `withSubscription :: KirokuStore -> SubscriptionConfig -> (SubscriptionHandle -> IO a) -> IO a` (and an `Eff`-based equivalent in `Subscription.Effect`) that wires `cancel` and `wait` into a `bracket`. Document the existing implicit contract on `Subscription.Effect.subscribe` clearly. Update the test suite to use the bracket where appropriate.
- Haddocks: any public symbol the audit flags as under-documented gets a Haddock string with a one-paragraph contract description plus an example.

What will exist at the end: a green build with `-Wall -Werror`, a green test suite, an updated `shibuya-kiroku-adapter` if any breaking change requires it, and updated Haddocks. The Decision Log enumerates every fix landed and every should-fix item formally deferred.

Verification: `cabal build kiroku-store kiroku-store-test`, `cabal test kiroku-store`, and `cabal build shibuya-kiroku-adapter` all succeed.


## Concrete Steps

### Milestone 1 commands

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    cabal build kiroku-store
    cabal repl kiroku-store
    # In ghci:
    :browse Kiroku.Store
    :browse Kiroku.Store.Subscription.Effect
    :browse Kiroku.Store.Effect.Resource

Walk the output. For each export, note in Surprises & Discoveries: signature, contract, severity, and any specific concern. For symbols whose contract is not obvious from the type signature, read the implementation and the test suite usage to infer it.

Files to read in full:

- `kiroku-store/src/Kiroku/Store.hs` (46 lines) — re-export structure
- `kiroku-store/src/Kiroku/Store/Types.hs` (118 lines)
- `kiroku-store/src/Kiroku/Store/Connection.hs` (103 lines)
- `kiroku-store/src/Kiroku/Store/Effect.hs` (293 lines)
- `kiroku-store/src/Kiroku/Store/Effect/Resource.hs` (44 lines)
- `kiroku-store/src/Kiroku/Store/Error.hs` (126 lines)
- `kiroku-store/src/Kiroku/Store/Append.hs` (27 lines)
- `kiroku-store/src/Kiroku/Store/Lifecycle.hs` (33 lines)
- `kiroku-store/src/Kiroku/Store/Link.hs` (18 lines)
- `kiroku-store/src/Kiroku/Store/Read.hs` (67 lines)
- `kiroku-store/src/Kiroku/Store/Subscription.hs` (40 lines)
- `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` (81 lines)
- `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` (66 lines)
- `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` (68 lines)
- `kiroku-store/test/Main.hs` (887 lines) — usage patterns
- `shibuya-kiroku-adapter/src/` — every file (real-world consumer)

### Audit Checklist

For every public symbol, record severity and a one-line note. The checklist is grouped by concern.

Type design:
- `StreamName Text`, `StreamId Int64`, `EventId UUID`, etc. — newtype wrappers with `deriving stock (Eq, Ord, Show, Generic)`. Confirm `Ord` makes sense for every newtype that has it (e.g. ordering by `EventId` is by UUID byte order, not generation time — possibly surprising for UUIDv7).
- `ExpectedVersion` — four constructors. Confirm naming clarity (`AnyVersion` may be misleading; "create-or-append" may be clearer).
- `EventData` and `RecordedEvent` — record types with overlapping field names. Confirm `DuplicateRecordFields` works at all call sites, including in pattern matches inside the adapter.
- `StreamInfo` — has `id` and `name` and `version` fields. The field names shadow Prelude functions (`id`) — confirm `OverloadedLabels` resolves the ambiguity in practice.

Effect design:
- The `Store` GADT has 12 constructors. Audit: which can be removed or split into a separate effect? For a v0.x library, splitting `Store` into `Store` + `StoreLifecycle` may be worth doing now while no consumer exists.
- `Subscription` effect is higher-order. Confirm the `localUnliftIO env (ConcUnlift Persistent (Limited 1))` strategy is correct (Persistent — environment survives across handler calls; Limited 1 — only one concurrent unlift per subscription, which is correct because the worker is a single thread). Document this in a Haddock note.
- `KirokuStoreResource` static effect (`Effect/Resource.hs`) — confirm the static-effect choice over a dynamic one is documented. Static is the right call (no need to mock the store handle), but the rationale should be in a comment.

Connection settings:
- `defaultConnectionSettings :: Text -> ConnectionSettings`. Confirm every setting is documented in the Haddock. Add `statement_timeout` if the audit determines it is needed for production safety (cross-plan with EP-5 — operational tuning).
- The `observationHandler :: Maybe (Observation -> m ())` field is monad-polymorphic via `ConnectionSettingsM m`. Confirm this works smoothly when `m ~ IO` (the default) and when callers want to thread the handler through `Eff`.
- `schema` field. Cross-plan with EP-4: the field is currently passed to the Notifier (which uses it in the LISTEN channel name) but not to the SQL statements. EP-4 owns the decision; this audit only flags it.

Error model:
- Multi-stream attribution bug (must-fix, see above).
- `ConnectionError` granularity (should-fix, see above).
- `mapUniqueViolation` (`Error.hs:75-92`) does string matching on `events_pkey` and `ix_streams_stream_name`. Confirm: the constraint names are stable across PostgreSQL versions and across schema migrations. If a future migration renames the constraint, the error mapping silently falls through to the generic-conflict branch (`WrongExpectedVersion`). Document the dependency.
- `extractEventId` falls back to `EventId UUID.nil` when parsing fails. Confirm: callers cannot misinterpret a nil UUID as a valid event id. Consider `Maybe EventId` instead.

Subscription API:
- `subscribe` returns a `SubscriptionHandle` with `cancel` and `wait`. The implicit contract is "must cancel before scope exits". Add `withSubscription` bracket. Document.
- `SubscriptionConfig` has a hard-coded default-less `batchSize :: Int32`. Confirm the test suite always sets it; consider providing a default.
- `subscriptionStream` (Streamly bridge) — confirm the queue capacity (the `Natural` parameter) matches Streamly's expectations and that the `Nothing` sentinel pattern does not leak events.
- The handler type `EventHandlerM m = RecordedEvent -> m SubscriptionResult`. Confirm callers can return `Stop` mid-batch and the worker correctly persists the checkpoint up to the event just processed (cross-plan with EP-3).

Documentation:
- For each public symbol, confirm a Haddock string exists. Catalogue gaps. Land additions in Milestone 2.
- For each public type, confirm a Haddock describes the contract for each constructor or field, not just the type.

Adapter validation:
- Read every file in `shibuya-kiroku-adapter/src/`. Identify any place where the adapter has had to work around a `kiroku-store` API limitation (search for `TODO`, `XXX`, `FIXME`, awkward patterns like manually constructing an `EventData` with default fields). Surface each as a finding.

### Milestone 2 commands

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    # 1. Add a regression test for the multi-stream attribution bug
    $EDITOR kiroku-store/test/Main.hs
    cabal test kiroku-store        # confirm new test fails (red)
    # 2. Land the fix
    $EDITOR kiroku-store/src/Kiroku/Store/Effect.hs
    cabal test kiroku-store        # green
    # 3. Commit
    git commit -m "fix(api): correctly attribute multi-stream conflicts to the failing stream

    <body>

    MasterPlan: docs/masterplans/1-production-readiness-review-of-kiroku-store.md
    ExecPlan: docs/plans/2-public-api-surface-types-and-error-model-audit.md
    Intention: intention_01khv3gg6xe91tt2pyqvxw1832"

Repeat the workflow for each must-fix finding. After all fixes are landed, confirm the adapter still compiles:

    cabal build shibuya-kiroku-adapter

If the adapter breaks, decide whether to update the adapter (recording the change in this plan's Decision Log) or to soften the API change.


## Validation and Acceptance

Milestone 1 is complete when every public export has a finding entry, and all cross-plan items (`Effect.hs` shared with EP-1 and EP-4; `Subscription/*` shared with EP-3) are listed in the MasterPlan's Surprises & Discoveries section.

Milestone 2 is complete when:

- `cabal build kiroku-store` and `cabal test kiroku-store` both succeed.
- `cabal build shibuya-kiroku-adapter` succeeds (with adapter updates if a breaking change was made).
- Every must-fix finding has a corresponding commit and regression test.
- The Decision Log enumerates every fix and every formally deferred should-fix item.
- The MasterPlan's Exec-Plan Registry status for EP-2 is "Complete".

Acceptance behaviours that a human can verify:

- Multi-stream attribution: write a multi-stream append with three streams `[a, b, c]` where `b` has a version conflict; the returned `WrongExpectedVersion` should name `b`, not `a`. Before the fix it names `a`.
- `withSubscription` bracket: a test that uses `withSubscription` and throws an exception in the body confirms the subscription is cancelled (the worker thread exits within a bounded time).
- Refined `StoreError`: a test that triggers a pool acquisition timeout (by setting pool size to 1 and running two concurrent operations with the second blocking) returns the new `PoolAcquisitionTimeout` constructor (or whatever name the audit settles on), distinguishable from `ConnectionError` for a connection drop.


## Idempotence and Recovery

The audit milestone is read-only. The fix milestone produces commits — each commit must leave the test suite green and the adapter compiling. If a fix breaks the adapter and the adapter cannot be cheaply updated, defer the fix to a follow-up plan and record the deferral in the Decision Log.

Breaking-change decisions (e.g. renaming `AnyVersion` to `CreateOrAppend`, splitting `Store` into multiple effects) must be reviewed with the user before landing — surface them as MasterPlan-level decisions before committing.


## Interfaces and Dependencies

Files this plan modifies:

- `kiroku-store/src/Kiroku/Store/Effect.hs` — multi-stream attribution fix. Coordinate with EP-1 (TOCTOU) and EP-4 (schema-name decision).
- `kiroku-store/src/Kiroku/Store/Error.hs` — refined error constructors if the audit confirms the need.
- `kiroku-store/src/Kiroku/Store/Subscription.hs`, `Subscription/Effect.hs` — `withSubscription` bracket, lifecycle Haddocks. Coordinate with EP-3.
- `kiroku-store/src/Kiroku/Store.hs` — new exports if `withSubscription` is added.
- `kiroku-store/src/Kiroku/Store/Types.hs` — Haddock additions only (no semantic changes expected unless an audit finding requires).
- `kiroku-store/src/Kiroku/Store/{Append,Lifecycle,Link,Read}.hs` — Haddock additions only.
- `kiroku-store/src/Kiroku/Store/Connection.hs` — Haddock additions; new fields if statement_timeout etc. is added (cross-plan with EP-5).
- `kiroku-store/test/Main.hs` — regression tests for every must-fix.
- `shibuya-kiroku-adapter/` — only if a breaking change forces it.

External dependencies. No new package dependencies are expected. If `withSubscription` requires `MonadMask` for proper exception handling, the existing `unliftio-core` should suffice.

Module-level interface contracts:

- `Kiroku.Store.Error.StoreError` — public error type owned by this plan. EP-1 may surface findings that prompt new constructors.
- `Kiroku.Store.Effect.Store` — public effect owned by this plan. EP-1 may surface findings that prompt operational changes (e.g. moving the soft-delete check inside the CTE, which is a `runStorePool` change owned by EP-1, not a `Store` GADT change).
- `Kiroku.Store.Subscription.SubscriptionHandle` — owned by this plan; EP-3 may add lifecycle invariants.
- `Kiroku.Store.Connection.ConnectionSettings` — owned by this plan; EP-5 may add fields for observability tuning.

This plan should not modify `kiroku-store/sql/schema.sql` or `kiroku-store/src/Kiroku/Store/SQL.hs` — those are owned by EP-1.
