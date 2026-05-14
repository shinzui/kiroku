---
id: 12
slug: streamly-shaped-single-stream-forward-read
title: "Streamly-shaped single-stream forward read"
kind: exec-plan
created_at: 2026-05-14T03:13:45Z
intention: "intention_01krj7a4m1ev9vjmza6ywpv0qq"
---

# Streamly-shaped single-stream forward read


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture


Today, the public surface for reading a single stream's events forward is one function in
`kiroku-store/src/Kiroku/Store/Read.hs`:

```haskell
readStreamForward ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    StreamVersion ->
    Int32 ->
    Eff es (Vector RecordedEvent)
```

`StreamName` is a human-readable stream identifier (e.g. `StreamName "orders-1"`).
`StreamVersion` is a monotonically-increasing per-stream counter starting at `0` for an
empty stream; the cursor is *exclusive*, so passing `StreamVersion 0` reads from the very
first event and passing `StreamVersion n` returns events at versions `n + 1, n + 2, …`. The
`Int32` is the per-call batch limit. `RecordedEvent` is the read shape of an event, defined
in `Kiroku.Store.Types`; it carries `eventId`, `eventType`, payload, `streamVersion`,
`globalPosition`, and so on. `Eff es` is the `effectful` library's effect monad; `Store :>
es` constrains the effect row to provide the `Store` event-store effect (declared in
`kiroku-store/src/Kiroku/Store/Effect.hs`). `Vector` is `Data.Vector.Vector`.

The shape of that return — a `Vector` — forces every caller that wants to fold a long
stream in constant memory to wrap the call in a streaming combinator and paginate by hand.
The downstream consumer driving this need is `keiro`, a sister project at
`/Users/shinzui/Keikaku/bokuno/keiro` whose research note
`docs/research/06-command-cycle-design.md` §5 ("Hydration phase") shows the exact wrapper
every `keiro` consumer needs:

```haskell
hydrationStream ::
    (Store :> es, Error StoreError :> es) =>
    StreamName -> Int32 -> Stream (Eff es) RecordedEvent
hydrationStream sn pageSize =
    Stream.concatMap (Stream.fromList . V.toList) pages
  where
    pages = Stream.unfoldrM nextPage (StreamVersion 0)
    nextPage cursor = do
        events <- readStreamForward sn cursor pageSize
        if V.null events
            then pure Nothing
            else
                let lastV = (V.last events).streamVersion
                in pure (Just (events, lastV))
```

That wrapper is a few dozen lines, and it duplicates machinery that `kiroku-store` already
ships in a different shape: the live-subscription bridge
`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` exposes
`subscriptionStream :: KirokuStore -> SubscriptionConfig -> Natural -> IO (Stream IO
RecordedEvent, IO ())`, a Streamly stream sourced from the push-based subscription handler.
The missing piece is the analogous shape for *non-subscription, single-stream forward*
reads.

`keiro`'s parent MasterPlan, `docs/masterplans/1-keiro-research-foundation.md`, has an
Integration Point called "Streamly substrate" that names `streamly` as the canonical
in-process streaming substrate for keiro and every dependency it consumes (`shibuya`,
`kiroku-store`'s subscription bridge, and now keiro's own hydration / projection / process-
manager loops). Lifting the wrapper upstream into `kiroku-store` removes it from every
keiro call site and makes the streaming shape of single-stream reads consistent with
`Subscription.Stream`.

**User-visible behavior after this change.** A new function

```haskell
readStreamForwardStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    StreamVersion ->     -- exclusive cursor; pass StreamVersion 0 to read from the beginning
    Int32 ->             -- page size; callers should pass 256 unless they have a reason not to
    Stream (Eff es) RecordedEvent
```

is exported from `Kiroku.Store.Read` and re-exported from `Kiroku.Store`. `Stream (Eff es)
RecordedEvent` is `Streamly.Data.Stream.Stream (Eff es) RecordedEvent` — a pull-based
Streamly stream whose actions live in the `effectful` `Eff` monad. The function returns
*identically the same events in the same order* as `readStreamForward name startVer N`
would, where `N` is "however many events fit in the stream", but it does so without
materializing them as a `Vector`: a caller folding the stream sees one `RecordedEvent` at a
time, with paging back to PostgreSQL happening transparently every `pageSize` events.

The user can prove the change works by running the kiroku-store test suite from
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/`:

