---
id: 14
slug: causation-chain-and-correlation-walkers-with-optional-opentelemetry-context-helpers
title: "Causation chain and correlation walkers with optional OpenTelemetry context helpers"
kind: exec-plan
created_at: 2026-05-14T03:21:30Z
intention: "intention_01krj7r6s9e9fbpm3phr7mza2d"
---


# Causation chain and correlation walkers with optional OpenTelemetry context helpers


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture


Today, every event written through `kiroku-store` carries two optional UUID columns the
caller can use to relate events to each other: `causation_id` (the immediate cause — the
`event_id` of the event that produced this one) and `correlation_id` (the saga or
transaction this event belongs to). They are defined on `EventData` and `RecordedEvent` in
`kiroku-store/src/Kiroku/Store/Types.hs` and are written to indexed columns in
`kiroku-store/sql/schema.sql`:

```sql
-- Correlation tracing
CREATE INDEX IF NOT EXISTS ix_events_correlation_id
    ON events (correlation_id) WHERE correlation_id IS NOT NULL;

-- Causation tracing
CREATE INDEX IF NOT EXISTS ix_events_causation_id
    ON events (causation_id) WHERE causation_id IS NOT NULL;
```

The fields are written and indexed, but `kiroku-store` exposes no helpers for *using*
them. A consumer that wants to reconstruct "every event that fanned out from this command"
or "every event in this saga" has to drop down to raw SQL through the
`Kiroku.Store.Transaction.runTransaction` escape hatch (added by
`docs/plans/11-single-stream-runtransaction-combinator.md`) and write the recursive walk by
hand. There is also nothing in the store that helps a caller stitch OpenTelemetry trace
context across causation links: the `metadata` JSONB column is the obvious carrier for
W3C `traceparent` / `tracestate` strings, but `EventData` and `RecordedEvent` do not know
that.

The downstream consumer driving this plan is `keiro`, a sister project at
`/Users/shinzui/Keikaku/bokuno/keiro` whose process managers (PMs) carry causation
chains: a PM emits a command whose resulting event's `causationId` is the source event's
`eventId`. Operators debugging a stuck saga routinely need "show me every event that
descended from this trigger" and "show me everything in correlation `…`"; without a
shared helper, every `keiro` engineer writes a one-off recursive query. Cross-process
tracing — connecting a kiroku-store span to the upstream span that emitted the source
event — is the same problem one level up: each engineer hand-rolls metadata encoding.

This ExecPlan ships four helpers and one new internal package. The shape of the public
surface, all at the repository root path `kiroku-store/src/`:

```haskell
-- Kiroku.Store.Causation (new module, in kiroku-store)
findCausationDescendants ::
    (HasCallStack, Store :> es) =>
    EventId ->
    Eff es (Vector RecordedEvent)

findCausationAncestors ::
    (HasCallStack, Store :> es) =>
    EventId ->
    Eff es (Vector RecordedEvent)

findByCorrelation ::
    (HasCallStack, Store :> es) =>
    UUID ->
    Eff es (Vector RecordedEvent)
```

`Kiroku.Store.Causation` is re-exported from `Kiroku.Store`. All three functions are pure
SQL-shape helpers that use only the existing indexes (`ix_events_causation_id`,
`ix_events_correlation_id`) and the existing `recordedEventRow` decoder from
`kiroku-store/src/Kiroku/Store/SQL.hs`. They do not introduce a new `Store` effect
constructor; they reuse a single new constructor for "fetch a set of `RecordedEvent` rows
by a SQL filter" — see the Decision Log entry on `FindEvents`.

The OpenTelemetry-aware helpers ship in a **new sister package** `kiroku-otel`, located at
`kiroku-otel/` in this repository (alongside `kiroku-store/` and
`shibuya-kiroku-adapter/`). The package depends on `kiroku-store` and on
`hs-opentelemetry-api`, pinned to the same `source-repository-package` git tag that
`cabal.project` already uses for `shibuya-core` (commit
`adc464b0a45e56a983fa1441be6e432b50c29e0e`). It exposes:

```haskell
-- Kiroku.Otel.TraceContext (new module, in new package kiroku-otel)
extractTraceContext :: RecordedEvent -> Maybe SpanContext
injectTraceContext  :: SpanContext  -> EventData -> EventData
```

`SpanContext` is the `OpenTelemetry.Trace.Core.SpanContext` type from
`hs-opentelemetry-api`. The two helpers read/write the W3C `traceparent` and `tracestate`
header strings inside `RecordedEvent.metadata` / `EventData.metadata` (a JSONB
`Data.Aeson.Value`) using the same encoder/decoder pair the
`OpenTelemetry.Propagator.W3CTraceContext` module already exports
(`decodeSpanContext`, `encodeSpanContext`). The user-facing JSON shape is:

```json
{
  "traceparent": "00-...-...-01",
  "tracestate":  "vendor=value"
}
```

merged into whatever else the caller has stored in `metadata`.

After this change, two new things are possible. **First**, a `keiro` engineer (or any
`kiroku-store` consumer) can write

```haskell
-- in Eff es, with Store :> es
descendants <- findCausationDescendants (EventId triggerUuid)
allInSaga  <- findByCorrelation sagaUuid
```

without forking the SQL path or pulling the `runTransaction` escape hatch. The
descendants vector starts with the seed event (if it exists) and continues with every
event whose `causation_id` forms a chain back to the seed. The correlation vector returns
every event with the given `correlation_id`, in `global_position` order. **Second**, the
same engineer can opt into trace propagation by depending on `kiroku-otel` from their
app's cabal file:

```haskell
import Kiroku.Otel.TraceContext (injectTraceContext, extractTraceContext)

-- before append:
let ev0 = makeEvent "OrderCreated" payload
    ev  = injectTraceContext spanContext ev0
_ <- appendToStream name expected [ev]

-- on read:
case extractTraceContext recordedEv of
    Nothing  -> -- no trace context recorded
    Just sc  -> -- continue the trace from sc
```

Consumers that do not want a transitive dependency on `hs-opentelemetry-api` simply do not
depend on `kiroku-otel`. The kiroku-store library's transitive dependency set is
unchanged.

