---
id: 15
slug: expose-lookupstreamid-combinator-on-kiroku-store-read
title: "Expose lookupStreamId combinator on Kiroku.Store.Read"
kind: exec-plan
created_at: 2026-05-14T03:23:52Z
intention: "intention_01krj80vf4epcrsegk3d3ptjmr"
---

# Expose lookupStreamId combinator on Kiroku.Store.Read

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today `kiroku-store` exposes one public way to map a human-readable `StreamName` to its
database surrogate `StreamId`: `Kiroku.Store.Read.getStream`, defined at
`kiroku-store/src/Kiroku/Store/Read.hs:145`. That function returns `Maybe StreamInfo`,
which packs five columns — `id`, `name`, `version`, `createdAt`, `deletedAt` — and the
caller decodes the whole row even when the only field it needs is `id`. Internally
`Kiroku.Store.SQL.findStreamIdStmt` (`kiroku-store/src/Kiroku/Store/SQL.hs:654`) already
does the cheap single-column lookup the hard-delete path needs, but it is not part of the
public surface: `Kiroku.Store.SQL` is listed under `other-modules` in
`kiroku-store/kiroku-store.cabal:40`, not `exposed-modules`.

After this change, callers of `kiroku-store` will be able to write

```haskell
lookupStreamId :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
```

— a public combinator on `Kiroku.Store.Read` that returns `Just sid` for any stream whose
row currently exists (live *or* soft-deleted, matching the semantics of `getStream`),
`Nothing` for streams that have never been created or have been hard-deleted, and pays for
exactly one `int8` decode per row instead of five.

You can see it working in two ways. First, a new unit test in
`kiroku-store/test/Main.hs` will assert that `lookupStreamId` returns the same `StreamId`
that `getStream` reports — proving the new path is consistent with the established one —
and that it returns `Nothing` for a stream that was never created. Second, the
`shinzui/keiro` framework (a downstream consumer at `/Users/shinzui/Keikaku/bokuno/keiro`)
documents this combinator as an optional optimization in its upstream-roadmap (`§4.9` of
`docs/research/11-upstream-roadmap.md`) for its snapshot read/write path, which is keyed
on `stream_id`; once this plan lands, that optimization becomes available without keiro
having to either decode a five-column row or inline its own `SELECT stream_id FROM streams
WHERE stream_name = $1`.


## Progress

- [x] Add the `LookupStreamId :: StreamName -> Store m (Maybe StreamId)` constructor to the
  `Store` effect (`kiroku-store/src/Kiroku/Store/Effect.hs`), and extend the
  `runStorePool` interpreter to dispatch it to `SQL.findStreamIdStmt`. (2026-05-13)
- [x] Add the public `lookupStreamId` combinator to `Kiroku.Store.Read`
  (`kiroku-store/src/Kiroku/Store/Read.hs`) and include it in the module export list.
  (2026-05-13)
- [x] Confirm `cabal build kiroku-store` succeeds and that the `Kiroku.Store` umbrella
  module (`kiroku-store/src/Kiroku/Store.hs`) automatically re-exports the new symbol via
  `module Kiroku.Store.Read`. The library and the test executable both linked cleanly; an
  unrelated pre-existing breakage in `bench/ShibuyaOverhead.hs` (the `Envelope` constructor
  is missing a strict `attributes` field) blocks `cabal build kiroku-store` as a whole but
  is out of scope for this plan — see Surprises & Discoveries. (2026-05-13)
- [x] Add a `describe "lookupStreamId"` block to `kiroku-store/test/Main.hs` covering:
  agreement with `getStream` on a live stream, behavior on a never-created stream, and
  behavior on a soft-deleted stream. (2026-05-13)
- [x] Run `cabal test kiroku-store-test --test-show-details=streaming` and record the
  pass/fail line counts here. Result: `128 examples, 0 failures` — the new `lookupStreamId`
  block contributes 3 examples, all passing. (2026-05-13)