```bash
cabal test kiroku-store:kiroku-store-test
```

and observing the new `describe "readStreamForwardStream"` group pass. Specifically: a
test that appends 1,000 events at versions 1..1000 to a stream, folds the stream with
`Streamly.Data.Fold.length`, and asserts the resulting count is `1000` — exercising at
least four internal pages at the spec-default 256 page size. A second test compares
`Stream.toList (readStreamForwardStream …) == V.toList <$> readStreamForward …` for a
shorter stream where the entire content fits in one page; the two paths must agree byte
for byte. A third test asserts behaviour on an empty / nonexistent stream: the stream
terminates immediately with zero events emitted, just like `readStreamForward` returns an
empty vector today.

The behavioral guarantee this plan signs up for: `readStreamForwardStream` shares a single
SQL path and a single set of error semantics with `readStreamForward`. The streaming
function is implemented in terms of repeated `Store` effect dispatches to the existing
`ReadStreamForward` constructor; it does not add a new SQL statement, a new effect
constructor, or a new error variant.


## Progress


Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Library: add `readStreamForwardStream` to `Kiroku.Store.Read`.

- [x] Add the import of `Streamly.Data.Stream` (aliased as `Stream`) to
      `kiroku-store/src/Kiroku/Store/Read.hs`. The library already depends on
      `streamly-core >= 0.3` (see `kiroku-store/kiroku-store.cabal:58`); no new dependency
      is required for the library target. — 2026-05-13
- [x] Add `readStreamForwardStream` to the export list of `Kiroku.Store.Read`. — 2026-05-13
- [x] Implement `readStreamForwardStream :: (HasCallStack, Store :> es) => StreamName ->
      StreamVersion -> Int32 -> Stream (Eff es) RecordedEvent` as a `Stream.unfoldrM` over
      pages of `readStreamForward`. The unfold's state is the current `StreamVersion`
      cursor (exclusive); each step calls `readStreamForward name cursor pageSize`, yields
      the page, and advances the cursor to the last event's `streamVersion`. When the
      page comes back empty the unfold terminates. — 2026-05-13
- [x] Add Haddock for the new function naming the cursor semantics, page-size guidance
      (256 default, larger for hot streams, smaller for very wide events), and explicit
      cross-reference to `readStreamForward` for the SQL- and error-semantics parity.
      — 2026-05-13
- [x] Confirm the function is re-exported by `Kiroku.Store` (no edit required: `Kiroku.Store`
      already does `module Kiroku.Store.Read` re-export at
      `kiroku-store/src/Kiroku/Store.hs:19`). — 2026-05-13
- [x] Build the library target: `cabal build kiroku-store:lib:kiroku-store` from the
      repository root. Expect a clean build with no new warnings. — 2026-05-13 (clean
      compile of all 21 modules, no new warnings)

Milestone 2 — Tests: validate identity-with-Vector and multi-page hydration.

- [ ] Add `streamly-core >= 0.3` to the `test-suite kiroku-store-test` `build-depends`
      stanza in `kiroku-store/kiroku-store.cabal`. The test suite does not currently link
      against `streamly-core` (only the library target does).
- [ ] Add a new test module `kiroku-store/test/Test/ReadStream.hs` housing the
      `readStreamForwardStream` Hspec group. Wire it into the `other-modules` list of
      `test-suite kiroku-store-test` in `kiroku-store/kiroku-store.cabal` and import it
      from `kiroku-store/test/Main.hs`.
- [ ] Test "identity with `readStreamForward` on a single-page stream": append 5 events
      to a fresh stream, call `Stream.toList (readStreamForwardStream name (StreamVersion
      0) 256)` and compare it with `V.toList <$> readStreamForward name (StreamVersion 0)
      256`. The two lists must compare equal element-by-element.
- [ ] Test "multi-page hydration in constant memory shape": append 1,000 events to a
      fresh stream (in batches small enough not to time out the test), then fold
      `readStreamForwardStream` with `Streamly.Data.Fold.length` at `pageSize = 256`. The
      fold must return `1000`. The test also checks that the *first* and *last* events'
      `streamVersion` and `eventType` match expectations, proving order is preserved
      across page boundaries.