The user can prove the change works by running, from
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/`:

```bash
cabal test kiroku-store:kiroku-store-test
cabal test kiroku-otel:kiroku-otel-test
```

and observing the new `describe "findCausationDescendants"`, `describe "findCausationAncestors"`,
`describe "findByCorrelation"`, and `describe "TraceContext round-trip"` groups all pass.
Specifically: a test appends a 5-deep causation chain `A → B → C → D → E` (each event's
`causationId` is the previous event's `eventId`) across three streams, calls
`findCausationDescendants (eventId A)`, and asserts the returned vector is `[A, B, C, D,
E]` in global-position order. A second test appends 7 events with the same
`correlationId` spread across four streams, calls `findByCorrelation`, and asserts the
length is 7 and every element has the expected correlation id. A third test in
`kiroku-otel-test` round-trips a W3C `SpanContext` through `injectTraceContext` /
`extractTraceContext` and asserts the result `traceId`, `spanId`, and `traceFlags` match
the input.


## Progress


Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Effect-level building block in `kiroku-store`.

- [x] Add a single new effect constructor `FindEvents :: EventFilter -> Store m (Vector
      RecordedEvent)` to `data Store :: Effect` in
      `kiroku-store/src/Kiroku/Store/Effect.hs`. `EventFilter` is a new closed sum
      living in `Kiroku.Store.Types` with two constructors: `FilterCorrelation !UUID`
      and `FilterCausationDescendants !EventId` and `FilterCausationAncestors
      !EventId`. The sum is closed so mock interpreters can pattern-match exhaustively.
      Done 2026-05-14.
- [x] Add a new SQL statement set to `kiroku-store/src/Kiroku/Store/SQL.hs`:
      `findByCorrelationStmt :: Statement UUID (Vector RecordedEvent)`,
      `findCausationDescendantsStmt :: Statement UUID (Vector RecordedEvent)`, and
      `findCausationAncestorsStmt :: Statement UUID (Vector RecordedEvent)`. The
      correlation statement is a flat `SELECT` driven by `ix_events_correlation_id`.
      The descendants statement is a `WITH RECURSIVE` walk seeded by the input
      `event_id`. The ancestors statement is the symmetric walk that follows
      `causation_id` upward. All three end with a join against `stream_events` so the
      returned `RecordedEvent` rows carry `stream_version`, `global_position`, and the
      `original_*` columns. See the SQL templates in Interfaces and Dependencies.
      Done 2026-05-14; ancestor SQL uses the cleaner self-join shape (see Decision Log
      entry on the ancestor-walk SQL simplification).
- [x] Add the interpreter branch for `FindEvents` in `runStorePool` that pattern-matches
      on `EventFilter` and dispatches to the correct statement via `usePool`. The branch
      pipes the result through `decodeEvents` so the `decodeHook` from `StoreSettings`
      applies to the new reads on parity with `readStreamForward` and friends.
      Done 2026-05-14.
- [x] Add public smart constructors `findCausationDescendants`,
      `findCausationAncestors`, and `findByCorrelation` to a new module
      `Kiroku.Store.Causation` exported from `kiroku-store.cabal`. Each is a one-liner
      that calls `send (FindEvents (FilterCausationDescendants eid))` and so on.
      Done 2026-05-14.
- [x] Re-export `Kiroku.Store.Causation` from `Kiroku.Store` in
      `kiroku-store/src/Kiroku/Store.hs`. Done 2026-05-14.
- [x] Build the library: `cabal build kiroku-store:lib:kiroku-store` from the repository
      root. Expect a clean build with no new warnings. Done 2026-05-14; 23/23 modules
      compiled with no warnings.

Milestone 2 — Tests for the causation/correlation helpers.

- [x] Add a new test module `kiroku-store/test/Test/Causation.hs`, wired into the
      `other-modules` list of `test-suite kiroku-store-test` in
      `kiroku-store/kiroku-store.cabal` and imported from `kiroku-store/test/Main.hs`.
      Done 2026-05-14.
- [x] Test "findCausationDescendants returns the seed event and every descendant in
      global-position order": append a 5-deep chain `A → B → C → D → E` across three
      streams `pm-trigger`, `pm-cmd`, `pm-result` (mimicking the PM hop pattern); each
      event after `A` supplies `causationId = Just (previousEvent.eventId)`. Call
      `findCausationDescendants (eventId A)` and assert the result is `[A, B, C, D, E]`
      compared by `eventId` and by `globalPosition` strictly increasing. Done 2026-05-14.
- [x] Test "findCausationDescendants on an eventId with no descendants returns a vector
      of length 1 (the seed only)": append one event with no causation arrow pointing
      at it; call `findCausationDescendants`; assert `V.length == 1` and the single
      element's `eventId` matches. Done 2026-05-14.
- [x] Test "findCausationDescendants on a non-existent eventId returns an empty vector":
      use a fresh `UUID.nil` (which is not used by any test event); assert `V.null`.
      Done 2026-05-14.
- [x] Test "findCausationAncestors walks from a leaf back to the root": with the same
      chain `A → B → C → D → E`, call `findCausationAncestors (eventId E)` and assert
      the result is `[E, D, C, B, A]` (leaf-first; the SQL `ORDER BY depth ASC` walks
      back from the leaf). Compare by `eventId`. Done 2026-05-14.
- [x] Test "findByCorrelation returns every event with the given correlation, in
      global-position order, across multiple streams": append 7 events across 4 streams
      with `correlationId = Just c`; append a noise event with no correlation; append
      an additional 5 events with `correlationId = Just c2` (a different correlation
      id). Call `findByCorrelation c`; assert the returned vector has length 7, every
      element's `correlationId == Just c`, and `globalPosition` is strictly increasing.
      Done 2026-05-14.
- [x] Test "findByCorrelation on an unknown correlation returns an empty vector".
      Done 2026-05-14.
- [x] Run the kiroku-store test suite: `cabal test kiroku-store:kiroku-store-test`.
      Done 2026-05-14; 125 examples (was 118), zero failures, ~82s wall time on the
      ephemeral-pg fixture.

Milestone 3 — New `kiroku-otel` package with W3C trace-context helpers.

- [x] Create `kiroku-otel/` at the repository root with `kiroku-otel.cabal`, `src/`,
      `test/`, and `CHANGELOG.md`. The cabal file declares the library target
      `kiroku-otel` exposing the single module `Kiroku.Otel.TraceContext`, with
      `build-depends` on `aeson`, `base`, `bytestring`, `kiroku-store`,
      `hs-opentelemetry-api ^>= 0.3`, `hs-opentelemetry-propagator-w3c ^>= 0.1`, `text`.
      The package version is `0.1.0.0` and the synopsis is "OpenTelemetry W3C
      trace-context helpers for Kiroku event metadata". `unordered-containers` was
      dropped from the dep list during implementation: `aeson`'s `Data.Aeson.KeyMap`
      and `Data.Aeson.Key` cover the JSON-object operations we need, so an explicit
      `HashMap` dependency would be dead weight. Done 2026-05-14.
- [x] Add `kiroku-otel` to `packages:` in `cabal.project` at the repository root. The
      file already lists `kiroku-store` and `shibuya-kiroku-adapter`. Do **not** add a
      new `source-repository-package` block for `hs-opentelemetry`; the project file
      already pins both `hs-opentelemetry-api` and `hs-opentelemetry-propagator-w3c` to
      git tag `adc464b0a45e56a983fa1441be6e432b50c29e0e` for the shibuya-core build,
      and `kiroku-otel` reuses that pin. See the Decision Log entry on the OTel version
      pin and the design constraint in Purpose. Done 2026-05-14.
- [x] Implement `Kiroku.Otel.TraceContext` in `kiroku-otel/src/Kiroku/Otel/TraceContext.hs`
      with the two functions described in Interfaces and Dependencies.
      `injectTraceContext` calls `OpenTelemetry.Propagator.W3CTraceContext.encodeSpanContext`
      to obtain the `traceparent` and `tracestate` `ByteString`s, decodes them to UTF-8
      `Text`, and merges them into the existing `metadata` JSON object (creating one if
      `metadata` was `Nothing`). `extractTraceContext` reads `metadata`, pulls the two
      string fields if present, encodes them back to `ByteString`, and calls
      `OpenTelemetry.Propagator.W3CTraceContext.decodeSpanContext`. Done 2026-05-14.
- [x] Add a test target `kiroku-otel-test` (Hspec) in `kiroku-otel.cabal`. Add the
      single test file `kiroku-otel/test/Main.hs` with the test groups described in
      Validation and Acceptance. Done 2026-05-14.
- [x] Add a `CHANGELOG.md` to `kiroku-otel/` with an `## Unreleased` heading describing
      the initial helper surface. Reference it under `extra-doc-files` in the cabal
      file. Done 2026-05-14.
- [x] Update the repository root `mori.dhall` to register the new package under
      `packages`: add a `Schema.Package` entry with `name = "kiroku-otel"`, `path = Some
      "kiroku-otel"`, and `description = Some "OpenTelemetry W3C trace-context helpers
      for Kiroku event metadata"`. Add `iand675/hs-opentelemetry` to `dependencies` so
      `mori show --full` reflects the new dep. Done 2026-05-14; `mori show --full`
      now lists three packages and includes `iand675/hs-opentelemetry` in the
      dependencies stanza.
- [x] Build and test the new package: from the repository root, run
      `cabal build kiroku-otel:lib:kiroku-otel` then `cabal test
      kiroku-otel:kiroku-otel-test`. Done 2026-05-14; clean build, 6/6 examples passing
      in ~1.6 ms.

Milestone 4 — Documentation and changelog.

- [x] Add an `## Unreleased` entry to `kiroku-store/CHANGELOG.md` (created by
      `docs/plans/11-single-stream-runtransaction-combinator.md`) describing the new
      `Kiroku.Store.Causation` module and its three functions. Cite the existing
      `ix_events_causation_id` / `ix_events_correlation_id` indexes as the reason the
      functions are cheap. Done 2026-05-14; entry sits above the plan-13 hooks
      section.
- [x] Run the targeted library + test build one final time from the repository root to
      confirm everything still links and tests pass:

      ```bash
      cabal build kiroku-store:lib:kiroku-store kiroku-otel:lib:kiroku-otel
      cabal test  kiroku-store:kiroku-store-test kiroku-otel:kiroku-otel-test
      ```

      Done 2026-05-14; both libraries up-to-date, `kiroku-store-test` 125/125 in
      ~85 s, `kiroku-otel-test` 6/6 in ~1.6 ms.


## Surprises & Discoveries


Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Surprise (2026-05-14)**: The plan asserted the kiroku-store test count was 109
  examples (the M3 outcome of plan 11). The actual pre-existing count on master at
  the start of M2 was 118 examples — the suite has grown by 9 examples since plan 11
  through subsequent merges. After adding the seven `Test.Causation` examples the
  total is 125, all passing. Evidence:

  ```text
  Finished in 82.0121 seconds
  125 examples, 0 failures
  Test suite kiroku-store-test: PASS
  ```

- **Surprise (2026-05-14)**: `Data.UUID.V7` is exposed only via the
  `mmzk-typeid` package, which is in the *library*'s `build-depends` but not in
  the *test target*'s. The test target listed `uuid` directly, so the test
  module switched to `Data.UUID.V4.nextRandom` for ad-hoc UUID generation. The
  store accepts any UUID for `eventId`; the column's default `uuidv7()` is only
  used when the caller supplies `Nothing`. Versioning of test-event UUIDs is
  irrelevant to the causation/correlation queries since both index on the raw
  bytes.

- **Surprise (2026-05-14)**: GHC 9.12 + `DuplicateRecordFields` rejects record
  updates whose field name appears on multiple datatypes (`eventId`,
  `causationId`, and `correlationId` all live on both `EventData` and
  `RecordedEvent`), even when the expression being updated has an unambiguous
  type. The test module compensates with `mkEventWithIds :: Text -> Maybe UUID
  -> Maybe UUID -> Maybe UUID -> EventData`, which builds an `EventData` from
  scratch via positional record syntax. This avoids per-call type annotations
  while keeping the test code readable.