- [x] Fill in `Outcomes & Retrospective` after the test pass. (2026-05-13)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`bench/ShibuyaOverhead.hs` is broken on the current branch (pre-existing).** Running
  `cabal build kiroku-store` builds the library and the test executable cleanly but then
  fails compiling the `kiroku-shibuya-overhead` benchmark with:

  ```text
  bench/ShibuyaOverhead.hs:209:13: error: [GHC-95909]
      • Constructor ‘Envelope’ does not have the required strict field(s):
          attributes :: HashMap Text Attribute
  ```

  The benchmark constructs an `Envelope` record without the `attributes` field that the
  current shibuya version requires as strict. This is unrelated to the `LookupStreamId`
  change — the failure compiles a benchmark module that does not reference the new
  constructor — and the test suite exercises the production code path end-to-end. Out of
  scope for this plan; should be filed as its own ticket.
  Evidence: `cabal build kiroku-store 2>&1 | tail -50` on 2026-05-13. The library
  built cleanly (`Kiroku.Store.Effect` and `Kiroku.Store.Read` both compiled) and
  `kiroku-store-test` linked successfully (`[10 of 10] Linking ... kiroku-store-test`)
  before the bench compilation failed.


## Decision Log

- Decision: Add a new constructor `LookupStreamId` to the `Store` effect rather than
  building a derived helper that just calls `getStream` and projects `^. #id`.
  Rationale: The whole point of the combinator is to avoid the five-column row decode that
  `getStream` performs. A derived helper would defeat the optimization the keiro
  upstream-roadmap is asking for. The effect constructor lets the PostgreSQL interpreter
  dispatch directly to the existing one-column `SQL.findStreamIdStmt`, and it keeps mock
  interpreters honest: any mock that wants to support `lookupStreamId` must answer it
  explicitly rather than inheriting an implementation through `getStream`.
  Date: 2026-05-14

- Decision: Keep `Kiroku.Store.SQL` in `other-modules` (private) and do *not* re-export
  `findStreamIdStmt` directly.
  Rationale: `kiroku-store/kiroku-store.cabal:40` deliberately hides the SQL layer so the
  Store effect remains the single abstraction boundary. Exposing `findStreamIdStmt`
  directly would force callers to either thread a `Hasql.Pool.Pool` themselves or run their
  own session helpers — both of which bypass the `Effect.Store` interpreter chain (pool
  acquisition, error mapping, observability). The effect-constructor approach preserves
  the abstraction.
  Date: 2026-05-14

- Decision: Match `getStream`'s soft-delete semantics — return `Just sid` for both live and
  soft-deleted streams, `Nothing` for hard-deleted or never-created streams.
  Rationale: The existing internal SQL (`SELECT stream_id FROM streams WHERE stream_name =
  $1`, no `deleted_at` filter) already has these semantics because it was written for the
  hard-delete path, which deliberately targets soft-deleted rows. Aligning with `getStream`
  on the boundary case keeps the two combinators substitutable up to the row-decode cost
  and removes one footgun for callers migrating from one to the other.
  Date: 2026-05-14