- [ ] Test "page-boundary cursor invariant": with 5 events in the stream and `pageSize =
      2`, fold the stream collecting the `streamVersion` of each event into a list. Expect
      `[StreamVersion 1, StreamVersion 2, StreamVersion 3, StreamVersion 4, StreamVersion
      5]` — no duplicates, no gaps, in order. This proves the cursor advance between
      pages is correct.
- [ ] Test "empty / nonexistent stream": call `readStreamForwardStream` on a stream that
      was never created; the resulting stream must terminate immediately with zero
      elements emitted (mirroring `readStreamForward`'s `V.length result == 0`
      behaviour).
- [ ] Test "non-zero start cursor": append 5 events; call `readStreamForwardStream name
      (StreamVersion 2) 256` and assert that exactly 3 events come back, with
      `streamVersion` values `[3, 4, 5]`. Confirms cursor exclusivity is preserved by the
      streaming wrapper.
- [ ] Run the full test suite from the repository root: `cabal test
      kiroku-store:kiroku-store-test`. Expect every test (the prior suite plus the new
      `readStreamForwardStream` group) to pass.

Milestone 3 — Documentation and changelog.

- [ ] Add a new entry under `## Unreleased` in `kiroku-store/CHANGELOG.md` describing
      `readStreamForwardStream` and citing the rationale (Streamly substrate Integration
      Point) without leaking keiro-internal vocabulary into the public changelog.
- [ ] Run the targeted library + test build one final time from the repository root to
      confirm everything still links and tests pass:

      ```bash
      cabal build kiroku-store:lib:kiroku-store
      cabal test kiroku-store:kiroku-store-test
      ```


## Surprises & Discoveries


Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log


- Decision: Implement `readStreamForwardStream` as a thin wrapper that calls the existing
  `readStreamForward` repeatedly, rather than introducing a new `Store` effect
  constructor or a new `SQL.readStreamForwardStreamStmt`.
  Rationale: the user's explicit design constraint is that the new function must use the
  same per-page batched read `kiroku-store` already implements, so the Vector-returning
  `readStreamForward` and the Stream-returning `readStreamForwardStream` share a single
  SQL path and a single set of error semantics. Calling the existing effect dispatch is
  the only implementation that satisfies that constraint by construction: any failure
  mode of the underlying read (e.g. `ConnectionError`, future cancellation surfaces)
  flows through unchanged, and the SQL `recordedEventRow` decoder used by
  `SQL.readStreamForwardStmt` is exercised verbatim. A separate `Store`-effect
  constructor for streaming would either fork the SQL path (defeating the constraint) or
  reduce to the same wrapper internally (pointless ceremony plus a constructor that mock
  interpreters must learn to reject).
  Date: 2026-05-14

- Decision: Make page size a required `Int32` parameter on `readStreamForwardStream`
  rather than expose two functions (one with a hard-coded 256 default, one configurable),
  or accept a record-of-options.
  Rationale: the existing `readStreamForward` already takes the per-call batch size as an
  explicit `Int32 -> ` positional argument with no default; matching that style keeps the
  two functions visually parallel and keeps the diff small. The 256 default lives in the
  Haddock as a recommendation rather than in the type. A future "convenience wrapper
  that defaults to 256" can be added cheaply if user feedback asks for it.
  Date: 2026-05-14

- Decision: Constrain `readStreamForwardStream` with `(HasCallStack, Store :> es)`,
  matching `readStreamForward`'s existing constraint set, rather than the larger
  `(Store :> es, Error StoreError :> es)` the original problem statement sketched.
  Rationale: `Error StoreError :> es` is required *by the interpreter*
  (`Kiroku.Store.Effect.runStorePool`) and is therefore satisfied at every realistic call
  site that actually executes the stream — but the constraint is not required by the
  function itself, which contains no `throwError`. Keeping the constraint set identical
  to `readStreamForward`'s preserves the "this is the streaming sibling, nothing more"
  framing and avoids a needless inconsistency between the two read functions.
  Date: 2026-05-14