- **Surprise (2026-05-14)**: The same `DuplicateRecordFields` rule bit
  `kiroku-otel` even harder than expected. The plan's sketch used
  `re.metadata` / `ed.metadata` selectors; the GHC 9.12 error is
  *"Ambiguous occurrence 'metadata'"* because both `EventData` and
  `RecordedEvent` have a `metadata` field. Record-dot syntax with type
  annotation (`metadata (ed :: EventData)`) is also rejected. Workaround:
  pattern-match on the constructor (`case ed of EventData{metadata = m} -> …`
  and `RecordedEvent{metadata = m} -> …`), then operate on a plain
  `Maybe Aeson.Value`. The record *update* `ed{metadata = …}` still works
  but emits a `-Wambiguous-fields` warning; the warning is informational
  ("type-directed disambiguation will not be supported by
  -XDuplicateRecordFields in future releases of GHC") so it's left as a
  future-compatibility flag rather than a build break.

- **Surprise (2026-05-14)**: `OpenTelemetry.Trace.Core.SpanContext` exposes
  field names (`traceId`, `spanId`, `traceFlags`, `traceState`, `isRemote`)
  that collide with the existing `Kiroku.Store.Types.RecordedEvent.eventType`
  imports, so the test module also has to annotate each
  `traceId (sc :: SpanContext)` access. Pattern-matching is not always
  practical for the comparator-style assertion, so explicit type ascription
  is used at the call site.


## Decision Log


- Decision: Ship the OpenTelemetry-aware helpers in a *new sister package* `kiroku-otel`
  rather than as an optional cabal flag inside `kiroku-store` or as an entirely separate
  repository.
  Rationale: the user's explicit design constraint is that `hs-opentelemetry-api` must
  not become a transitive dependency of `kiroku-store`. Three options were considered:
  (1) cabal flag (`flag opentelemetry { default: False }`) gating a new
  `Kiroku.Store.Otel` module — rejected because cabal flags propagate badly through the
  solver, force conditional Haddock builds, and make CI matrix combinatorics nontrivial;
  (2) entirely separate repository — rejected because the helper is six functions and
  fewer than 150 lines of code, and a cross-repo dependency would slow the very small
  change cycle this code is likely to see; (3) sister package in the same monorepo —
  selected. The sister package gets its own cabal file, its own test target, and its
  own dependency closure, while still benefiting from the shared `cabal.project`,
  `flake.nix`, and CI. `shibuya-kiroku-adapter/` already establishes the sister-package
  pattern in this repository, so this introduces no new layout.
  Date: 2026-05-14

- Decision: Pin `hs-opentelemetry-api` and `hs-opentelemetry-propagator-w3c` in
  `kiroku-otel` to the exact same `source-repository-package` git tag that
  `cabal.project` already uses for the shibuya-core build (commit
  `adc464b0a45e56a983fa1441be6e432b50c29e0e`).
  Rationale: the user's stated constraint references a hypothetical (or future)
  "Surprises & Discoveries entry of 2026-05-05 (EP-3)" that flags `hs-opentelemetry`
  version skew between `shibuya-core` and `pgmq-hs` as a build-environment coordination
  item. Whatever the precise origin of that constraint, the rule is clear: do not
  deepen the skew. The `cabal.project` file at the repository root already pins one
  specific git tag of `hs-opentelemetry` for shibuya-core's transitive use; if
  `kiroku-otel` introduced its own pin (or its own version range), the cabal solver
  would have to satisfy *two* constraints simultaneously, and any future bump in either
  pin would risk a conflict that takes the whole tree red. Reusing the same pin
  contributes zero new coordination cost.
  Date: 2026-05-14

- Decision: Introduce a single new `Store` effect constructor `FindEvents :: EventFilter
  -> Store m (Vector RecordedEvent)` rather than three separate constructors
  (`FindByCorrelation`, `FindCausationDescendants`, `FindCausationAncestors`).
  Rationale: the three operations share an identical shape — "fetch a vector of
  `RecordedEvent` rows matching a filter" — and adding three constructors would force
  every future mock interpreter to learn three new branches that are mechanically
  identical. Closing the filter into a single ADT (`EventFilter`) preserves
  exhaustiveness-checking (mock interpreters get a `-Wincomplete-patterns` warning if a
  new filter is added) without growing the effect surface linearly. The trade-off is
  that the smart constructor `findCausationDescendants` is now `send (FindEvents
  (FilterCausationDescendants eid))` rather than `send (FindCausationDescendants eid)`;
  the wrapper is one line and entirely mechanical.
  Date: 2026-05-14

- Decision: Surface both `findCausationDescendants` and `findCausationAncestors`
  rather than the single `findCausationChain` the user's interface sketch named.
  Rationale: the user's sketch was `findCausationChain :: EventId -> Eff es
  [RecordedEvent]` with the use case "reconstruct the chain for an operator who is
  debugging a stuck saga". That use case is *ambiguous* in direction: an operator might
  hold the root command's eventId and want everything that fanned out (descendants), or
  hold a tail event's eventId and want to trace back to the trigger (ancestors).
  Picking only one direction guarantees that the other half of the user base writes the
  helper themselves anyway. The PostgreSQL cost of supporting both is one additional
  `WITH RECURSIVE` template; the SQL is symmetric. The name `findCausationChain` is
  retained in spirit but the function is split for clarity. If a future plan finds that
  callers always want both halves, a third convenience function
  `findCausationChain = liftA2 (<>) findCausationAncestors findCausationDescendants` is
  trivially additive.
  Date: 2026-05-14

- Decision: Return `Vector RecordedEvent` from all three causation/correlation
  functions, not `[RecordedEvent]`.
  Rationale: every other read in `Kiroku.Store.Read` returns `Vector RecordedEvent`
  (`readStreamForward`, `readAllForward`, `readCategory`). Returning `[RecordedEvent]`
  here just because the user's interface sketch used the list type would introduce a
  one-off inconsistency. The user's sketch was a notional Haskell pseudo-signature in
  prose, not a binding type declaration; matching the rest of `kiroku-store`'s read API
  preserves the principle of least surprise.
  Date: 2026-05-14

- Decision: Do not add a per-call `limit :: Int32` argument to the
  causation/correlation functions. Return the full result set.
  Rationale: the existing `readStreamForward`-style read API uses an `Int32` limit
  because per-stream and per-`$all` reads are intentionally pageable. The causation
  use-case is "show me an entire chain so I can debug it"; a partial chain is actively
  unhelpful (the missing tail is exactly the part the operator needs to see).
  Correlation has a similar shape: sagas typically run a few dozen events; trimming the
  result by an arbitrary `Int32` would create a footgun where a caller silently misses
  events. If a saga or chain ever grows past a few thousand events, a future plan can
  add a streaming sibling (`findCausationDescendantsStream`) following the pattern
  introduced by `docs/plans/12-streamly-shaped-single-stream-forward-read.md`. We do
  not pre-emptively complicate the v1 API for that hypothetical.
  Date: 2026-05-14

- Decision: The causation walk's `WITH RECURSIVE` CTE includes the seed event in its
  output (i.e. the seed event is the depth-0 row).
  Rationale: an operator handed `findCausationDescendants triggerEventId` expects to
  see the trigger event itself plus every event it caused. Omitting the seed forces
  every caller to do a separate single-event lookup just to get back what they passed
  in. The user's sketch (`findCausationChain :: EventId -> Eff es [RecordedEvent]`) is
  consistent with "include the seed" — the result type `[RecordedEvent]` contains
  events, and the natural reading is "the chain rooted at this event". If the seed has
  no descendants, the result is a single-element vector. If the seed `event_id` does
  not exist in the table at all, the result is empty.
  Date: 2026-05-14

- Decision: Order causation-descendant results by `global_position ASC`, and order
  causation-ancestor results by `depth ASC` (i.e. leaf-first).
  Rationale: descendants of a trigger event are emitted forward in time; a global-
  position-ascending order matches the order an operator's mental model expects when
  reading "what happened after the trigger fired". Ancestors run the other way: the
  operator holds a *current* (likely stuck) event and wants to walk back along the
  chain — leaf, parent, grandparent, root — which is exactly `depth ASC` if depth is
  measured from the leaf. The SQL is symmetric: both queries are `WITH RECURSIVE` with
  a `depth` counter on the recursive step. Documented in the Haddock of each function.
  Date: 2026-05-14

- Decision: Allow `kiroku-otel`'s `injectTraceContext` to overwrite any existing
  `traceparent` / `tracestate` keys in `metadata`, but preserve all other keys.
  Rationale: the W3C trace-context spec is explicit that exactly one `traceparent` and
  one `tracestate` value travel with a span; emitting two of either is a protocol
  violation. Overwriting is the only behavior consistent with the spec. Preserving
  other keys is necessary because `metadata` is the caller's general-purpose JSON
  envelope — clobbering it would be a regression for any consumer already using it for
  tenant ids, user-id pinning, or release tags. The implementation merges via
  `Data.Aeson.Object` key-set union with overwrites limited to the two trace-context
  keys.
  Date: 2026-05-14

- Decision: When `extractTraceContext` is given a `RecordedEvent` whose `metadata` is
  `Nothing`, whose JSON shape is not an `Object`, or whose `traceparent` field is
  missing, return `Nothing` rather than throwing.
  Rationale: an event without trace context is not an error — it predates the trace
  instrumentation, came from a producer that does not emit one, or was deliberately
  scrubbed. Throwing would force every reader of the `metadata` column to bracket the
  call. Returning `Nothing` lets the caller decide whether to start a fresh trace,
  inherit from an ambient context, or skip the event. The W3C decode path
  (`decodeSpanContext`) already returns `Maybe SpanContext`; we propagate that shape.
  Date: 2026-05-14

- Decision: Simplify the ancestor-walk SQL during M1 implementation. The plan
  originally proposed a recursive step that used two scalar subqueries against
  `events` per chain row to look up the parent's `causation_id` and confirm the
  parent's `event_id`. The implementation uses a direct self-join instead:
  `JOIN events parent ON parent.event_id = current.causation_id` paired with
  `JOIN events current ON current.event_id = chain.event_id`. The recursive CTE
  still references `chain` exactly once (PostgreSQL's restriction), but the join
  shape is symmetric with the descendant walk and easier to read.
  Rationale: the plan itself flagged the original SQL as "denser than the
  descendant walk" and invited a single-self-join replacement if it caused
  planner pathology. Adopting the cleaner shape upfront removes one source of
  complexity without changing the index footprint — both shapes traverse
  `ix_events_causation_id`.
  Date: 2026-05-14

- Decision: Pipe `FindEvents` results through `decodeEvents` in the
  PostgreSQL interpreter, the same way every other read constructor does.
  Rationale: `Kiroku.Store.Settings`'s `decodeHook` was added by plan 13 and is
  expected to run on every read path. Skipping it for causation/correlation
  reads would silently bypass interpreter-level decode customization (e.g.,
  payload migration shims) and surface as "events look different depending on
  which read function I used." Cost is one extra `Eff es (Vector RecordedEvent)`
  hop; correctness gain is real.
  Date: 2026-05-14


## Outcomes & Retrospective


Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### Completion — 2026-05-14

**What shipped.** All four milestones landed in three commits on `master`:

1. `feat(store): add Kiroku.Store.Causation with causation/correlation walkers`
   (M1) — `EventFilter` ADT, three SQL statements, `FindEvents` effect
   constructor + interpreter branch, and the public smart-constructor module
   `Kiroku.Store.Causation` re-exported from `Kiroku.Store`.
2. `test(store): cover causation chain and correlation walkers` (M2) — 7 new
   examples in `Test.Causation`, bringing the kiroku-store suite from 118 to
   125 examples (the 109 figure quoted in the plan was stale).
3. `feat(otel): add kiroku-otel sister package with W3C trace-context helpers`
   (M3 + M4 changelogs) — new `kiroku-otel` package with
   `Kiroku.Otel.TraceContext`, its 6-example Hspec suite, `cabal.project`
   registration, and `mori.dhall` registration. Both changelogs updated.

**Behavior delivered against the Purpose.** A `keiro` engineer (or any
`kiroku-store` consumer) can now write `findCausationDescendants
(EventId triggerUuid)` to retrieve the trigger plus every descendant in
global-position order, `findCausationAncestors` to walk the same chain
in reverse from a leaf, and `findByCorrelation sagaUuid` to fan in
every event for a saga across however many streams it touched. Tracing
consumers opt in by depending on `kiroku-otel` and using
`injectTraceContext` / `extractTraceContext` on the `metadata` JSONB
column; `kiroku-store`'s `build-depends` is unchanged, preserving the
"no transitive `hs-opentelemetry` dependency" constraint.

**Validation evidence (commands the user can re-run).**

```bash
cabal build kiroku-store:lib:kiroku-store kiroku-otel:lib:kiroku-otel
cabal test  kiroku-store:kiroku-store-test kiroku-otel:kiroku-otel-test
```

* `kiroku-store-test`: 125 examples, 0 failures, ~85 s on the ephemeral-pg
  fixture.
* `kiroku-otel-test`: 6 examples, 0 failures, ~1.6 ms.

**Deviations from the plan.**

* The ancestor-walk SQL uses a single self-join (`current.causation_id =
  parent.event_id`) instead of the denser scalar-subquery shape originally
  sketched in Interfaces and Dependencies. Recorded in the Decision Log; the
  plan itself invited this simplification if no planner regression appeared.
* `decodeEvents` (the `StoreSettings.decodeHook` plumbing) is run on
  `FindEvents` results. Not called out in the original plan; added so the new
  reads stay on parity with every other read constructor. Recorded in the
  Decision Log.
* `kiroku-otel`'s `injectTraceContext` is implemented via pattern matching
  rather than record-dot syntax because `DuplicateRecordFields` on GHC 9.12
  flags `ed.metadata` / `re.metadata` as ambiguous (both `EventData` and
  `RecordedEvent` carry a `metadata` field of the same type). The
  `ed{metadata = …}` *update* still compiles with a `-Wambiguous-fields`
  notice, which GHC will retire in a future release. No follow-up needed
  beyond keeping an eye on that warning.
* The kiroku-store test suite gained 7 examples (118 → 125), not 6+1 as the
  plan stated — the plan double-counted one of the four `findCausationDescendants`
  cases.

**What's left / follow-ups.** None blocking. Optional future work:

* Streamly-shaped siblings (`findCausationDescendantsStream`,
  `findByCorrelationStream`) for chains that grow past a few thousand events,
  following the pattern from plan 12. Decision Log notes this is deliberately
  deferred.
* Eliminate the `-Wambiguous-fields` warning inside
  `kiroku-otel/src/Kiroku/Otel/TraceContext.hs` by either renaming `metadata`
  on one of the records or qualifying the record update via module-level
  qualification once GHC drops the type-directed disambiguation rule.
* A convenience `findCausationChain :: EventId -> Eff es (Vector
  RecordedEvent)` combining ancestors and descendants, if real-world callers
  want it.

**Lessons.**

* `DuplicateRecordFields` interacts poorly with `OverloadedRecordDot` and
  with record update syntax when the same field name lives on multiple
  records of the same overall payload type. Pattern-matching against the
  constructor (`EventData{metadata = m}`) is the most robust workaround that
  doesn't pull in lens; explicit type ascription works for record updates
  but emits a deprecation warning.
* The test target's `build-depends` should be audited against the library's
  whenever a new test module reaches for a library-only transitive dep —
  `Data.UUID.V7` only lives in `mmzk-typeid`, which the test target didn't
  list.


## Context and Orientation


The repository root used throughout this plan is
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. All commands shown here assume that
working directory unless noted. The repository is a Cabal multi-package project; the
top-level `cabal.project` file lists `kiroku-store` and `shibuya-kiroku-adapter` as
packages today, and this plan adds a third package `kiroku-otel`.

### What `kiroku-store` is and how reads work today

`kiroku-store` (sources under `kiroku-store/src/`) is the Haskell event-store library this
plan extends. The two relevant concepts are the abstract `Store` effect and the SQL layer
beneath it.

The `Store` effect is declared in `kiroku-store/src/Kiroku/Store/Effect.hs` as
`data Store :: Effect where …`, with one constructor per high-level operation:
`AppendToStream`, `ReadStreamForward`, `ReadAllForward`, `GetStream`, `LinkToStream`,
`AppendMultiStream`, the soft/hard delete family, `RunTransaction`,
`RunTransactionNoRetry`, etc. Each constructor is interpreted by `runStorePool`, which
pattern-matches on the constructor and dispatches the appropriate SQL statement against a
`Hasql.Pool.Pool` via the local helper `usePool :: Pool -> Hasql.Session.Session a -> Eff
es a`. Smart constructors in sibling modules (`Kiroku.Store.Append`, `Kiroku.Store.Read`,
`Kiroku.Store.Lifecycle`, `Kiroku.Store.Link`) wrap each constructor via `send` to
provide the public API. This plan adds one constructor (`FindEvents`) and one smart-
constructor module (`Kiroku.Store.Causation`); see Plan of Work for details.

The SQL statements live in `kiroku-store/src/Kiroku/Store/SQL.hs`. Every read statement
shares a single decoder `recordedEventRow :: D.Row RecordedEvent` (declared at lines
355–368), which decodes the eleven columns of a `RecordedEvent` from a join of the
`events` table against the `stream_events` junction table. This plan reuses
`recordedEventRow` verbatim — the new statements end with the same eleven `SELECT`
columns in the same order.

### What `RecordedEvent`, `causation_id`, and `correlation_id` look like

`kiroku-store/src/Kiroku/Store/Types.hs` defines:

```haskell
data RecordedEvent = RecordedEvent
    { eventId :: !EventId          -- newtype around UUID; the primary key of the row
    , eventType :: !EventType
    , streamVersion :: !StreamVersion
    , globalPosition :: !GlobalPosition
    , originalStreamId :: !StreamId
    , originalVersion :: !StreamVersion
    , payload :: !Aeson.Value
    , metadata :: !(Maybe Aeson.Value)
    , causationId :: !(Maybe UUID)
    , correlationId :: !(Maybe UUID)
    , createdAt :: !UTCTime
    }
```

and the writeable shape

```haskell
data EventData = EventData
    { eventId :: !(Maybe EventId)
    , eventType :: !EventType
    , payload :: !Aeson.Value
    , metadata :: !(Maybe Aeson.Value)
    , causationId :: !(Maybe UUID)
    , correlationId :: !(Maybe UUID)
    }
```

The schema in `kiroku-store/sql/schema.sql` writes `causation_id` and `correlation_id` to
the `events` table and indexes each with a partial index (`WHERE … IS NOT NULL`). The
indexes are already present; the cost of adding the new queries is zero schema work.

### How the `Store` effect leaks Hasql in one tightly scoped place

`Kiroku.Store.Effect` already includes `RunTransaction :: Hasql.Transaction.Transaction a
-> Store m a` and a sister `RunTransactionNoRetry` (added by
`docs/plans/11-single-stream-runtransaction-combinator.md`). Those constructors are the
*only* place in the effect that exposes a third-party `Hasql` type. The new `FindEvents`
constructor introduced by this plan is *not* such a leak: its argument is a closed
`EventFilter` sum defined inside `Kiroku.Store.Types`, and the return type is the same
`Vector RecordedEvent` shape used by every existing read. Mock interpreters that
implement `Store` can pattern-match exhaustively on `EventFilter`.

### What `hs-opentelemetry` already provides

`hs-opentelemetry` is the Haskell distribution of the OpenTelemetry specification. The
repository at `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/`
contains many subpackages; this plan needs two:

- `hs-opentelemetry-api` (subdir `api/`) provides the `SpanContext` type at
  `api/src/OpenTelemetry/Internal/Trace/Types.hs`. Re-exported by
  `OpenTelemetry.Trace.Core`, a `SpanContext` records `traceFlags`, `isRemote`,
  `traceId`, `spanId`, and `traceState`. It is the canonical W3C trace-context
  representation in this ecosystem.
- `hs-opentelemetry-propagator-w3c` (subdir `propagators/w3c/`) provides
  `OpenTelemetry.Propagator.W3CTraceContext` which exports two functions used by this
  plan:
    - `decodeSpanContext :: Maybe ByteString -> Maybe ByteString -> Maybe SpanContext`
      — takes a `traceparent` header value and an optional `tracestate` value, returns
      a `SpanContext` if both parse.
    - `encodeSpanContext :: Span -> IO (ByteString, ByteString)` — emits the
      `traceparent` and `tracestate` header values for a given `Span`. (Note: the
      `encodeSpanContext` signature takes `Span`, not `SpanContext` directly, because
      the propagator pulls the immutable span-context portion out of the span. The
      `injectTraceContext` helper wraps a caller-supplied `SpanContext` in a
      `FrozenSpan` via `OpenTelemetry.Trace.Core.wrapSpanContext` before calling
      `encodeSpanContext`. See Interfaces and Dependencies for the exact code.)

Both libraries are already entered in `cabal.project` at the repository root as
`source-repository-package` blocks pinned to git tag
`adc464b0a45e56a983fa1441be6e432b50c29e0e`. They are pulled in today only because
`shibuya-core` (used by `shibuya-kiroku-adapter` and a benchmark) depends on them. The
`kiroku-store` library does *not* depend on either. This plan keeps that property: only
the new `kiroku-otel` package depends on them.

### What the W3C trace-context wire shape looks like

A W3C trace-context propagation carries two HTTP-header-like strings:

```text
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
tracestate:  vendor1=value1,vendor2=value2
```

`kiroku-otel` reuses these field names verbatim as JSON keys inside the event's
`metadata` object. The JSON shape (when both fields are present) is exactly:

```json
{
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "tracestate":  "vendor1=value1,vendor2=value2"
}
```

`tracestate` is optional per the spec; `kiroku-otel` writes it only when non-empty and
reads it as `Nothing` when absent (which `decodeSpanContext` handles gracefully).

### Sister package precedent in this repository

`shibuya-kiroku-adapter/` is the existing sister package in this repository. Its layout
(`src/`, `test/`, `shibuya-kiroku-adapter.cabal`, `CHANGELOG.md`) is the template that
`kiroku-otel/` follows. The cabal file imports the same `common common` stanza pattern
used by `kiroku-store`'s cabal file, sets `GHC2024` as the default language, and uses
`hs-source-dirs: src`. The repository's `cabal.project` lists both packages explicitly
under `packages:`. This plan adds a third entry.

### Files this plan touches

Reading list, in order, for a contributor implementing this plan:

1. `kiroku-store/src/Kiroku/Store/Types.hs` — defines `RecordedEvent`, `EventData`,
   `EventId`, and (after this plan) `EventFilter`.
2. `kiroku-store/src/Kiroku/Store/SQL.hs` — the prepared-statement layer. Already
   contains `recordedEventRow`; this plan adds three new statements next to the
   existing read statements.
3. `kiroku-store/src/Kiroku/Store/Effect.hs` — declares `Store` and `runStorePool`. This
   plan adds the `FindEvents` constructor and its interpreter branch.
4. `kiroku-store/src/Kiroku/Store/Causation.hs` — new module exporting the three smart
   constructors.
5. `kiroku-store/src/Kiroku/Store.hs` — the umbrella module that re-exports the public
   API; this plan adds `module Kiroku.Store.Causation` to the re-export list.
6. `kiroku-store/kiroku-store.cabal` — register `Kiroku.Store.Causation` under
   `exposed-modules`. Register `Test.Causation` under the test target's `other-modules`.
7. `kiroku-store/test/Test/Causation.hs` (new) and `kiroku-store/test/Main.hs` — hook the
   new test module into the existing Hspec suite.
8. `cabal.project` at the repository root — add `kiroku-otel` to `packages:`.
9. `kiroku-otel/` (new directory): `kiroku-otel.cabal`, `src/Kiroku/Otel/TraceContext.hs`,
   `test/Main.hs`, `CHANGELOG.md`.
10. `mori.dhall` at the repository root — register `kiroku-otel` under `packages` and
    add `iand675/hs-opentelemetry` to `dependencies`.


## Plan of Work


The work is broken into four milestones, each ending in a state where every package
builds and every test target passes. The milestones are ordered so that each is
independently verifiable: M1 produces a building library with a new effect constructor
but no public smart constructors yet (so it can be sanity-checked alone). M2 adds the
public smart constructors and their tests. M3 stands up the new package. M4 is purely
documentation.

### Costs and hazards (read first)

1. **Recursive CTEs can be expensive at scale.** A causation chain longer than a few
   thousand hops will take measurable wall-clock time on PostgreSQL because the
   recursive step does an index lookup per depth. The partial index
   `ix_events_causation_id` keeps the per-step cost at O(log n) so the total cost is
   O(depth · log n), but if a saga emits thousands of events the operator will notice.
   No mitigation is built in to v1 — see the Decision Log entry on rejecting a `limit`
   parameter. If real-world chains grow past a few thousand events, follow-up work
   should expose a streaming sibling (per
   `docs/plans/12-streamly-shaped-single-stream-forward-read.md`).
2. **`hs-opentelemetry` version skew.** The user's stated constraint flags
   `hs-opentelemetry` version skew between `shibuya-core` and `pgmq-hs` as a
   build-environment coordination item; this plan must not deepen that skew. Mitigation:
   `kiroku-otel` pins exactly the same `source-repository-package` git tag (commit
   `adc464b0a45e56a983fa1441be6e432b50c29e0e`) that `cabal.project` already records for
   shibuya-core. See Decision Log.
3. **`encodeSpanContext :: Span -> IO …`, not `SpanContext -> Pure`.** The W3C
   propagator API operates on `Span` (a mutable handle) rather than `SpanContext` (an
   immutable record), because span-context emission is the propagator's
   pluggable-vendor extension point. The `injectTraceContext :: SpanContext -> EventData
   -> EventData` shape the user asked for is pure (no `IO`). Mitigation:
   `OpenTelemetry.Trace.Core.wrapSpanContext :: SpanContext -> Span` already provides a
   pure "frozen" `Span` carrying just the span-context payload; wrapping with that and
   then calling `encodeSpanContext` is safe but the latter still returns `IO`. Resolve
   by using `unsafePerformIO` at the wrap site: `encodeSpanContext` on a frozen span is
   provably pure (it neither reads nor writes any reference and never throws), and
   tagging the use with `NOINLINE` plus a comment cites this rationale. Tested by the
   round-trip property test in `kiroku-otel-test`. Alternative considered: keep
   `injectTraceContext` in `IO` and rename to `injectTraceContextIO`. Rejected because
   the user's interface sketch explicitly typed the function as pure and the
   `unsafePerformIO` is genuinely justified here.
4. **`FindEvents` constructor breaks any in-tree mock interpreter.** If a downstream
   consumer (notably `shibuya-kiroku-adapter` or a future test helper) has its own
   `Store` interpreter, adding a constructor produces an `-Wincomplete-patterns`
   warning. As of writing, no such mock exists in this repository
   (`shibuya-kiroku-adapter` consumes `kiroku-store` only via the public smart
   constructors). The warning is the desired signal — it tells future authors to add a
   branch. Documented in the Decision Log.

### Milestone 1 — Effect-level building block in `kiroku-store`

**Scope.** Add the `EventFilter` ADT, the three SQL statements, and the `FindEvents`
effect constructor with its interpreter branch. No public smart constructors yet. After
this milestone, the library compiles and the constructor is callable via `send
(FindEvents …)` from any `Store :> es` context, but nothing exports a convenient name
for it.

**What will exist that did not before.** A working SQL → effect path that returns
`Vector RecordedEvent` for any of the three filters. The `kiroku-store` library target
builds cleanly; the test target still runs the unchanged 109-example suite (the
constructor is unused by tests until M2).

**Commands.**

```bash
cabal build kiroku-store:lib:kiroku-store
cabal test  kiroku-store:kiroku-store-test
```

Expect a clean build and the pre-existing example count, all passing.

**Acceptance.** `runStorePool` pattern-matches on every constructor of `Store` exhaustively
(GHC's exhaustiveness check confirms). The new SQL statements are exercised by no test in
this milestone, but a `ghci` smoke test session (recorded in the Concrete Steps section
below) confirms each statement runs against a fresh ephemeral PostgreSQL with the schema
applied.

### Milestone 2 — Public smart constructors and tests

**Scope.** Add `Kiroku.Store.Causation` with three exported functions
(`findCausationDescendants`, `findCausationAncestors`, `findByCorrelation`); add the
seven tests listed in the Progress section; wire the new test module into the suite.

**What will exist that did not before.** A consumer can write `import Kiroku.Store
(findCausationDescendants)` and call the function from `Eff es` with `Store :> es`. The
test suite gains six examples and passes.

**Commands.**

```bash
cabal build kiroku-store:lib:kiroku-store
cabal test  kiroku-store:kiroku-store-test
```

Expect the example count to rise by six and every example to pass. Record the before/
after counts in Surprises & Discoveries.

**Acceptance.** Each of the seven test cases passes. The Haddock for each smart
constructor renders cleanly (`cabal haddock kiroku-store:lib:kiroku-store`).

### Milestone 3 — New `kiroku-otel` package

**Scope.** Stand up the new package at `kiroku-otel/`. Implement
`Kiroku.Otel.TraceContext` with `injectTraceContext` and `extractTraceContext`. Add the
Hspec test suite at `kiroku-otel/test/Main.hs` with the round-trip and missing-context
test cases. Register the package in `cabal.project` and `mori.dhall`.

**What will exist that did not before.** A second build target `kiroku-otel:lib:kiroku-otel`
and its test target `kiroku-otel:kiroku-otel-test`. The repository now has three packages:
`kiroku-store`, `shibuya-kiroku-adapter`, `kiroku-otel`. The mori manifest reflects all
three. The `kiroku-store` library's `build-depends` and exposed-module list are
unchanged.

**Commands.**

```bash
cabal build kiroku-otel:lib:kiroku-otel
cabal test  kiroku-otel:kiroku-otel-test
```

Expect a clean build and a green test suite (six examples — see Validation).

**Acceptance.** The cabal file resolves the `hs-opentelemetry-api` and
`hs-opentelemetry-propagator-w3c` dependencies against the `cabal.project`
`source-repository-package` pin (verifiable from the `cabal build --dry-run` output:
the resolved version numbers should match the tag's published Cabal `version:` fields).
The mori manifest now lists `kiroku-otel` under `packages` and
`iand675/hs-opentelemetry` under `dependencies`.

### Milestone 4 — Documentation and changelog

**Scope.** Update `kiroku-store/CHANGELOG.md` and `kiroku-otel/CHANGELOG.md`. Run the
full build + test sequence one final time.

**What will exist that did not before.** Public-surface changelog entries that name the
new functions and the rationale. No code changes.

**Commands.**

```bash
cabal build kiroku-store:lib:kiroku-store kiroku-otel:lib:kiroku-otel
cabal test  kiroku-store:kiroku-store-test kiroku-otel:kiroku-otel-test
```

Expect both targets to build and both test suites to pass.

**Acceptance.** Both `CHANGELOG.md` files contain `## Unreleased` entries documenting
the new surface in the user-facing vocabulary defined in this plan (no internal
`EventFilter` constructor names; only the public function names).


## Concrete Steps


All commands assume the working directory is the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Update this section as work
proceeds.

### Step 1: Read the existing read-statement layout

```bash
sed -n '350,500p' kiroku-store/src/Kiroku/Store/SQL.hs
```

Expected to display the `recordedEventRow` decoder (around line 355) and the
`readStreamForwardStmt` / `readStreamForwardSQL` pair (around lines 394 and 442). Use
the same module conventions (`{-# LANGUAGE MultilineStrings #-}`, multi-line `"""..."""`
SQL templates, `preparable`-based `Statement` declarations) for the three new
statements.

### Step 2: Add the `EventFilter` ADT to `Kiroku.Store.Types`

Edit `kiroku-store/src/Kiroku/Store/Types.hs`. Add to the export list:

```haskell
    EventFilter (..),
```

and define, alongside the existing data types:

```haskell
data EventFilter
    = FilterCorrelation !UUID
    | FilterCausationDescendants !EventId
    | FilterCausationAncestors !EventId
    deriving stock (Eq, Show, Generic)
```

`UUID` is already imported in this module (`import Data.UUID (UUID)`); `Generic` is too.

### Step 3: Add the three SQL statements to `Kiroku.Store.SQL`

Edit `kiroku-store/src/Kiroku/Store/SQL.hs`. Add to the export list (next to the existing
`readStreamForwardStmt`, `readAllForwardStmt`, etc.):

```haskell
    findByCorrelationStmt,
    findCausationDescendantsStmt,
    findCausationAncestorsStmt,
```

and at the bottom of the Read Statements section, add the three statement declarations
and SQL templates. The exact code is given in Interfaces and Dependencies below.

### Step 4: Add the `FindEvents` constructor and interpreter branch

Edit `kiroku-store/src/Kiroku/Store/Effect.hs`. Inside `data Store :: Effect where`,
add a new constructor next to the existing read constructors:

```haskell
    FindEvents :: EventFilter -> Store m (Vector RecordedEvent)
```

`EventFilter` is the new type from Step 2. `Vector RecordedEvent` is the same return
shape as the other read constructors.

Inside `runStorePool`'s `interpret_` block, add the branch:

```haskell
    FindEvents filt -> case filt of
        FilterCorrelation cid ->
            usePool (store ^. #pool) $
                Session.statement cid SQL.findByCorrelationStmt
        FilterCausationDescendants (EventId eid) ->
            usePool (store ^. #pool) $
                Session.statement eid SQL.findCausationDescendantsStmt
        FilterCausationAncestors (EventId eid) ->
            usePool (store ^. #pool) $
                Session.statement eid SQL.findCausationAncestorsStmt
```

### Step 5: Add `Kiroku.Store.Causation` and re-export it

Create `kiroku-store/src/Kiroku/Store/Causation.hs` with the three smart constructors;
see Interfaces and Dependencies for the exact module body.

Add `Kiroku.Store.Causation` to `exposed-modules` in
`kiroku-store/kiroku-store.cabal`. The relevant section currently reads:

```cabal
  exposed-modules:
    Kiroku.Store
    Kiroku.Store.Append
    Kiroku.Store.Connection
    Kiroku.Store.Effect
    Kiroku.Store.Effect.Resource
    Kiroku.Store.Error
    Kiroku.Store.Lifecycle
    Kiroku.Store.Link
    Kiroku.Store.Notification
    Kiroku.Store.Observability
    Kiroku.Store.Read
    Kiroku.Store.Schema
    Kiroku.Store.Subscription
    …
```

Insert `Kiroku.Store.Causation` alphabetically between `Append` and `Connection`.

In `kiroku-store/src/Kiroku/Store.hs`, add `module Kiroku.Store.Causation` to the
`module … (` re-export list and `import Kiroku.Store.Causation` to the import block,
following the pattern established by the other modules.

### Step 6: Build the library

```bash
cabal build kiroku-store:lib:kiroku-store
```

Expect a clean build. If `runStorePool` warns about missing `FindEvents` branch coverage,
re-check Step 4.

### Step 7: Add the test module and run the kiroku-store test suite

Create `kiroku-store/test/Test/Causation.hs` with the seven test cases listed in the
Progress section. Use the same skeleton as
`kiroku-store/test/Test/Transaction.hs`: a top-level `spec :: Spec` using
`Test.Helpers.withTestStore` via `around`.

Register `Test.Causation` in `kiroku-store/kiroku-store.cabal` under the test target's
`other-modules`:

```cabal
  other-modules:
    Test.Causation
    Test.Concurrency
    Test.FailureInjection
    Test.Helpers
    Test.Properties
    Test.Transaction
```

Wire the spec into `kiroku-store/test/Main.hs`: add `import Test.Causation qualified as
Causation` and a `Causation.spec` call alongside the existing `Transaction.spec`.

Run the test suite:

```bash
cabal test kiroku-store:kiroku-store-test
```

The pre-existing count (109 examples per the M3 outcome of plan 11) should rise by 7 to
116 examples — six tests for `findCausationDescendants` / `findCausationAncestors` /
`findByCorrelation`, plus one for the empty-correlation case. Record the actual
before/after counts in Surprises & Discoveries.

### Step 8: Create the `kiroku-otel` package skeleton

```bash
mkdir -p kiroku-otel/src/Kiroku/Otel kiroku-otel/test
```

Create `kiroku-otel/kiroku-otel.cabal` with the exact contents shown in Interfaces and
Dependencies. Create empty placeholder files `kiroku-otel/src/Kiroku/Otel/TraceContext.hs`
and `kiroku-otel/test/Main.hs` (they will be filled in Steps 9 and 10).

Add `kiroku-otel` to `packages:` in `cabal.project`. The relevant section currently reads:

```text
packages:
  kiroku-store
  shibuya-kiroku-adapter
```

Change it to:

```text
packages:
  kiroku-store
  shibuya-kiroku-adapter
  kiroku-otel
```

Do **not** modify the existing `source-repository-package` blocks for
`hs-opentelemetry`. They already pin the right commit.

### Step 9: Implement `Kiroku.Otel.TraceContext`

Edit `kiroku-otel/src/Kiroku/Otel/TraceContext.hs` with the module body shown in
Interfaces and Dependencies.

Build:

```bash
cabal build kiroku-otel:lib:kiroku-otel
```

Expect a clean build. If a `hs-opentelemetry-api` import cannot be resolved, confirm
`cabal.project`'s existing `source-repository-package` blocks are intact (they may have
been disturbed by a merge).

