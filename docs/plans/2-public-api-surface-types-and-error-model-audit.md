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

- [ ] Milestone 1: Audit findings document
  - [ ] Inventory the entire public surface (every export from `Kiroku.Store` and the modules it re-exports)
  - [ ] For each item, record purpose, contract (preconditions, postconditions, error cases), and severity classification
  - [ ] Cross-check `shibuya-kiroku-adapter/src/` for actual usage patterns and identify ergonomics issues from real call sites
  - [ ] Record findings inline in Surprises & Discoveries with file:line references
- [ ] Milestone 2: Land must-fix corrections
  - [ ] Fix the multi-stream error attribution bug
  - [ ] Refine `StoreError` to distinguish failure modes the SQL layer separates (coordinate with EP-1)
  - [ ] Add a `withSubscription` bracket and document the `Subscription` effect lifecycle contract
  - [ ] Land Haddock improvements for every public symbol that the audit flags as under-documented
  - [ ] Update the MasterPlan's Exec-Plan Registry status and Progress section


## Surprises & Discoveries

(None yet. The findings document produced in Milestone 1 will be reflected here with file:line references and severity classification.)

Initial leads identified during MasterPlan research, to be confirmed or refuted by the audit:

- Multi-stream error attribution bug (`kiroku-store/src/Kiroku/Store/Effect.hs:179-184`): on a `Left usageErr` from the multi-stream transaction, the interpreter maps the error using the *first* stream's name and expected version regardless of which stream actually conflicted. Severity: must-fix. Proposed fix: capture the per-statement failure within the transaction, or detect on-`Right` whether one or more results are `Nothing` and report the first conflicting `(StreamName, ExpectedVersion)` from the input list.
- `ConnectionError !Text` is the catch-all for: pool acquisition timeout (`Error.hs:46`), arbitrary session errors (`Error.hs:51`), arbitrary statement errors (`Error.hs:58`), and server errors with codes other than `23505`/`23503` (`Error.hs:65`). Consumers cannot programmatically distinguish "pool exhausted, retry" from "schema mismatch, fail" from "database down, escalate". Severity: should-fix; consider adding `PoolAcquisitionTimeout`, `SchemaMismatch` (for unrecognized server-error codes), and `TransientDatabaseError` (for connection drops) constructors.
- `subscribe` (`Subscription.hs`) and the higher-order `Subscription` effect (`Subscription/Effect.hs`) impose an implicit lifecycle contract — "the returned handle must be canceled before the effect scope exits". This is mentioned in a Haddock note (`Subscription/Effect.hs:43-47`) but no `withSubscription` bracket exists. Severity: should-fix.
- `Store` GADT (`Effect.hs:46-58`) has 12 constructors. Mockable via `interpret_` but the surface is wide. Audit: do all 12 belong here, or are some (e.g. `SoftDeleteStream`, `HardDeleteStream`, `UndeleteStream`) operationally distinct enough to warrant a separate effect? This is a potentially large API change — consider for v0.2.
- `EventData` and `RecordedEvent` are records with overlapping field names (`eventId`, `eventType`, `payload`, `metadata`, `causationId`, `correlationId`). The cabal file enables `DuplicateRecordFields` and `OverloadedLabels`. Audit: are field names disambiguated by `Data.Generics.Labels` lensing in all uses, including downstream? Confirm via the adapter.
- `defaultConnectionSettings` (`Connection.hs:47-55`) has hard-coded defaults: `poolSize = 10`, `idleInTransactionTimeout = 30`, `schema = "public"`. Audit: are these documented? Is there a `statement_timeout`? (No — gap.) Is the schema parameter actually wired through the SQL layer? (No — see EP-4.)
- `withStore` (`Connection.hs:67-102`) takes `MonadUnliftIO m`. Confirm this matches the pattern used by other production-grade Haskell libraries; some prefer `MonadResource` or `MonadMask`. Document the choice.
- `subscriptionStream` (`Subscription/Stream.hs:33`) provides a Streamly bridge. Audit: does the cancel action cleanly drain the queue without leaking events? Cross-plan with EP-3.
- The `ExpectedVersion` data constructor `AnyVersion` is documented as "Create or append, don't care" (`Types.hs:54`) but the SQL layer's `appendAnyVersionSQL` is a true upsert. Audit: is the rename from `AnyVersion` to `CreateOrAppend` worth the breakage? Or document more clearly?


## Decision Log

- Decision: Treat `shibuya-kiroku-adapter` as a real-world consumer reference for ergonomics findings; do not modify it as part of this plan, but read it to confirm or refute usage assumptions.
  Rationale: The MasterPlan scopes the adapter as out-of-scope as a target. Reading it is the cheapest way to validate that the API works for its intended audience.
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