- Decision: Restrict the scope of this ExecPlan to the *forward single-stream* shape only.
  `readStreamBackward`, `readAllForward`, `readAllBackward`, and `readCategory` are not
  given Stream-returning siblings in this plan.
  Rationale: the keiro consumer that motivates this plan needs only the forward single-
  stream shape — its hydration phase folds source events from version 0 upward into
  aggregate state. The other read directions have legitimate streaming use cases (e.g.
  catch-up over `readAllForward`, category fan-in over `readCategory`), but they are not
  blocking keiro v1 and they would each warrant their own targeted test coverage. Doing
  them speculatively here would expand the diff for no immediate consumer. They become
  cheap follow-ups once this plan ships: each is a near-identical wrapper over its
  corresponding `Vector`-returning sibling.
  Date: 2026-05-14

- Decision: Place `readStreamForwardStream` in `Kiroku.Store.Read` next to
  `readStreamForward`, rather than in a new `Kiroku.Store.Read.Stream` module or in
  `Kiroku.Store.Subscription.Stream`.
  Rationale: a separate `Read.Stream` module would split a function from its non-streaming
  sibling on a packaging boundary, making the "they share SQL and error semantics"
  guarantee less discoverable. Placing it in `Subscription.Stream` is wrong on type
  grounds — that module's `subscriptionStream` is `IO`-flavored (it owns a `TBQueue`
  bridging a push-based handler) and is parameterised by `KirokuStore`, not the `Store`
  effect. The streaming forward read is a pull-shaped wrapper over the abstract `Store`
  effect and belongs with the function it wraps.
  Date: 2026-05-14


## Outcomes & Retrospective


Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation


The repository root used throughout this plan is
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. All commands shown here assume that
working directory unless noted. The repository is a Cabal multi-package project: the
package this plan touches is `kiroku-store` (sources under `kiroku-store/src/`, tests under
`kiroku-store/test/`).

The libraries to know about, with full paths, are:

- `kiroku-store/src/Kiroku/Store/Read.hs` — the module that exports `readStreamForward`
  today and to which `readStreamForwardStream` will be added.
- `kiroku-store/src/Kiroku/Store/Effect.hs` — declares the abstract `Store` effect (an
  `effectful` `Effect`) and its interpreter `runStorePool`. The `Store` constructor used
  by both the existing `readStreamForward` and the new streaming function is
  `ReadStreamForward :: StreamName -> StreamVersion -> Int32 -> Store m (Vector
  RecordedEvent)`.
- `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` — the existing
  `subscriptionStream` function that demonstrates how Streamly is used inside
  `kiroku-store`. The new function follows the same import pattern (`import
  Streamly.Data.Stream (Stream); import Streamly.Data.Stream qualified as Stream`) and
  uses the same `Stream.unfoldrM` primitive, although for a pull source rather than a
  TBQueue-fed push source.
- `kiroku-store/src/Kiroku/Store/Types.hs` — defines `StreamName`, `StreamVersion`,
  `RecordedEvent`. No edits here.
- `kiroku-store/src/Kiroku/Store.hs` — the top-level re-export module. It already does
  `module Kiroku.Store.Read` so the new function will be re-exported automatically.
- `kiroku-store/kiroku-store.cabal` — the package descriptor. The library target already
  lists `streamly-core >= 0.3`. The test target does *not* depend on `streamly-core`
  today; this plan adds the dependency to the test target so the new test module can
  consume `Streamly.Data.Stream` and `Streamly.Data.Fold`.
- `kiroku-store/test/Main.hs` — the Hspec test entry point. It imports topic-specific
  test modules (`Test.Properties`, `Test.Concurrency`, `Test.FailureInjection`,
  `Test.Transaction`, and `Test.Helpers`) and composes them into one suite. The new
  module `Test.ReadStream` is wired in alongside these.
- `kiroku-store/test/Test/Helpers.hs` — exports `withTestStore` (an ephemeral-PG-backed
  fixture used with Hspec's `around`) and `makeEvent` (a convenience builder for
  `EventData`). The new tests reuse both.

Terms of art used below, in plain language:

- **`Stream m a`** (from `streamly-core`'s `Streamly.Data.Stream`): a pull-based stream
  of `a` values whose stepping actions run in the monad `m`. Conceptually it is a
  recursive `m (Maybe (a, Stream m a))`; in practice the library hides that under
  combinators like `unfoldrM`, `concatMap`, `fold`. A `Stream m a` consumed by a `Fold m
  a b` runs in constant memory regardless of stream length — that is exactly the
  property keiro's hydration phase relies on.
- **`Stream.unfoldrM :: Monad m => (s -> m (Maybe (a, s))) -> s -> Stream m a`** — the
  standard "build a stream from a stateful generator" primitive. Each step takes the
  current state, runs an `m` action, and either yields one `a` plus the next state or
  signals end-of-stream by returning `Nothing`.
- **`effectful`** (`Effectful.*`): the effect-system library kiroku-store uses. `Eff es a`
  is the underlying monad; `es` is a type-level row of effect constraints. `Store :> es`
  says "the `Store` effect is in the row"; calling `readStreamForward` requires this.
- **Cursor exclusivity** — `readStreamForward name (StreamVersion v) limit` returns
  events with `streamVersion > v`. The first call passes `StreamVersion 0` to start at
  the very first event; subsequent calls pass the highest `streamVersion` seen so far.
  The streaming wrapper preserves this convention end-to-end.
- **EP-1 hydration / `hydrationStream`** — names used in keiro's research notes for the
  Streamly wrapper this plan promotes upstream. `EP-1` is keiro's command-cycle ExecPlan
  at `/Users/shinzui/Keikaku/bokuno/keiro/docs/plans/1-command-cycle-design-and-spike.md`;
  `hydrationStream` is the function shown verbatim in the Purpose section above.
- **Streamly substrate Integration Point** — a section of keiro's parent MasterPlan
  (`/Users/shinzui/Keikaku/bokuno/keiro/docs/masterplans/1-keiro-research-foundation.md`,
  "Integration Points") that fixes Streamly's `Stream` and `Fold` types as the canonical
  in-process streaming substrate for keiro and the components it consumes. This plan is
  one of the consequences of that decision.

What this plan does *not* touch: the SQL layer (`kiroku-store/src/Kiroku/Store/SQL.hs`),
the schema (`kiroku-store/sql/schema.sql`), the `Store` effect declaration or
interpreter, any error type, the public subscription surface, or the multi-stream /
append surface. All of those are left as-is. The single SQL path that
`readStreamForwardStream` exercises is the existing `SQL.readStreamForwardStmt` reached
through the existing `ReadStreamForward` effect constructor; this is precisely the
property the design constraint requires.


## Plan of Work


The work is three milestones long. Each milestone is independently verifiable.

**Milestone 1 — library function.** The scope is to add the new function, export it from
its module, and confirm `Kiroku.Store`'s aggregate re-export picks it up. At the end of
this milestone, `cabal build kiroku-store:lib:kiroku-store` succeeds and
`readStreamForwardStream` is visible to consumers who `import Kiroku.Store` or `import
Kiroku.Store.Read`.

Edits in `kiroku-store/src/Kiroku/Store/Read.hs`:

1. Add to the module export list, right after `readStreamForward`:

   ```haskell
       readStreamForwardStream,
   ```

2. Add the following imports below the existing import block:

   ```haskell
   import Control.Lens ((^.))
   import Data.Generics.Labels ()
   import Data.Vector qualified as V
   import Streamly.Data.Stream (Stream)
   import Streamly.Data.Stream qualified as Stream
   ```

   The `OverloadedLabels` and `DuplicateRecordFields` extensions are already enabled
   globally for the package via the `common common` stanza in
   `kiroku-store/kiroku-store.cabal`; `^. #streamVersion` therefore works without
   additional pragmas.

3. Add the function immediately below `readStreamForward`'s definition:

   ```haskell
   {- | Forward read a single stream as a constant-memory Streamly 'Stream'.

   The streaming sibling of 'readStreamForward'. Identical SQL path and identical
   error semantics: this function dispatches 'readStreamForward' repeatedly with
   the supplied @pageSize@ as the per-call limit, advancing the exclusive
   'StreamVersion' cursor across pages until the next call returns an empty
   batch.

   The exclusive-cursor convention is preserved end-to-end: passing
   @'StreamVersion' 0@ reads from the first event in the stream. Empty and
   nonexistent streams terminate the stream immediately with zero elements.

   The recommended @pageSize@ is @256@. Callers reading very wide events (large
   payloads / metadata) should pass a smaller value to keep per-page memory
   bounded; callers reading very long streams of small events may pass a larger
   value to reduce round-trip count.
   -}
   readStreamForwardStream ::
       (HasCallStack, Store :> es) =>
       StreamName ->
       StreamVersion ->
       Int32 ->
       Stream (Eff es) RecordedEvent
   readStreamForwardStream name startVer pageSize =
       Stream.concatMap (Stream.fromList . V.toList) pages
     where
       pages = Stream.unfoldrM nextPage startVer
       nextPage cursor = do
           events <- readStreamForward name cursor pageSize
           if V.null events
               then pure Nothing
               else
                   let lastV = V.last events ^. #streamVersion
                   in pure (Just (events, lastV))
   ```

The wrapper paginates per-page by yielding each page-vector as a `Stream m (Vector
RecordedEvent)` and then `concatMap`-ping each vector into its element stream. The state
threaded through `Stream.unfoldrM` is the current `StreamVersion` cursor; the next page's
cursor is the `streamVersion` of the last event in the page just returned (preserving the
exclusive convention because `readStreamForward` returns events with `streamVersion >
cursor`).

Acceptance for Milestone 1 is a clean `cabal build kiroku-store:lib:kiroku-store` plus a
quick `cabal repl kiroku-store:lib:kiroku-store` sanity check that the symbol is in
scope:

```text
λ> :type readStreamForwardStream
readStreamForwardStream
  :: (HasCallStack, Store :> es) =>
     StreamName
     -> StreamVersion
     -> Int32
     -> Stream (Eff es) RecordedEvent
```

**Milestone 2 — tests.** The scope is to prove the streaming function is identical in
output to `readStreamForward` for the cases that fit in one page, and to prove it
preserves order, exclusivity, and totality across multiple pages. The test file is new and
isolated, so failures cannot mask regressions in unrelated test groups.

Edits:

1. In `kiroku-store/kiroku-store.cabal`, add `streamly-core >= 0.3` to the
   `test-suite kiroku-store-test`'s `build-depends` stanza (alphabetical order, between
   `stm` and `text`). Add `Test.ReadStream` to the `other-modules` list for the same
   target.