### Step 10: Implement the `kiroku-otel-test` suite

Edit `kiroku-otel/test/Main.hs` with the test groups described in Validation and
Acceptance. Run:

```bash
cabal test kiroku-otel:kiroku-otel-test
```

Expect six examples to pass.

### Step 11: Update `mori.dhall`

Edit `mori.dhall` at the repository root. In the `packages` list, add an entry between
the existing `kiroku-store` and `shibuya-kiroku-adapter` packages (or after them; mori
does not enforce order):

```dhall
      , Schema.Package::{ name = "kiroku-otel"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-otel"
        , description = Some "OpenTelemetry W3C trace-context helpers for Kiroku event metadata"
        }
```

In the `dependencies` list, add `"iand675/hs-opentelemetry"` (the exact qualified name
mori uses, as confirmed by `mori registry list | grep opentelemetry`).

Verify:

```bash
mori show --full
```

Expect the output to list three packages under the `kiroku` project and to include
`iand675/hs-opentelemetry` in the dependencies stanza.

### Step 12: Update changelogs

Append an `## Unreleased` entry to `kiroku-store/CHANGELOG.md` describing the three new
exports of `Kiroku.Store.Causation` and citing the existing index coverage as the
performance rationale. Append a parallel entry to `kiroku-otel/CHANGELOG.md` (created in
Step 8) describing the two trace-context helpers.