- Decision: Do not add a corresponding `Tx.Transaction`-flavored `lookupStreamIdTx`
  combinator in `Kiroku.Store.Transaction` as part of this plan.
  Rationale: The keiro use case named in the purpose section ("snapshot write resolves
  `stream_id` from `stream_name` via an inline `SELECT`") is the inline-SELECT case, which
  *is* a Tx-flavored call. However, the keiro upstream-roadmap explicitly scopes this
  candidate as a public `Eff`-level combinator (`lookupStreamId :: StreamName -> Eff es
  (Maybe StreamId)`), and the snapshot write currently has its own inline SQL it can keep
  for the Tx case without blocking on a kiroku change. If profiling later shows the Tx
  flavor is also worth saving, it can be added as a follow-up (one extra exported function
  from `Kiroku.Store.Transaction` that calls `Tx.statement name SQL.findStreamIdStmt`).
  Date: 2026-05-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### What was delivered

- `Kiroku.Store.Effect.Store` gained one constructor:
  `LookupStreamId :: StreamName -> Store m (Maybe StreamId)`, sitting between `GetStream`
  and `LinkToStream` in the GADT and dispatched in `runStorePool` to the existing
  `SQL.findStreamIdStmt`. The interpreter wraps the raw `Maybe Int64` result with
  `fmap (fmap StreamId)` at the call site, leaving `findStreamIdStmt` untouched.
- `Kiroku.Store.Read` exports the new combinator
  `lookupStreamId :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)`,
  reachable as `Kiroku.Store.lookupStreamId` via the umbrella module's wholesale
  re-export of `module Kiroku.Store.Read`.
- `kiroku-store/test/Main.hs` gained a `describe "lookupStreamId"` block with three
  examples — agreement with `getStream` on a live stream, `Nothing` on a never-created
  stream, and id stability across `softDeleteStream`. All three pass against the ephemeral
  PostgreSQL test harness.

### Comparison against the original purpose

The plan's purpose was to give consumers a one-column path from `StreamName` to
`StreamId` without forcing them to either decode a five-column `StreamInfo` row through
`getStream` or inline their own `SELECT stream_id FROM streams WHERE stream_name = $1`.
That is exactly what landed: the new combinator dispatches to the same one-column
`findStreamIdStmt` the hard-delete path already uses, with no schema change and no new
SQL. The keiro upstream-roadmap optimization called out in the purpose section is now
unblocked on the kiroku side.

### Gaps and lessons

- The Tx-flavored `lookupStreamIdTx` combinator was deliberately deferred per the Decision
  Log entry; this remains a follow-up if profiling later shows the inline-SELECT inside
  the snapshot-write path is worth saving.
- A pre-existing breakage in `bench/ShibuyaOverhead.hs` (see Surprises & Discoveries)
  prevents a clean `cabal build kiroku-store` end-to-end; the library and test
  executable build cleanly and the test suite runs to a green pass. The bench failure
  predates this work and is out of scope for this plan.
- No surprises in the implementation itself: the change followed the precedent set by
  plans 11 and 12 (effect constructor → interpreter branch → top-level combinator) one
  step at a time and the test pass on the first try.

### Final test result

```text
Finished in 85.5256 seconds
128 examples, 0 failures
Test suite kiroku-store-test: PASS
```

The new `lookupStreamId` block contributes 3 of those 128 examples, all green.


## Context and Orientation

`kiroku-store` is a PostgreSQL-backed event store written in Haskell. It lives in the
`kiroku-store/` directory of this repository; its public library is declared in
`kiroku-store/kiroku-store.cabal`. The store's external API is a dynamically-dispatched
`effectful` effect named `Store`, defined as a GADT in
`kiroku-store/src/Kiroku/Store/Effect.hs` starting at line 58. Each constructor of the
GADT corresponds to one operation a caller can invoke through `Effectful.Eff`. The
production interpreter `runStorePool` (same file, line 91 onward) maps each constructor
to one or more `hasql` SQL statements that run against a connection pool.

The relevant types live in `kiroku-store/src/Kiroku/Store/Types.hs`:

- `newtype StreamName = StreamName Text` (line 39) — the human-readable name a caller
  supplies, e.g. `StreamName "orders-1"`.
- `newtype StreamId = StreamId Int64` (line 47) — the database surrogate id assigned to
  the row in the `streams` table; stable for the row's lifetime.
- `data StreamInfo = StreamInfo { id, name, version, createdAt, deletedAt }` (line 168) —
  what `getStream` currently returns.

The existing public read API is in `kiroku-store/src/Kiroku/Store/Read.hs`. That module
re-exports six combinators today — `readStreamForward`, `readStreamForwardStream`,
`readStreamBackward`, `readAllForward`, `readAllBackward`, `readCategory`, and `getStream`
— each of which is a thin `send` to a `Store` constructor. The umbrella module
`kiroku-store/src/Kiroku/Store.hs` re-exports `module Kiroku.Store.Read` wholesale (line
19), so anything you add to `Read`'s explicit export list automatically appears in
`Kiroku.Store`.

The SQL layer lives in `kiroku-store/src/Kiroku/Store/SQL.hs`. That module is listed
under `other-modules` in `kiroku-store/kiroku-store.cabal:40`, meaning it is *not*
exposed to consumers — it is an internal-only assembly of `hasql` `Statement` values that
the interpreter dispatches to. Two statements there are relevant:

- `getStreamStmt :: Statement Text (Maybe StreamInfo)` (line 426) — runs `SELECT
  stream_id, stream_name, stream_version, created_at, deleted_at FROM streams WHERE
  stream_name = $1` and decodes all five columns. This is what `GetStream` dispatches to.
- `findStreamIdStmt :: Statement Text (Maybe Int64)` (line 654) — runs `SELECT stream_id
  FROM streams WHERE stream_name = $1` and decodes exactly one `int8` column. This
  statement is already used by the hard-delete path inside `runStorePool` (the
  `HardDeleteStream` branch, around line 197), wrapped in a `hasql-transaction`
  `Tx.statement` call.

The terms used above are: an `Effect` (capital E) in `effectful` is a GADT marked
`type instance DispatchOf e = Dynamic`; values of type `Eff es a` are computations that
require the effects listed in the row variable `es`. The single function `send`
(`Effectful.Dispatch.Dynamic.send`) lifts one GADT constructor into the corresponding
`Eff` computation; this is the pattern every existing read combinator follows
(`send (ReadStreamForward …)`, `send (GetStream …)`, etc.). A `hasql` `Statement` is a
parameterized SQL string paired with an encoder for inputs and a decoder for outputs;
`Session.statement` runs one against a single connection. None of these terms require
familiarity with prior plans.

Two reads of soft-delete semantics worth keeping in mind. A *soft-deleted* stream has
`streams.deleted_at IS NOT NULL` but its row is still present in the table; `getStream`
will return `Just streamInfo` for it with `deletedAt` populated, per its docstring at
`kiroku-store/src/Kiroku/Store/Read.hs:139`. A *hard-deleted* stream has had its row
removed from `streams` entirely (via `Kiroku.Store.Lifecycle.hardDeleteStream`); both
`getStream` and the new `lookupStreamId` will return `Nothing` for it. This is by design
and follows from `findStreamIdStmt` having no `deleted_at` filter.

Two related ExecPlans give additional surrounding context. Plan
`docs/plans/11-single-stream-runtransaction-combinator.md` documents the
`runTransactionAppending` Tx wrapper used by downstream projection consumers (most
prominently keiro), and plan `docs/plans/12-streamly-shaped-single-stream-forward-read.md`
records the recent addition of the `readStreamForwardStream` constant-memory streaming
read. Both follow the same shape this plan uses: add an effect constructor, dispatch to
a SQL statement, expose a top-level combinator on `Kiroku.Store.Read`. Familiarity with
those plans is not required, but they establish the precedent.


## Plan of Work

The work is small enough to land in a single milestone. There is no schema change, no new
SQL, no library-level refactor, and no observable change to existing behavior — only one
new exported function backed by an existing internal SQL statement.

### Milestone 1 — Expose `lookupStreamId`

Scope: thread a new `LookupStreamId` constructor through the `Store` effect, route it to
`SQL.findStreamIdStmt` in the PostgreSQL interpreter, expose a `lookupStreamId` combinator
on `Kiroku.Store.Read`, and add unit tests that prove the combinator returns the same
`StreamId` as `getStream` for live streams, the same `StreamId` for soft-deleted streams,
and `Nothing` for never-created streams.

What will exist at the end:

```haskell
-- in Kiroku.Store.Read
lookupStreamId :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
```

reachable via `Kiroku.Store.lookupStreamId` for any consumer that imports the umbrella
module.

The edits, in order:

1. `kiroku-store/src/Kiroku/Store/Effect.hs` — extend the `Store` GADT. Insert a new
   constructor between the existing `GetStream` and `LinkToStream` constructors so the
   ordering reflects "read-side metadata before mutating combinators":

   ```haskell
   LookupStreamId :: StreamName -> Store m (Maybe StreamId)
   ```

   Then extend the `runStorePool` interpreter's case-of with a new branch that mirrors
   the existing `GetStream` branch (currently at lines 130–132 of `Effect.hs`):

   ```haskell
   LookupStreamId (StreamName name) ->
       fmap (fmap StreamId) $
           usePool (store ^. #pool) $
               Session.statement name SQL.findStreamIdStmt
   ```

   Note: `findStreamIdStmt` returns `Maybe Int64`, so the branch wraps the result with
   `fmap (fmap StreamId)` to lift the raw `Int64` into the `StreamId` newtype before
   returning to the caller. This matches the pattern used by `softDeleteStreamStmt`'s
   decoder, which embeds the `StreamId` wrap *inside* the statement's decoder (see
   `kiroku-store/src/Kiroku/Store/SQL.hs:635`) — the difference here is that
   `findStreamIdStmt` decodes plain `Int64` so the wrap happens at the call site.
   Wrapping at the call site preserves the existing internal SQL statement untouched and
   keeps the change additive.