2. Create `kiroku-store/test/Test/ReadStream.hs` with the following structure:

   ```haskell
   module Test.ReadStream (spec) where

   import Control.Lens ((^.))
   import Data.Aeson qualified as Aeson
   import Data.Generics.Labels ()
   import Data.Text qualified as T
   import Data.Vector qualified as V
   import Kiroku.Store
   import Streamly.Data.Fold qualified as Fold
   import Streamly.Data.Stream qualified as Stream
   import Test.Helpers
   import Test.Hspec

   spec :: Spec
   spec = around withTestStore $
       describe "readStreamForwardStream" $ do
           -- five tests detailed in the Progress section
           ...
   ```

   Each test follows the same idiom used elsewhere in `kiroku-store/test/Main.hs`:
   `runStoreIO store $ <stream action>`, then assert on the resulting list /
   `StreamVersion` / `EventType`. The streaming counterpart materializes a result list
   with `runStoreIO store $ Stream.toList $ readStreamForwardStream …` or computes a
   summary with `runStoreIO store $ Stream.fold Fold.length $ readStreamForwardStream …`.

3. In `kiroku-store/test/Main.hs`, add the import `import Test.ReadStream qualified as
   ReadStream` near the existing `import Test.Transaction qualified as Transaction` line,
   and call `ReadStream.spec` inside `main = hspec $ do` alongside the other top-level
   `spec` invocations (the order is not load-bearing; place it after `Transaction.spec`).

Acceptance for Milestone 2 is `cabal test kiroku-store:kiroku-store-test` ending with
`0 failures`. The Hspec report should show the five new `readStreamForwardStream`
examples in addition to the prior suite. Approximate expected count: 110 examples (the
current suite is 105 per the closing note in
`docs/plans/11-single-stream-runtransaction-combinator.md`).

**Milestone 3 — changelog and final verification.** The scope is a public-facing
description of the new function and a final end-to-end build / test pass.