### Step 13: Final build and test

```bash
cabal build kiroku-store:lib:kiroku-store kiroku-otel:lib:kiroku-otel
cabal test  kiroku-store:kiroku-store-test kiroku-otel:kiroku-otel-test
```

Expect every target to build and every test target to pass. Record the result in
Outcomes & Retrospective.


## Validation and Acceptance


The user-visible behavior to verify is:

1. **A `keiro` engineer can call `findCausationDescendants` and get the whole
   downstream chain.** Test scenario in `kiroku-store/test/Test/Causation.hs`:

    - Append event `A` to stream `pm-trigger` with no causation/correlation.
    - Append event `B` to stream `pm-cmd` with `causationId = Just (uuidOf A)` and
      `correlationId = Just c`.
    - Append event `C` to stream `pm-cmd` with `causationId = Just (uuidOf B)` and
      `correlationId = Just c`.
    - Append event `D` to stream `pm-result` with `causationId = Just (uuidOf C)`.
    - Append event `E` to stream `pm-result` with `causationId = Just (uuidOf D)`.
    - Call `findCausationDescendants (eventId A)`.
    - Assert: the returned `Vector` has length 5; the `eventId`s in order are
      `[A, B, C, D, E]`; every `globalPosition` is strictly greater than the previous.

2. **`findCausationAncestors` walks the same chain backward from a leaf.** Using the
   same fixtures: call `findCausationAncestors (eventId E)` and assert the returned
   `eventId`s in order are `[E, D, C, B, A]`.