2. `kiroku-store/src/Kiroku/Store/Read.hs` — add `lookupStreamId` to the export list (place
   it next to `getStream` since they are sibling read-metadata combinators), and add the
   combinator definition at the end of the file:

   ```haskell
   {- | Look up a stream's surrogate id by name.

   Returns 'Just' the 'StreamId' for both live and soft-deleted streams (mirroring
   'getStream'\'s soft-delete behavior). Returns 'Nothing' for streams that have
   never been created and for streams that have been hard-deleted.

   This is a lighter-weight alternative to 'getStream' when the caller only needs
   the surrogate id: it decodes one @int8@ column instead of the five columns
   that 'StreamInfo' carries. Equivalent to projecting @info ^. #id@ from a
   successful 'getStream' result, but cheaper.
   -}
   lookupStreamId ::
       (HasCallStack, Store :> es) =>
       StreamName ->
       Eff es (Maybe StreamId)
   lookupStreamId name = send (LookupStreamId name)
   ```

3. `kiroku-store/test/Main.hs` — add a new `describe "lookupStreamId" $ do` block to the
   existing `around withTestStore $ do` group. Place it immediately after the existing
   `describe "getStream"` block (currently around line 309) so the two related read-metadata
   tests sit together. Three cases:

   - **Agrees with getStream on a live stream.** Append events to a stream, call
     `getStream` to obtain the canonical `StreamId`, call `lookupStreamId` separately, and
     assert equality.
   - **Returns Nothing for a stream that never existed.** Call `lookupStreamId
     (StreamName "no-such-stream")` against a fresh store and assert `Nothing`.
   - **Returns Just the same id for a soft-deleted stream.** Create a stream, capture its
     id via `lookupStreamId`, soft-delete it via `softDeleteStream`, call `lookupStreamId`
     again, and assert the id is unchanged. Cross-check with `getStream` to confirm both
     combinators see the soft-deleted row identically.

   Skeleton (the exact code goes in the file; the snippet below is the shape):

   ```haskell
   describe "lookupStreamId" $ do
       it "returns the same id as getStream for a live stream" $ \store -> do
           Right _ <-
               runStoreIO store $
                   appendToStream
                       (StreamName "lookup-live")
                       NoStream
                       [makeEvent "A" (Aeson.object [])]
           Right mInfo <- runStoreIO store $ getStream (StreamName "lookup-live")
           Right mSid <- runStoreIO store $ lookupStreamId (StreamName "lookup-live")
           case (mInfo, mSid) of
               (Just info, Just sid) ->
                   (info ^. #id) `shouldBe` sid
               _ ->
                   expectationFailure "Expected both getStream and lookupStreamId to return Just"

       it "returns Nothing for a stream that has never been created" $ \store -> do
           Right mSid <- runStoreIO store $ lookupStreamId (StreamName "lookup-missing")
           mSid `shouldBe` Nothing

       it "returns Just the same id for a soft-deleted stream" $ \store -> do
           Right _ <-
               runStoreIO store $
                   appendToStream
                       (StreamName "lookup-soft")
                       NoStream
                       [makeEvent "A" (Aeson.object [])]
           Right mSidBefore <- runStoreIO store $ lookupStreamId (StreamName "lookup-soft")
           Right _ <- runStoreIO store $ softDeleteStream (StreamName "lookup-soft")
           Right mSidAfter <- runStoreIO store $ lookupStreamId (StreamName "lookup-soft")
           mSidAfter `shouldBe` mSidBefore
           -- And getStream agrees on the soft-deleted row.
           Right mInfo <- runStoreIO store $ getStream (StreamName "lookup-soft")
           case (mInfo, mSidAfter) of
               (Just info, Just sid) -> (info ^. #id) `shouldBe` sid
               _ -> expectationFailure "Expected Just on a soft-deleted stream"
   ```