Edits:

1. In `kiroku-store/CHANGELOG.md`, add a section under `## Unreleased`. Keep the section
   short and audience-neutral (the changelog is read by adopters who do not know about
   keiro):

   ```markdown
   ### Added — streaming single-stream forward read

   * `Kiroku.Store.Read.readStreamForwardStream` (re-exported from `Kiroku.Store`):
     a Streamly `Stream (Eff es) RecordedEvent` companion to `readStreamForward`.
     Internally paginates `readStreamForward` at a caller-supplied page size and
     yields events one at a time, enabling constant-memory folds over long
     streams. Shares SQL path and error semantics with `readStreamForward`.
   ```

2. Final build and test pass:

   ```bash
   cabal build kiroku-store:lib:kiroku-store
   cabal test kiroku-store:kiroku-store-test
   ```


## Concrete Steps


All commands below assume the working directory
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/`.

Initial sanity check that the toolchain is wired up. The flake-provided environment is
already on `PATH` in the repository (see `flake.nix`); these commands assume the user is
inside `nix develop` or equivalent.

```bash
cabal build kiroku-store:lib:kiroku-store
```

Expect a clean build (the line `Up to date.` or a normal compile-and-link sequence
ending in `[N of N] Compiling …` with no warnings).

```bash
cabal test kiroku-store:kiroku-store-test
```

Expect the existing suite to pass (`Finished in … seconds; 105 examples, 0 failures.`
approximately — exact count varies as the suite evolves).

Milestone 1 edits, then re-verify:

```bash
cabal build kiroku-store:lib:kiroku-store
```

Expect a clean compile of `Kiroku.Store.Read`. The new import block on
`kiroku-store/src/Kiroku/Store/Read.hs` should not introduce orphan-instance warnings or
unused-import warnings (the import of `Data.Generics.Labels ()` is the orphan-instance
provider required by `OverloadedLabels`-driven field accessors).

Milestone 2 edits, then run the test target:

```bash
cabal test kiroku-store:kiroku-store-test
```

Expect output ending with `Finished in … seconds; 110 examples, 0 failures.` (give or
take a few examples depending on the exact number added — the key signal is `0 failures`).

Milestone 3 edits, then the final full verification:

```bash
cabal build kiroku-store:lib:kiroku-store
cabal test kiroku-store:kiroku-store-test
```

Both must succeed cleanly.


## Validation and Acceptance


The change is accepted when *all* of the following are observably true.

1. `Kiroku.Store.Read.readStreamForwardStream` exists and has the exact type
   `(HasCallStack, Store :> es) => StreamName -> StreamVersion -> Int32 -> Stream (Eff
   es) RecordedEvent`. This can be confirmed via `cabal repl kiroku-store:lib:kiroku-store`
   and `:type readStreamForwardStream` returning the signature shown in Milestone 1.

2. The function is re-exported from `Kiroku.Store` without an explicit re-export edit
   (relying on the existing `module Kiroku.Store.Read` clause at
   `kiroku-store/src/Kiroku/Store.hs:19`). A `cabal repl kiroku-store:lib:kiroku-store`
   session and `:type Kiroku.Store.readStreamForwardStream` returning the same signature
   confirms this.

3. The new Hspec group `readStreamForwardStream` in `Test.ReadStream` shows five passing
   examples in the test output:

   - reads the same events `readStreamForward` does on a single-page stream
   - folds 1,000 events end-to-end via `Streamly.Data.Fold.length`
   - preserves order and avoids duplicates / gaps when paging at `pageSize = 2`
   - terminates immediately on a nonexistent stream
   - honors a non-zero starting cursor with exclusivity

   The final Hspec summary line shows `0 failures`.

4. The change shares the SQL path and the error semantics of `readStreamForward`. The
   demonstration of this is structural: the implementation in
   `kiroku-store/src/Kiroku/Store/Read.hs` calls `readStreamForward` and no other read
   primitive, so any error that path raises (`StoreError` constructors handled by
   `runStorePool` in `Kiroku.Store.Effect`) is what the stream consumer sees when folding,
   and the SQL statement issued per page is `SQL.readStreamForwardStmt`. A reviewer
   inspecting the diff can verify this by reading the new function body in isolation:
   the only `Store`-effect call is to `readStreamForward`.

5. `cabal build kiroku-store:lib:kiroku-store` and `cabal test
   kiroku-store:kiroku-store-test` both succeed from the repository root, with no new
   GHC warnings introduced.


## Idempotence and Recovery


Every command in this plan is safe to repeat: `cabal build` and `cabal test` are
idempotent (cabal caches build products under `dist-newstyle/` and re-uses them); edits
to `Kiroku.Store.Read`, the cabal file, and the new `Test/ReadStream.hs` are file
overwrites that produce the same final state on each run.

If a step fails partway:

- *Build failure after Milestone 1 edit.* The most likely cause is a missing or
  misordered import (e.g. forgetting `import Data.Generics.Labels ()` for the
  `OverloadedLabels` accessors, or forgetting the qualified `import Streamly.Data.Stream
  qualified as Stream`). Re-read the file diff against the Plan of Work block in
  Milestone 1 and add the missing imports.

- *Test failure on the multi-page test.* The most likely cause is an off-by-one in the
  `nextPage` cursor advance — for example, advancing the cursor to `V.head events ^.
  #streamVersion` instead of `V.last events ^. #streamVersion`. The fix is mechanical;
  re-check the function body against the snippet in Milestone 1.