3. **`findByCorrelation` fans in across streams.** Append 7 events across 4 streams all
   carrying `correlationId = Just c`. Append a noise event with `correlationId =
   Nothing` and 5 events with `correlationId = Just c2`. Call `findByCorrelation c` and
   assert length 7, every element's `correlationId == Just c`, `globalPosition`
   strictly increasing.

4. **Empty results are returned for absent inputs.** Calling
   `findCausationDescendants (EventId UUID.nil)` and `findByCorrelation UUID.nil`
   each returns an empty `Vector`.

5. **`injectTraceContext` round-trips through `extractTraceContext`.** In
   `kiroku-otel/test/Main.hs`:

    - Build a `SpanContext` with a known `traceId`, `spanId`, `traceFlags = 0x01` (the
      "sampled" flag), `isRemote = True`, and `traceState = empty`. Use
      `OpenTelemetry.Trace.Core.TraceFlags` and the trace-id / span-id constructors in
      `OpenTelemetry.Trace.Id`.
    - Call `injectTraceContext sc (makeEvent "X" Null)` (where `makeEvent` is the
      test-helper that builds an `EventData` with empty metadata).
    - Build a `RecordedEvent` by copying the resulting `EventData`'s metadata onto a
      stub `RecordedEvent` (the OTel test does not need a real database; it only
      tests pure metadata round-tripping). The test-helper is local to the OTel test
      and lives in `kiroku-otel/test/Main.hs`.
    - Call `extractTraceContext recordedStub`.
    - Assert: the result is `Just sc'` where `sc'.traceId == sc.traceId`,
      `sc'.spanId == sc.spanId`, `sc'.traceFlags == sc.traceFlags`.