Acceptance for the milestone: `cabal build kiroku-store` succeeds; `cabal test
kiroku-store-test --test-show-details=streaming` finishes with all three new examples
passing and no existing example regressing. The Validation and Acceptance section below
spells out the exact commands and expected transcript snippets.


## Concrete Steps

All commands run from the repository root: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

1. Confirm the working tree is clean for the kiroku-store package:

   ```bash
   git status -- kiroku-store
   ```

   Expected: no modifications under `kiroku-store/` (or only modifications you have
   already accepted as in-flight).

2. Edit `kiroku-store/src/Kiroku/Store/Effect.hs` to add the `LookupStreamId` constructor
   to the `Store` GADT and the matching interpreter branch in `runStorePool`. See the Plan
   of Work section for the exact code.

3. Edit `kiroku-store/src/Kiroku/Store/Read.hs` to add `lookupStreamId` to the export list
   and define the combinator. See the Plan of Work section for the exact code.

4. Edit `kiroku-store/test/Main.hs` to add the `describe "lookupStreamId" $ do` block. See
   the Plan of Work section for the test skeleton.

5. Build the library:

   ```bash
   cabal build kiroku-store
   ```

   Expected (abbreviated):

   ```text
   Resolving dependencies...
   Build profile: -w ghc-X.Y.Z -O1
   In order, the following will be built (use -v for more details):
    - kiroku-store-0.1.0.0 (lib) (file Kiroku/Store/Effect.hs changed)
   Preprocessing library for kiroku-store-0.1.0.0...
   Building library for kiroku-store-0.1.0.0...
   [12 of 19] Compiling Kiroku.Store.Effect ( src/Kiroku/Store/Effect.hs, ... )
   [13 of 19] Compiling Kiroku.Store.Read ( src/Kiroku/Store/Read.hs, ... )
   ...
   ```

   Zero warnings about unused identifiers, no `findStreamId` / `LookupStreamId` errors.