- *Test failure on the "non-zero start cursor" test.* This indicates the wrapper is
  ignoring the supplied `startVer` and always starting from `StreamVersion 0`. Check
  that `Stream.unfoldrM nextPage startVer` is used (with `startVer`, not a literal
  `StreamVersion 0`).

The plan does not touch SQL, schema, or any migration; there is nothing to roll back at
the database layer. A complete rollback is `git restore` on the four touched files
(`Kiroku/Store/Read.hs`, `kiroku-store.cabal`, `test/Main.hs`, `test/Test/ReadStream.hs`)
plus `git restore` on `CHANGELOG.md`.


## Interfaces and Dependencies


Libraries:

- `streamly-core` (>= 0.3). Already a `library` build-depend of `kiroku-store`. This
  plan adds it as a `test-suite kiroku-store-test` build-depend so the new test module
  can import `Streamly.Data.Stream` and `Streamly.Data.Fold`.
- `effectful-core` (>= 2.4). Already a build-depend on both targets; no change.
- `vector` (>= 0.13). Already a build-depend on both targets; no change.
- `lens` (>= 5.2) and `generic-lens` (>= 2.2). Already build-depends; provide the
  `(^.) :: s -> Getting a s a -> a` accessor and the `OverloadedLabels`-derived field
  optics used to extract `streamVersion` from a `RecordedEvent`.

Modules added or edited (full repository-relative paths):

- `kiroku-store/src/Kiroku/Store/Read.hs` — adds the `readStreamForwardStream` export
  and definition.
- `kiroku-store/kiroku-store.cabal` — adds `streamly-core` to the test target's
  `build-depends`, and `Test.ReadStream` to the test target's `other-modules`.
- `kiroku-store/test/Test/ReadStream.hs` — new module containing the Hspec group for the
  new function.
- `kiroku-store/test/Main.hs` — imports `Test.ReadStream` and calls its `spec` inside
  `main`.
- `kiroku-store/CHANGELOG.md` — adds a `### Added — streaming single-stream forward
  read` section under `## Unreleased`.

Public interface at the end of Milestone 1 (full type signature):

```haskell
readStreamForwardStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    StreamVersion ->
    Int32 ->
    Stream (Eff es) RecordedEvent
```

`StreamName`, `StreamVersion`, `RecordedEvent`, and `Store` come from `Kiroku.Store`
(transitively from `Kiroku.Store.Types` and `Kiroku.Store.Effect`). `Stream` comes from
`Streamly.Data.Stream` (re-exported from `streamly-core`). `Eff` and `(:>)` come from
`Effectful` (`effectful-core`). `Int32` comes from `Data.Int` (`base`). `HasCallStack`
comes from `GHC.Stack` (`base`).

No new types, no new effect constructors, no new error variants, no new SQL statements.
The wrapper is implemented entirely on top of the existing `readStreamForward` and the
existing `Store` effect surface.