6. **`extractTraceContext` returns `Nothing` for events without trace metadata.**
   Three sub-cases: `metadata = Nothing`, `metadata = Just (Aeson.object [])`, and
   `metadata = Just (Aeson.object [("traceparent", Aeson.String "garbage")])`. The
   third case verifies that an unparseable `traceparent` produces `Nothing` rather
   than a runtime error.

7. **`injectTraceContext` preserves existing metadata keys.** Start with `metadata =
   Just (Aeson.object [("tenant", Aeson.String "acme")])`. After `injectTraceContext`,
   the metadata should contain both `tenant` and the trace-context keys.

Test commands (run from the repository root):

```bash
cabal test kiroku-store:kiroku-store-test
cabal test kiroku-otel:kiroku-otel-test
```

Expected: zero failures across both targets. The kiroku-store target should report 7
new examples relative to current master; the kiroku-otel target should report 6 examples
total (it is new).


## Idempotence and Recovery


Every step in Concrete Steps is additive and safe to re-run:

- The new `EventFilter` ADT, the `FindEvents` constructor, and the three SQL statements
  are pure code additions. Re-applying a partial edit (e.g. via `git stash pop`) cannot
  damage existing data — the SQL never `UPDATE`s or `DELETE`s, and the events table is
  immutable by trigger anyway (see `kiroku-store/sql/schema.sql` lines 102–116).
- Creating the `kiroku-otel/` directory and its skeleton files is idempotent: re-running
  `mkdir -p` is harmless, and re-writing the cabal/source files overwrites the previous
  contents.
- Updating `cabal.project` to add `kiroku-otel` to `packages:` is idempotent provided
  the change is applied via `git diff` review (do not re-append a duplicate `kiroku-
  otel` line). Cabal tolerates duplicates but the file becomes confusing.
- Updating `mori.dhall` is text edit; re-running `mori show --full` after a partial
  edit will surface a Dhall parse error rather than silently corrupting state.
- The test suite is hermetic: each test brackets its own ephemeral PostgreSQL via
  `Test.Helpers.withTestStore`, so re-running `cabal test` after a partial failure is
  always safe.

Rollback path: every change introduced by this plan is contained in:

- A new module `kiroku-store/src/Kiroku/Store/Causation.hs`.
- A new test module `kiroku-store/test/Test/Causation.hs`.
- Additions inside `kiroku-store/src/Kiroku/Store/Types.hs`,
  `kiroku-store/src/Kiroku/Store/SQL.hs`, `kiroku-store/src/Kiroku/Store/Effect.hs`,
  `kiroku-store/src/Kiroku/Store.hs`, `kiroku-store/kiroku-store.cabal`,
  `kiroku-store/test/Main.hs`, and `kiroku-store/CHANGELOG.md`.
- A new directory `kiroku-otel/` containing the new package.
- A `cabal.project` `packages:` addition.
- A `mori.dhall` packages/dependencies addition.

To roll back, `git revert` the implementing commits or `git checkout master -- <paths>`
the touched files. No database migration is involved (the schema already has the
required indexes; the recursive CTE is computed at query time without persistent state).


## Interfaces and Dependencies


All paths are repository-relative to
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

### `Kiroku.Store.Types` additions

```haskell
-- Add to the export list:
    EventFilter (..),

-- Add to the body:

{- | Filter passed to the 'Kiroku.Store.Effect.FindEvents' constructor and the
public smart constructors in 'Kiroku.Store.Causation'. Each constructor maps
to one SQL statement in 'Kiroku.Store.SQL'.

The sum is closed: mock interpreters that implement 'Store' can pattern-match
exhaustively. Adding a new filter is a breaking change for downstream
interpreters and is captured by GHC's exhaustiveness check.
-}
data EventFilter
    = -- | Match every event whose @correlation_id@ equals the supplied UUID.
      FilterCorrelation !UUID
    | {- | Match the seed event and every event whose @causation_id@ chain
      walks back to it. The seed event itself is included as the depth-0
      row when it exists.
      -}
      FilterCausationDescendants !EventId
    | {- | Match the seed event and every event reachable by walking
      @causation_id@ upward from the seed. The seed itself is included.
      -}
      FilterCausationAncestors !EventId
    deriving stock (Eq, Show, Generic)
```

### `Kiroku.Store.SQL` additions

```haskell
-- Add to the export list:
    findByCorrelationStmt,
    findCausationDescendantsStmt,
    findCausationAncestorsStmt,

-- Statements (placed at the end of the Read Statements section):

-- | Return every event whose @correlation_id@ equals the input, in
-- @global_position@ order.
findByCorrelationStmt :: Statement UUID (Vector RecordedEvent)
findByCorrelationStmt =
    preparable
        findByCorrelationSQL
        (E.param (E.nonNullable E.uuid))
        (D.rowVector recordedEventRow)

findByCorrelationSQL :: Text
findByCorrelationSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM events e
    JOIN stream_events se
      ON se.event_id = e.event_id AND se.stream_id = 0
    WHERE e.correlation_id = $1
    ORDER BY se.stream_version ASC
    """

-- | Walk the causation graph forward from a seed event, returning the seed
-- itself and every event whose @causation_id@ chain leads back to it. The
-- result is ordered by ascending @global_position@.
findCausationDescendantsStmt :: Statement UUID (Vector RecordedEvent)
findCausationDescendantsStmt =
    preparable
        findCausationDescendantsSQL
        (E.param (E.nonNullable E.uuid))
        (D.rowVector recordedEventRow)

findCausationDescendantsSQL :: Text
findCausationDescendantsSQL =
    """
    WITH RECURSIVE chain (event_id, depth) AS (
        SELECT event_id, 0
        FROM events
        WHERE event_id = $1
      UNION ALL
        SELECT e.event_id, c.depth + 1
        FROM events e
        JOIN chain c ON e.causation_id = c.event_id
    )
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM chain c
    JOIN events e ON e.event_id = c.event_id
    JOIN stream_events se
      ON se.event_id = e.event_id AND se.stream_id = 0
    ORDER BY se.stream_version ASC
    """

-- | Walk the causation graph backward from a seed event, returning the seed
-- itself and every ancestor reachable via @causation_id@. Result is ordered
-- by ascending @depth@ (the seed is depth 0, its immediate cause is depth 1,
-- etc.).
findCausationAncestorsStmt :: Statement UUID (Vector RecordedEvent)
findCausationAncestorsStmt =
    preparable
        findCausationAncestorsSQL
        (E.param (E.nonNullable E.uuid))
        (D.rowVector recordedEventRow)

findCausationAncestorsSQL :: Text
findCausationAncestorsSQL =
    """
    WITH RECURSIVE chain (event_id, depth) AS (
        SELECT event_id, 0
        FROM events
        WHERE event_id = $1
      UNION ALL
        SELECT e.event_id, c.depth + 1
        FROM events e
        JOIN chain c ON c.event_id IN (
            SELECT causation_id FROM events WHERE event_id = c.event_id
        )
        WHERE e.event_id = (SELECT causation_id FROM events WHERE event_id = c.event_id)
          AND e.event_id IS NOT NULL
    )
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM chain c
    JOIN events e ON e.event_id = c.event_id
    JOIN stream_events se
      ON se.event_id = e.event_id AND se.stream_id = 0
    ORDER BY c.depth ASC
    """
```