6. Run the test suite:

   ```bash
   cabal test kiroku-store-test --test-show-details=streaming
   ```

   Expected (abbreviated, the new block's lines should appear):

   ```text
   kiroku-store-test
     ...
     lookupStreamId
       returns the same id as getStream for a live stream  [✔]
       returns Nothing for a stream that has never been created  [✔]
       returns Just the same id for a soft-deleted stream  [✔]
   ...
   Finished in N.NNN seconds
   M examples, 0 failures
   ```

   The total example count `M` should equal the previous total plus three.

7. Stage and commit:

   ```bash
   git add kiroku-store/src/Kiroku/Store/Effect.hs \
           kiroku-store/src/Kiroku/Store/Read.hs \
           kiroku-store/test/Main.hs \
           docs/plans/15-expose-lookupstreamid-combinator-on-kiroku-store-read.md
   git commit -m "$(cat <<'EOF'
   feat(store): expose lookupStreamId combinator on Kiroku.Store.Read

   Adds a public combinator that decodes one int8 column instead of the
   five columns getStream materializes. Backed by the existing internal
   findStreamIdStmt; matches getStream's soft-delete semantics.

   ExecPlan: docs/plans/15-expose-lookupstreamid-combinator-on-kiroku-store-read.md
   Intention: intention_01krj80vf4epcrsegk3d3ptjmr
   EOF
   )"
   ```

   Per the repo-global `CLAUDE.md`, commits follow Conventional Commits and stay on the
   current branch (no feature branch). Per the ExecPlan skill, every commit while working
   on this plan must carry both the `ExecPlan:` and `Intention:` trailers shown above.

As work proceeds, append a short transcript snippet under each step here whenever a
command's actual output differs meaningfully from the expected output, and update the
Progress section's checkboxes.


## Validation and Acceptance

Acceptance is phrased as the three behaviors the new test block exercises. A reader who
just ran the steps above should be able to verify each in isolation.

1. **Agreement with `getStream`.** After appending one event to `StreamName "lookup-live"`
   with `NoStream`, the following expressions return the same `StreamId`:

   ```haskell
   fmap (^. #id) <$> getStream (StreamName "lookup-live")
   lookupStreamId (StreamName "lookup-live")
   ```

   Concretely the test asserts `(info ^. #id) == sid`; observe the
   `returns the same id as getStream for a live stream [✔]` line in the test output.

2. **Nothing for a never-created stream.** `lookupStreamId (StreamName "lookup-missing")`
   on a fresh store returns `Right Nothing` (the outer `Right` is the `runStoreIO`
   result envelope; the inner `Nothing` is the combinator's answer). Observe the
   `returns Nothing for a stream that has never been created [✔]` line.

3. **Soft-deleted streams still resolve.** After `softDeleteStream (StreamName
   "lookup-soft")`, a subsequent `lookupStreamId (StreamName "lookup-soft")` returns
   `Just` the same `StreamId` it returned before the soft-delete, and `getStream` agrees
   on the id. Observe the `returns Just the same id for a soft-deleted stream [✔]` line.

The test harness, defined at `kiroku-store/test/Test/Helpers.hs:69`, brackets an ephemeral
PostgreSQL instance via `EphemeralPg.withCached` and a `KirokuStore` via `withStore`, so
the tests run against real Postgres — not a mock. That means a passing run proves the SQL
statement actually executes and its decoder is correct, not just that the Haskell
typechecks.

If any of the three lines reports `[✘]`, the failure message will name the expected vs.
actual `StreamId`. Common failure shapes and what they mean:

- `Expected: Just (StreamId 7), Actual: Nothing` — the SQL filter is rejecting rows it
  should accept. Check that the new branch in `runStorePool` is calling
  `SQL.findStreamIdStmt` and not, say, `SQL.softDeleteStreamStmt` by mistake.
- `Expected Just StreamInfo, got Nothing` from inside one of the `case` blocks — the
  setup `appendToStream` call failed; inspect the preceding line in the test output for
  the underlying `StoreError`.
- A compile-time error on `Ambiguous occurrence ‘LookupStreamId’` — the GADT constructor
  was added under `import qualified` instead of via a re-export; ensure `Kiroku.Store.Read`
  imports `Store (..)` unqualified at the top of the file (this is the existing pattern,
  visible at `kiroku-store/src/Kiroku/Store/Read.hs:19`).

The umbrella module `kiroku-store/src/Kiroku/Store.hs` re-exports `module
Kiroku.Store.Read`, so once the export list there is updated, the new symbol is reachable
from a fresh consumer with a single `import Kiroku.Store`. No additional plumbing in
`Kiroku/Store.hs` is needed.

Beyond the unit tests, manual verification is optional but cheap: in a `cabal repl
kiroku-store-test` session, the new combinator should appear in the namespace
(`:t lookupStreamId` should print
`lookupStreamId :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)`).


## Idempotence and Recovery

Every step in this plan is safely repeatable. The work is additive at three levels and
performs no schema migration, no data migration, and no destructive operation.

- `cabal build kiroku-store` and `cabal test kiroku-store-test` may be re-run any number
  of times. The test harness in `Test.Helpers.withTestStore` brackets a fresh ephemeral
  PostgreSQL instance per `it` example, so test state never leaks between runs and there
  is no test data to clean up between attempts.
- Edits to `Effect.hs`, `Read.hs`, and `Main.hs` are localized; if a build fails midway,
  `git diff` shows exactly what was added and `git checkout -- <path>` reverts cleanly.
  No file outside the three named here should change.
- The commit step is the only point where work becomes durable beyond the working tree;
  before committing, re-run the build and the test suite and confirm both succeed. If a
  commit lands with a regression, the recovery is a normal forward-fix commit, not a
  destructive history rewrite — per the global `CLAUDE.md` guidance to prefer new commits
  over amends.

No production database is touched by this plan. There is no rollback contingency to
prepare; the change is purely additive at the API level and does not modify the on-disk
schema, the SQL statements that already exist, or the behavior of any existing call.


## Interfaces and Dependencies

### Libraries

This plan introduces no new dependencies. The work uses libraries already pulled in by
`kiroku-store/kiroku-store.cabal`:

- `effectful-core` (`Effectful`, `Effectful.Dispatch.Dynamic.send`) — the effect system
  that hosts the `Store` GADT.
- `hasql` (`Hasql.Session.statement`) and `hasql-pool` (`Hasql.Pool.use`) — used by the
  existing `usePool` helper in `Kiroku.Store.Effect` to execute the SQL statement.
- `hspec` and `hspec-hedgehog` — already present in the test stanza; the new tests use
  plain `hspec` `it`/`shouldBe` style with no property tests.

### Types and signatures (post-milestone-1)

In `Kiroku.Store.Effect` (`kiroku-store/src/Kiroku/Store/Effect.hs`), the `Store` GADT
gains one constructor:

```haskell
LookupStreamId :: StreamName -> Store m (Maybe StreamId)
```

placed between the existing `GetStream` and `LinkToStream` constructors.

In `Kiroku.Store.Read` (`kiroku-store/src/Kiroku/Store/Read.hs`), one new top-level
binding appears, exported from the module:

```haskell
lookupStreamId ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamId)
```

Both types — `StreamName` and `StreamId` — already exist in
`Kiroku.Store.Types` (lines 39 and 47 respectively).

### Re-exports

`Kiroku.Store` (`kiroku-store/src/Kiroku/Store/Read.hs:19` reachable via the umbrella at
`kiroku-store/src/Kiroku/Store.hs:19`) re-exports `module Kiroku.Store.Read` wholesale.
After this plan, `import Kiroku.Store` is sufficient to call `lookupStreamId` from any
consumer. No additional re-export wiring is required.

### Downstream consumers

The named beneficiary is `shinzui/keiro`, located at `/Users/shinzui/Keikaku/bokuno/keiro`
on this machine. Its upstream-roadmap document
(`docs/research/11-upstream-roadmap.md`, §4.9, lines 257–275) records the request that
motivated this plan. Updating keiro to *consume* the new combinator is out of scope here
— this plan delivers only the kiroku-side capability. If keiro wants to switch its
snapshot read or write path to `lookupStreamId`, that is a separate change tracked by
that project's own ExecPlans.

### Mock interpreters

`kiroku-store/src/Kiroku/Store/Effect.hs:32` declares that mock interpreters of `Store`
are expected to reject `RunTransaction` / `RunTransactionNoRetry` at runtime. The new
`LookupStreamId` constructor has the opposite property: it is trivially mockable (input
`StreamName`, output `Maybe StreamId`), so any in-memory mock that wants to support it
needs only one additional case branch. The default policy for mock interpreters that this
repository does not own is unchanged — they will fail compilation pattern matches by way
of GHC's `-Wincomplete-patterns` warning until they handle the new constructor. This is
the intended discovery mechanism for downstream test mocks.