Implementation note on the ancestor walk: PostgreSQL forbids referencing the
recursive-step CTE more than once in the recursive `SELECT`. The
`findCausationAncestorsSQL` template above uses two scalar subqueries against the
`events` table on each step (one to fetch the parent's `causation_id` and one to confirm
the parent's `event_id`). This compiles and runs but is denser than the descendant walk.
If the test suite or a benchmark reveals planner pathology, replace it with an
equivalent shape that uses a single self-join — the partial index `ix_events_causation_id`
is the limiting factor either way.

### `Kiroku.Store.Effect` additions

```haskell
-- Inside data Store :: Effect where (next to the other read constructors):
    FindEvents :: EventFilter -> Store m (Vector RecordedEvent)

-- Inside runStorePool's interpret_ block:
    FindEvents filt -> case filt of
        FilterCorrelation cid ->
            usePool (store ^. #pool) $
                Session.statement cid SQL.findByCorrelationStmt
        FilterCausationDescendants (EventId eid) ->
            usePool (store ^. #pool) $
                Session.statement eid SQL.findCausationDescendantsStmt
        FilterCausationAncestors (EventId eid) ->
            usePool (store ^. #pool) $
                Session.statement eid SQL.findCausationAncestorsStmt
```

### `Kiroku.Store.Causation` (new module)

```haskell
module Kiroku.Store.Causation (
    findCausationDescendants,
    findCausationAncestors,
    findByCorrelation,
) where

import Data.UUID (UUID)
import Data.Vector (Vector)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Types

{- | Return the seed event and every event whose @causation_id@ chain leads
back to it, in ascending @global_position@ order. The seed event is included
as the depth-0 row when it exists; otherwise the result is empty.

Uses the @ix_events_causation_id@ partial index. Cost is
@O(depth * log n)@ where @depth@ is the length of the longest chain rooted
at the seed and @n@ is the total event count.
-}
findCausationDescendants ::
    (HasCallStack, Store :> es) =>
    EventId ->
    Eff es (Vector RecordedEvent)
findCausationDescendants eid = send (FindEvents (FilterCausationDescendants eid))

{- | Return the seed event and every ancestor reachable via @causation_id@,
in depth-ascending order (the seed is first, its immediate cause is second,
etc.). The seed event is included as the depth-0 row when it exists;
otherwise the result is empty.
-}
findCausationAncestors ::
    (HasCallStack, Store :> es) =>
    EventId ->
    Eff es (Vector RecordedEvent)
findCausationAncestors eid = send (FindEvents (FilterCausationAncestors eid))

{- | Return every event whose @correlation_id@ equals the input, in ascending
@global_position@ order. Uses the @ix_events_correlation_id@ partial index.
-}
findByCorrelation ::
    (HasCallStack, Store :> es) =>
    UUID ->
    Eff es (Vector RecordedEvent)
findByCorrelation cid = send (FindEvents (FilterCorrelation cid))
```

### `kiroku-otel/kiroku-otel.cabal`

```cabal
cabal-version:   3.0
name:            kiroku-otel
version:         0.1.0.0
synopsis:        OpenTelemetry W3C trace-context helpers for Kiroku event metadata
description:
  Pure helpers to inject and extract W3C trace-context (@traceparent@ and
  @tracestate@ header strings, per the W3C trace-context specification)
  into and out of the @metadata@ JSONB column carried by every Kiroku
  event. Provided as a sister package to keep @kiroku-store@ free of any
  @hs-opentelemetry@ dependency; consumers opt in by depending on this
  package directly.
license:         BSD-3-Clause
build-type:      Simple
extra-doc-files: CHANGELOG.md

common common
  default-language:   GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings

  ghc-options:        -Wall

library
  import:          common
  exposed-modules: Kiroku.Otel.TraceContext
  build-depends:
    , aeson                            >=2.1
    , base                             >=4.18  && <5
    , bytestring                       >=0.11
    , hs-opentelemetry-api             >=0.3   && <0.4
    , hs-opentelemetry-propagator-w3c  >=0.1   && <0.2
    , kiroku-store                     >=0.1
    , text                             >=2.0

  hs-source-dirs:  src

test-suite kiroku-otel-test
  import:         common
  type:           exitcode-stdio-1.0
  main-is:        Main.hs
  hs-source-dirs: test
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , aeson
    , base                  >=4.18 && <5
    , bytestring
    , hs-opentelemetry-api
    , hspec                 >=2.10
    , kiroku-otel
    , kiroku-store
    , text
    , time
    , uuid
```

### `kiroku-otel/src/Kiroku/Otel/TraceContext.hs`

```haskell
{- | W3C trace-context helpers that read and write @traceparent@ /
@tracestate@ header strings inside Kiroku event metadata.

The on-the-wire JSON shape inside the event's @metadata@ JSONB column is:

> {
>   "traceparent": "00-<32-hex traceId>-<16-hex spanId>-<2-hex flags>",
>   "tracestate":  "<vendor entries, optional>"
> }

Other keys in @metadata@ are preserved by 'injectTraceContext'.
-}
module Kiroku.Otel.TraceContext (
    injectTraceContext,
    extractTraceContext,
) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.IO (unsafePerformIO)
import Kiroku.Store.Types (EventData (..), RecordedEvent (..))
import OpenTelemetry.Propagator.W3CTraceContext (decodeSpanContext, encodeSpanContext)
import OpenTelemetry.Trace.Core (SpanContext, wrapSpanContext)

{- | Encode a 'SpanContext' as W3C @traceparent@ / @tracestate@ strings and
merge them into the @metadata@ JSON object of an 'EventData'. Existing keys
in @metadata@ are preserved; existing @traceparent@ / @tracestate@ keys (if
any) are overwritten — the W3C spec mandates exactly one of each value per
propagation.

This function is pure: it uses 'unsafePerformIO' to call
'encodeSpanContext', which is observably pure on the frozen span returned
by 'wrapSpanContext' (no shared mutable state, no exceptions). The
\"unsafe\" annotation is mandatory to bridge the propagator's @IO@-typed
encoder to the pure interface this module exposes.
-}
{-# NOINLINE injectTraceContext #-}
injectTraceContext :: SpanContext -> EventData -> EventData
injectTraceContext sc ed =
    let (tp, ts) = unsafePerformIO (encodeSpanContext (wrapSpanContext sc))
        tpText = TE.decodeUtf8 tp
        tsText = TE.decodeUtf8 ts
        newKeys =
            ("traceparent" .= tpText)
                : if T.null tsText then [] else [("tracestate" .= tsText)]
        existing = case ed.metadata of
            Just (Object o) -> o
            Just _other -> KM.empty
            Nothing -> KM.empty
        merged = KM.union (KM.fromList newKeys) existing
     in ed{metadata = Just (Object merged)}

{- | Pull a 'SpanContext' back out of a 'RecordedEvent'\'s @metadata@. Returns
'Nothing' when @metadata@ is absent, is not a JSON object, lacks a
@traceparent@ key, or contains a @traceparent@ value that fails W3C parsing.
Never throws.
-}
extractTraceContext :: RecordedEvent -> Maybe SpanContext
extractTraceContext re = do
    Object o <- re.metadata
    String tpText <- KM.lookup "traceparent" o
    let tpBs :: ByteString
        tpBs = TE.encodeUtf8 tpText
        tsBs = case KM.lookup "tracestate" o of
            Just (String tsText) -> Just (TE.encodeUtf8 tsText)
            _ -> Nothing
    decodeSpanContext (Just tpBs) tsBs
```

### `kiroku-otel/test/Main.hs`

```haskell
module Main where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Kiroku.Otel.TraceContext (extractTraceContext, injectTraceContext)
import Kiroku.Store.Types
import OpenTelemetry.Trace.Core
import OpenTelemetry.Trace.Id
import OpenTelemetry.Trace.TraceState qualified as TS
import Test.Hspec

main :: IO ()
main = hspec $ do
    describe "TraceContext round-trip" $ do
        it "encodes and decodes a SpanContext through metadata" $ do
            let sc = mkTestSpanContext
                ed0 = mkEmptyEventData
                ed1 = injectTraceContext sc ed0
                stub = mkStubRecorded (ed1.metadata)
            case extractTraceContext stub of
                Just sc' -> do
                    traceId sc' `shouldBe` traceId sc
                    spanId sc' `shouldBe` spanId sc
                    traceFlags sc' `shouldBe` traceFlags sc
                Nothing -> expectationFailure "expected Just SpanContext"

        it "preserves existing metadata keys" $ do
            let baseMeta = Aeson.object [("tenant", Aeson.String "acme")]
                ed0 = mkEmptyEventData{metadata = Just baseMeta}
                ed1 = injectTraceContext mkTestSpanContext ed0
            case ed1.metadata of
                Just (Aeson.Object o) -> do
                    KM.lookup "tenant" o `shouldBe` Just (Aeson.String "acme")
                    KM.lookup "traceparent" o `shouldNotBe` Nothing
                _ -> expectationFailure "metadata is not a JSON object"

    describe "extractTraceContext absence handling" $ do
        it "returns Nothing when metadata is absent" $
            extractTraceContext (mkStubRecorded Nothing) `shouldBe` Nothing

        it "returns Nothing when metadata is empty" $
            extractTraceContext (mkStubRecorded (Just (Aeson.object [])))
                `shouldBe` Nothing

        it "returns Nothing when traceparent is unparseable" $
            extractTraceContext
                (mkStubRecorded (Just (Aeson.object [("traceparent", Aeson.String "garbage")])))
                `shouldBe` Nothing

    describe "injectTraceContext overwrites prior trace keys" $ do
        it "replaces an existing traceparent value" $ do
            let preexisting =
                    Aeson.object
                        [ ("traceparent", Aeson.String "00-aaaa-bbbb-00")
                        , ("tenant", Aeson.String "acme")
                        ]
                ed0 = mkEmptyEventData{metadata = Just preexisting}
                ed1 = injectTraceContext mkTestSpanContext ed0
            case ed1.metadata of
                Just (Aeson.Object o) -> do
                    KM.lookup "tenant" o `shouldBe` Just (Aeson.String "acme")
                    KM.lookup "traceparent" o
                        `shouldNotBe` Just (Aeson.String "00-aaaa-bbbb-00")
                _ -> expectationFailure "metadata is not a JSON object"
  where
    mkEmptyEventData =
        EventData
            { eventId = Nothing
            , eventType = EventType (T.pack "X")
            , payload = Aeson.Null
            , metadata = Nothing
            , causationId = Nothing
            , correlationId = Nothing
            }
    mkStubRecorded meta =
        RecordedEvent
            { eventId = EventId UUID.nil
            , eventType = EventType (T.pack "X")
            , streamVersion = StreamVersion 1
            , globalPosition = GlobalPosition 1
            , originalStreamId = StreamId 1
            , originalVersion = StreamVersion 1
            , payload = Aeson.Null
            , metadata = meta
            , causationId = Nothing
            , correlationId = Nothing
            , createdAt = read "2026-05-14 00:00:00 UTC"
            }
    mkTestSpanContext =
        SpanContext
            { traceFlags = traceFlagsFromWord8 0x01
            , isRemote = True
            , traceId = either error id (baseEncodedToTraceId Base16 "4bf92f3577b34da6a3ce929d0e0e4736")
            , spanId = either error id (baseEncodedToSpanId Base16 "00f067aa0ba902b7")
            , traceState = TS.empty
            }
```

The implementer should run `cabal build kiroku-otel:lib:kiroku-otel --dry-run -v` to see
the exact module-export shape of `OpenTelemetry.Trace.Core`,
`OpenTelemetry.Trace.Id`, and `OpenTelemetry.Trace.TraceState` at the pinned commit and
adjust the imports if the upstream API has drifted. The plan's pin commit
(`adc464b0a45e56a983fa1441be6e432b50c29e0e`) was the same one that built cleanly for
shibuya-core at the time this plan was written; any drift between then and the
implementation date should be addressed by adjusting imports, not by bumping the pin (the
pin bump risks the version-skew hazard called out in the Decision Log).

### Library dependencies summary

This plan does not alter `kiroku-store`'s `build-depends`. It adds one new package
(`kiroku-otel`) whose dependencies are limited to:

- `aeson` (already in `kiroku-store`)
- `base`, `bytestring`, `text` (transitive everywhere)
- `kiroku-store >= 0.1` (the package this plan extends)
- `hs-opentelemetry-api >= 0.3 && < 0.4`
- `hs-opentelemetry-propagator-w3c >= 0.1 && < 0.2`

The two `hs-opentelemetry-*` dependencies are resolved against the existing
`source-repository-package` blocks in `cabal.project`; no new pin is introduced.
