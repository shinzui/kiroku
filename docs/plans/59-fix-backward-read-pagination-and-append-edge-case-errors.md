---
id: 59
slug: fix-backward-read-pagination-and-append-edge-case-errors
title: "Fix backward read pagination and append edge-case errors"
kind: exec-plan
created_at: 2026-06-11T04:32:45Z
intention: intention_01kv3qaxg9e91v0zq47stehnkz
master_plan: "docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md"
---

# Fix backward read pagination and append edge-case errors

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is EP-4 of the MasterPlan at
`docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`.
It has no dependencies on other child plans and can start immediately. EP-7 (the
benchmark-gated performance plan) soft-depends on this plan, because its append-pipelining
prototype must not re-introduce the empty-batch behavior fixed here.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. Its public read API promises that backward
reads — `readStreamBackward` and `readAllBackward` in
`kiroku-store/src/Kiroku/Store/Read.hs` — return events *older* than a caller-supplied
cursor, so a consumer can walk a stream from newest to oldest one page at a time. Today
that promise is broken: the SQL behind both functions filters for events *newer* than the
cursor, so the first page (cursor 0) accidentally works and every subsequent page re-reads
events the caller already has. Backward pagination is simply impossible. After this plan,
a caller can page backward through a stream (or the global `$all` stream) with a nonzero
cursor and receive strictly older events on every page, proven by tests that fail against
today's code.

The plan also fixes a cluster of smaller append/read edge cases found by the same
2026-06-10 audit, all in the `kiroku-store` package:

- Appending an empty event batch (`[]`) currently "succeeds" — and under the `NoStream`
  expectation it actually *creates* an empty stream — while taking the global `$all` row
  lock and firing `NOTIFY` triggers for nothing. After this plan, every append surface
  rejects an empty batch with a typed error before touching the connection pool.
- `linkToStream` failures (double-link, missing source event) surface as an opaque
  `ConnectionError` text blob. After this plan they map to typed, pattern-matchable
  `StoreError` constructors.
- A single-stream `NoStream` append that loses a deadlock race against a concurrent
  multi-stream transaction surfaces `UnexpectedServerError "40P01"` to the caller even
  though the operation is trivially retryable. After this plan the interpreter retries
  once, matching the retry behavior the multi-stream path already gets from
  `hasql-transaction`.
- Two small efficiency leaks are closed (`readStreamForwardStream` always pays one extra
  empty-page round trip; `lookupStreamNames []` does a round trip for a guaranteed-empty
  result), and one overselling haddock about `WrongExpectedVersion`'s "actual version"
  field is corrected.

Everything ships as Haskell changes in `kiroku-store` plus tests; no schema migration is
needed. The observable outcome is the `kiroku-store-test` suite: new tests fail before the
fixes and pass after, and the whole suite stays green.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add failing backward-pagination tests (`readStreamBackward` nonzero cursor, `readAllBackward` nonzero cursor) to `kiroku-store/test/Main.hs` and record their failure output (2026-06-14)
- [x] M1: Flip the predicate in `readStreamBackwardSQL` and `readAllBackwardSQL` to `<` in `kiroku-store/src/Kiroku/Store/SQL.hs` (2026-06-14)
- [x] M1: Map the cursor-0 sentinel to `maxBound` in the `ReadStreamBackward` / `ReadAllBackward` interpreter branches in `kiroku-store/src/Kiroku/Store/Effect.hs` (2026-06-14)
- [x] M1: Align haddocks in `Read.hs` and `SQL.hs`; confirm new tests pass and full suite is green (2026-06-14)
- [ ] M2: Add `EmptyAppendBatch` to `StoreError` and `EmptyAppendBatchConflict` to `AppendConflict` in `kiroku-store/src/Kiroku/Store/Error.hs`
- [ ] M2: Reject empty batches in `AppendToStream` and `AppendMultiStream` interpreter branches (`Effect.hs`), in `appendToStreamTx`, and in `runTransactionAppendingWith` (`Transaction.hs`)
- [ ] M2: Short-circuit `AppendMultiStream []` to `pure []`
- [ ] M2: Correct the empty-batch haddocks in `Append.hs` and `Transaction.hs`; fix the `WrongExpectedVersion` / `WrongExpectedVersionConflict` "actual version" haddocks in `Error.hs` (finding G)
- [ ] M2: Add empty-batch rejection tests (single, multi, transactional) and confirm green
- [ ] M3: Add `EventAlreadyLinked` and `LinkSourceEventMissing` constructors plus `mapLinkUsageError` / `mapGenericUsageError` to `Error.hs`
- [ ] M3: Route `LinkToStream` errors through `mapLinkUsageError` in `Effect.hs`; tighten the two `Left _` link tests in `test/Main.hs` to the typed constructors
- [ ] M3: Add `isTransientSerializationError` to `Error.hs` with a pure unit test; add one-shot retry to the `AppendToStream` interpreter branch
- [ ] M3: Add best-effort deadlock stress test to `kiroku-store/test/Test/Concurrency.hs`; confirm green
- [ ] M4: Early-terminate `readStreamForwardStream` when a page is short; replace per-page `Stream.fromList . V.toList` with an index-based `Stream.unfoldr`
- [ ] M4: Short-circuit `LookupStreamNames []` to `pure Map.empty`; update the `lookupStreamNames` haddock in `Read.hs`
- [ ] M4: Add round-trip-count tests (observation-handler based) for both M4 items; confirm green
- [ ] Final: `cabal build all` and `cabal test all` green; update MasterPlan 9 Progress entries for EP-4; write Outcomes & Retrospective


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

2026-06-14, M1 bite-check behaved as expected. After adding only the two new
pagination tests, `readStreamBackward` with cursor 4 returned `[StreamVersion 5]`
instead of `[StreamVersion 3, StreamVersion 2]`, and `readAllBackward` with cursor 2
returned `[GlobalPosition 3]` instead of `[GlobalPosition 1]`.

```text
readStreamBackward
  paginates backward using stream version as an exclusive cursor [x]
readAllBackward
  paginates backward using global position as an exclusive cursor [x]

Failures:
  1) readStreamBackward paginates backward using stream version as an exclusive cursor
       expected: [StreamVersion 3,StreamVersion 2]
        but got: [StreamVersion 5]

  2) readAllBackward paginates backward using global position as an exclusive cursor
       expected: [GlobalPosition 1]
        but got: [GlobalPosition 3]

2 examples, 2 failures
```

After changing both backward SQL predicates to `<` and mapping cursor 0 to `maxBound`
in the interpreter, the targeted test passed with `2 examples, 0 failures`; the full
`kiroku-store-test` suite passed with 203 examples and 0 failures.


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix backward-read pagination by keeping the SQL predicate a plain
  `se.stream_version < $N` and mapping the cursor-0 "from latest" sentinel to
  `maxBound :: Int64` in the interpreter (`Effect.hs`), rather than writing
  `($N = 0 OR se.stream_version < $N)` in SQL.
  Rationale: All four read statements are prepared (`preparable`); with a plain range
  predicate the planner keeps a simple, index-sargable condition on
  `ix_stream_events_stream_version (stream_id, stream_version)` even under a generic
  plan, whereas an `OR`-on-parameter shape risks degraded generic plans. The sentinel
  is a Haskell-API concept, so it belongs in the Haskell layer. Collision is
  impossible: real stream versions and global positions start at 1 (the `$all` seed
  row at position 0 is internal and never returned), so cursor 0 is unambiguous.
  Date: 2026-06-10

- Decision: Empty append batches are rejected with a new additive `StoreError`
  constructor `EmptyAppendBatch !StreamName` (mirrored as `EmptyAppendBatchConflict`
  in `AppendConflict` for the transaction surface), thrown before any pool work.
  Rationale: `Error.hs` documents the constructor set as designed for additive
  evolution; reusing an existing constructor (e.g. `WrongExpectedVersion`) would
  misdescribe a caller bug as a concurrency outcome. The `Tx` surface needs a mirror
  because `Hasql.Transaction.Transaction` has no exception channel.
  Date: 2026-06-10

- Decision: `appendMultiStream []` (an empty *list of operations*) short-circuits to
  `pure []` with no round trip instead of erroring; only a per-stream empty *event*
  list raises `EmptyAppendBatch`.
  Rationale: "All zero appends succeeded" is coherent and matches the
  `lookupStreamNames []` short-circuit pattern; there is no stream name to attribute
  an error to. The dangerous case — a real stream silently created or version-bumped
  by zero events — only arises from a per-stream empty batch.
  Date: 2026-06-10

- Decision: Link errors get two new constructors — `EventAlreadyLinked !StreamName
  !(Maybe EventId)` for `23505` on `stream_events_pkey` and `LinkSourceEventMissing
  !StreamName` for `23502` (not-null violation) — via a dedicated
  `mapLinkUsageError`, with a shared `mapGenericUsageError` fallback for
  pool/connection failures.
  Rationale: The existing `mapUsageError` is append-shaped (it needs an
  `ExpectedVersion` and maps generic `23505` to `WrongExpectedVersion`, which is wrong
  for links). The `stream_events` primary key is the unnamed
  `PRIMARY KEY (event_id, stream_id)` in the bootstrap migration, so PostgreSQL names
  the constraint `stream_events_pkey`; its violation detail is composite
  (`Key (event_id, stream_id)=(<uuid>, <id>) already exists.`), which is why the
  event-id extraction takes the *first* component and the payload stays `Maybe`.
  Date: 2026-06-10

- Decision: The single-stream `AppendToStream` interpreter retries exactly once on
  SQLSTATE `40001` (serialization failure) or `40P01` (deadlock detected), and only
  there. No retry loop, no backoff, no retry on any other path.
  Rationale: This mirrors what the multi-stream path already gets for free —
  `hasql-transaction`'s `Hasql.Transaction.Private.Sessions` retries exactly these two
  codes (verified in the hasql-transaction source; the changelog entry is "Add
  automatic retry on deadlock errors (code 40P01)"). A deadlock victim's transaction
  is fully rolled back by PostgreSQL, and event ids are generated before the first
  attempt, so the retry is idempotent. One shot keeps worst-case latency bounded and
  avoids masking systemic problems.
  Date: 2026-06-10

- Decision: `readStreamForwardStream` flattens each page with an index-based
  `Stream.unfoldr` over the `Vector` instead of `Stream.fromList . V.toList`.
  Rationale: Checked the dependency source (streamly-core, pinned `>=0.3 && <0.4`,
  source at `/Users/shinzui/Keikaku/hub/haskell/streamly-project`):
  `Streamly.Data.Stream` exposes no `Vector` unfold — vector integration lives in
  external packages we do not depend on. An index-based `unfoldr` is three lines,
  stays inside streamly-core, and avoids materializing an intermediate list per page.
  Date: 2026-06-10

- Decision: Round-trip-count assertions in tests use the hasql-pool
  `observationHandler` (counting `ConnectionStatusChangeObservation` transitions to
  `InUseConnectionStatus`, one per `Pool.use`) rather than an effect-level interposer.
  Rationale: Both M4 fixes live *inside* the interpreter, below the `Store` effect, so
  counting effect dispatches cannot observe them. `ConnectionSettings` already carries
  an `observationHandler` field and `test/Main.hs` (the `describe "observationHandler"`
  block near line 1756) already demonstrates the wiring. Publisher/notifier pool noise
  is avoided by quiescing (no appends during the measured window, `waitForPublisher`
  beforehand).
  Date: 2026-06-10

- (Constraint, restated from MasterPlan 9 — do not re-litigate.) The append SQL stays
  CTE-shaped: plans 21/22/23 established by benchmark that round-trip count dominates
  SQL shape on hasql. Nothing in this plan changes the CTE structure; M2 only adds a
  Haskell-side guard in front of it. Likewise `RecordedEvent` deliberately carries no
  stream-name field; nothing here adds one.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)

2026-06-14, after M1: backward stream reads and `$all` reads now paginate with
exclusive upper-bound cursors. Cursor 0 remains the public "from latest" sentinel but is
translated in `Effect.hs` before SQL execution, preserving simple prepared-statement
range predicates. The new regression tests cover nonzero cursor pages for both APIs and
the existing cursor-0 behavior remains green.


## Context and Orientation

The repository is a Haskell cabal multi-package project rooted at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. All work in this plan happens in
the `kiroku-store` package (library `kiroku-store/src`, test suite `kiroku-store/test`).
Sibling packages (`kiroku-cli`, `kiroku-metrics`, `kiroku-jitsurei`,
`shibuya-kiroku-adapter`) compile against the library; a repo-wide grep confirms none of
them call `readStreamBackward`, `readAllBackward`, `linkToStream`, or pattern-match
exhaustively on `StoreError`, so the changes here are additive from their point of view.
(Out-of-repo note: the `keiro` project consumes `kiroku-store` by git pin, so the new
error constructors reach it only after a push and pin bump — record that as a follow-up,
not part of this plan.)

Key vocabulary, defined once:

- **Stream**: a named, ordered sequence of events. Stored as one row in the `streams`
  table (surrogate key `stream_id`, monotonically increasing `stream_version`).
- **`$all`**: the global stream. It is the seeded `streams` row with `stream_id = 0`;
  every appended event also gets a junction row under stream 0, and that row's
  `stream_version` *is* the event's global position. The `$all` row works as a global
  lock: every append `UPDATE`s it, which serializes commits and makes global positions
  gap-free.
- **Junction row**: a row in `stream_events (event_id, stream_id, stream_version,
  original_stream_id, original_stream_version)` placing one event at one position in one
  stream. Its primary key is `PRIMARY KEY (event_id, stream_id)` (PostgreSQL
  auto-names it `stream_events_pkey`) — see
  `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`
  line 84.
- **CTE append**: each append variant is a single SQL statement made of chained
  `WITH` common table expressions (CTEs) in `kiroku-store/src/Kiroku/Store/SQL.hs`
  (lines ~160–367: `appendExpectedVersionSQL`, `appendStreamExistsSQL`,
  `appendNoStreamSQL`, `appendAnyVersionSQL`). When a precondition fails, the statement
  raises no error — it simply returns zero rows, and the Haskell layer maps that to a
  typed error (`emptyResultError` / `emptyResultConflict` in `Error.hs`).
- **The `Store` effect**: a dynamically dispatched `effectful` effect
  (`kiroku-store/src/Kiroku/Store/Effect.hs`). Public API modules (`Read.hs`,
  `Append.hs`, `Link.hs`, `Transaction.hs`) are thin `send` wrappers; `runStorePool`
  (Effect.hs line 126) is the PostgreSQL interpreter, running hasql sessions on a
  `hasql-pool` pool.
- **`ExpectedVersion`**: the append precondition — `NoStream` (stream must not exist;
  creates it), `StreamExists`, `ExactVersion n` (optimistic concurrency), `AnyVersion`
  (upsert).
- **ephemeral-pg**: the test suite (`kiroku-store/test/Main.hs` plus `Test.*` modules)
  starts its own throwaway PostgreSQL per run via the `ephemeral-pg` package; each
  `it` block wrapped in `around withTestStore` gets a freshly migrated database
  (helpers in `kiroku-store/test/Test/Helpers.hs`). No external database is needed,
  but the nix dev shell must be active so `initdb`/`postgres` are on `PATH`.

Where each audited defect lives (line numbers verified against the working tree on
2026-06-10; re-verify before editing, they will drift):

- **A (HIGH) — backward reads cannot paginate.** `readStreamBackwardSQL` (SQL.hs
  lines 487–502) and `readAllBackwardSQL` (SQL.hs lines 523–538) filter
  `se.stream_version > $N` and `ORDER BY ... DESC`. The documented contract
  (`Read.hs` lines 84–88 for streams, 115–119 for `$all`) is the opposite: "events
  with `streamVersion < startVer` are returned (events older than the cursor)", with
  0 meaning "start from the latest". With cursor 0 the buggy `>` returns everything
  newest-first — which is the only case the existing tests exercise
  (`test/Main.hs` lines 299–314 and 353–360). With any nonzero cursor it returns
  events *newer* than the cursor, so page 2 of a backward walk re-reads page 1's
  events. The interpreter branches are `ReadStreamBackward` (Effect.hs lines 159–163)
  and `ReadAllBackward` (lines 169–173).
- **B (MEDIUM) — empty-batch appends silently succeed and mutate state.** The haddock
  at `Append.hs` lines 62–68 claims `[]` produces an error via the empty-CTE path. It
  does not: with zero events, `count(*) FROM new_events` is 0, so the
  `stream_update`/`stream_upsert` CTE still matches and "bumps" the stream by 0 —
  `ExactVersion`-match, `StreamExists`, and `AnyVersion` all return success — and
  `appendNoStreamSQL`'s `stream_insert` (SQL.hs lines 273–277) inserts
  unconditionally, so `NoStream` with `[]` *creates an empty stream*. Every such call
  also takes the `$all` row lock (the `all_update` CTE updates `stream_id = 0`) and
  fires the `stream_events_notify` trigger. Affected surfaces: the `AppendToStream`
  branch (Effect.hs lines 132–153), the `AppendMultiStream` branch (lines 201–249),
  and the transactional `appendToStreamTx` (`Transaction.hs` lines 153–164) plus its
  wrapper `runTransactionAppendingWith` (lines 300–320).
- **C (LOW) — link errors are never mapped.** The `LinkToStream` branch (Effect.hs
  lines 187–195) goes through `usePool` (lines 319–328), which maps *every* failure
  to `ConnectionError (show usageErr)`. So the documented double-link primary-key
  violation (`Link.hs` lines 33–35) and the missing-source-event NOT NULL rejection
  (the `LEFT JOIN LATERAL` design note at SQL.hs lines 709–714) both surface as
  unmatchable text. The existing tests at `test/Main.hs` lines 530–538 and 545–553
  consequently assert only `Left _`.
- **D (LOW) — single-stream `NoStream` appends are not deadlock-retried.** A fresh
  `NoStream` append speculatively inserts a `streams` row and then waits to update
  `$all`; a concurrent multi-stream transaction (which pre-locks via
  `lockStreamsForMultiStmt`, SQL.hs lines 999–1009, and intentionally does *not*
  pre-lock `$all` or not-yet-existing streams — see that haddock) can hold `$all`
  while waiting on the same fresh stream's unique-index entry. PostgreSQL kills one
  side with SQLSTATE `40P01`. The multi-stream side is retried by
  `hasql-transaction` (which retries `40001` and `40P01`), but `AppendToStream` is a
  bare `Session.statement` under `Pool.use` (Effect.hs lines 138–146), so its caller
  gets `UnexpectedServerError "40P01" ...`.
- **E (LOW perf) — `readStreamForwardStream` always pays one extra round trip.** Its
  pager (`Read.hs` lines 72–79) terminates only when a page comes back empty, so a
  stream of 5 events read at page size 2 issues 4 queries (2+2+1+0) when 3 suffice.
  It also flattens each page with `Stream.fromList . V.toList`.
- **F (LOW perf) — `lookupStreamNames []` does a round trip.** The interpreter branch
  (Effect.hs lines 181–186) always hits the pool; the haddock (`Read.hs` lines
  191–192) already implies emptiness is free.
- **G (doc) — `WrongExpectedVersion`'s third field oversells.** The haddock
  (`Error.hs` lines 45–50) says the actual version is carried "or `StreamVersion` 0
  when the version could not be recovered". In reality the only producer on the
  empty-CTE path is `emptyResultConflict` (Error.hs lines 230–239), which *always*
  passes `StreamVersion 0` — the actual version is never recovered, because doing so
  would cost an extra read. The mirror haddock on `WrongExpectedVersionConflict`
  (lines 193–199) has the same problem.

Build and test commands (from the `Justfile` at the repo root; run everything from
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` inside the nix dev shell):

```bash
cabal build all                 # just build
cabal test all                  # just test
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
# Run a subset by hspec description:
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "readStreamBackward"'
```

The compiler is GHC 9.12.4 (pinned in `cabal.project`). The test suite is hspec-based;
`--match` filters by `describe`/`it` text.


## Plan of Work

Four milestones. M1 is the headline correctness fix and is mandated failing-test-first.
M2 closes the empty-batch hole across all three append surfaces and fixes the related
documentation (including finding G, which is about append-error docs). M3 adds the typed
link errors and the one-shot deadlock retry. M4 lands the two small efficiency fixes.
Each milestone leaves the full suite green and is independently committable.


### Milestone 1 — Backward reads paginate correctly (failing test first)

Scope: findings A. At the end of this milestone, `readStreamBackward` and
`readAllBackward` honor their documented exclusive-`<` cursor contract, a nonzero-cursor
pagination test exists for each (and demonstrably failed before the fix), and the
haddocks/SQL comments agree with the behavior.

**Step 1 — write the failing tests.** In `kiroku-store/test/Main.hs`, extend the existing
`describe "readStreamBackward"` block (currently at line 299) with a pagination test, and
the `describe "readAllBackward"` block (line 353) likewise. Model them on the existing
forward-pagination test ("paginates using stream version as cursor", line 317). The
stream-read test: append 5 events to one stream, then walk backward in pages of 2:

```haskell
it "paginates backward using stream version as an exclusive cursor" $ \store -> do
    let events = map (\i -> makeEvent ("E" <> T.pack (show i)) (Aeson.object [])) [1 .. 5 :: Int]
    Right _ <- runStoreIO store $ appendToStream (StreamName "read-bwd-page") NoStream events
    -- Page 1: cursor 0 = "from the latest".
    Right page1 <- runStoreIO store $ readStreamBackward (StreamName "read-bwd-page") (StreamVersion 0) 2
    fmap (^. #streamVersion) (V.toList page1) `shouldBe` [StreamVersion 5, StreamVersion 4]
    -- Page 2: cursor = oldest version seen so far; must return strictly OLDER events.
    let cursor1 = V.last page1 ^. #streamVersion
    Right page2 <- runStoreIO store $ readStreamBackward (StreamName "read-bwd-page") cursor1 2
    fmap (^. #streamVersion) (V.toList page2) `shouldBe` [StreamVersion 3, StreamVersion 2]
    -- Page 3: the final, short page.
    let cursor2 = V.last page2 ^. #streamVersion
    Right page3 <- runStoreIO store $ readStreamBackward (StreamName "read-bwd-page") cursor2 2
    fmap (^. #streamVersion) (V.toList page3) `shouldBe` [StreamVersion 1]
    -- Page 4: past the beginning — empty terminates the walk.
    Right page4 <- runStoreIO store $ readStreamBackward (StreamName "read-bwd-page") (V.last page3 ^. #streamVersion) 2
    V.length page4 `shouldBe` 0
```

The `$all` test is the same shape: append one event each to three distinct streams
(global positions 1–3 — each `around withTestStore` test gets a fresh database, so
positions are deterministic), then `readAllBackward (GlobalPosition 0) 2` must yield
positions `[3, 2]`, a second page from `GlobalPosition 2` must yield `[1]`, and a page
from `GlobalPosition 1` must be empty.

Run the new tests and capture the failure (this is the proof the test bites):

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "paginates backward"'
```

Expected failure shape against today's code (page 2 re-reads the *newest* events because
the SQL keeps returning `> cursor`):

```text
  1) readStreamBackward paginates backward using stream version as an exclusive cursor
       expected: [StreamVersion 3,StreamVersion 2]
        but got: [StreamVersion 5,StreamVersion 4]
```

**Step 2 — fix the SQL.** In `kiroku-store/src/Kiroku/Store/SQL.hs`, change the predicate
in `readStreamBackwardSQL` (line 499) and `readAllBackwardSQL` (line 535) from `>` to `<`:

```sql
  AND se.stream_version < $2   -- readStreamBackwardSQL ($1 for readAllBackwardSQL)
```

Update each statement's haddock to state the contract: the parameter is an *exclusive
upper bound*; the interpreter supplies `maxBound` for the "from the latest" case.

**Step 3 — map the sentinel in the interpreter.** In
`kiroku-store/src/Kiroku/Store/Effect.hs`, the `ReadStreamBackward` and `ReadAllBackward`
branches (lines 159–173) translate cursor 0 to `maxBound` before hitting the statement
(per the Decision Log — `0 OR <` in SQL was rejected for plan-shape reasons):

```haskell
ReadStreamBackward (StreamName name) (StreamVersion startVer) limit -> do
    let cursor = if startVer == 0 then maxBound else startVer
    evs <-
        usePool (store ^. #pool) $
            Session.statement (name, cursor, limit) SQL.readStreamBackwardStmt
    liftIO $ decodeEvents (store ^. #storeSettings) evs
```

and identically for `ReadAllBackward` with `startPos`. (`cursor :: Int64`; `maxBound`
resolves at that type.)

**Step 4 — align the docs.** In `kiroku-store/src/Kiroku/Store/Read.hs`, the
`readStreamBackward` haddock (lines 84–88) and `readAllBackward` haddock (lines 115–119)
already state the correct `<` contract; replace the parentheticals "(the SQL treats it as
\"newer than any\")" / "(treated as \"after everything\" by the SQL)" with wording that
matches the implementation, e.g. "(the interpreter maps 0 to the maximum cursor value,
so it never collides with a real version — versions start at 1)".

Acceptance: the two new pagination tests pass; the two pre-existing cursor-0 backward
tests (`test/Main.hs` lines 299–314, 353–360) still pass unchanged; the full
`kiroku-store-test` suite is green.


### Milestone 2 — Empty append batches are rejected before touching the pool

Scope: findings B and G. At the end of this milestone, every append surface rejects an
empty event batch with the typed error `EmptyAppendBatch` before acquiring a pool
connection — so no `$all` lock, no `NOTIFY`, no phantom stream creation — and the
haddocks tell the truth.

**Step 1 — extend the error types.** In `kiroku-store/src/Kiroku/Store/Error.hs`:

- Add to `StoreError` (the sum is documented as additively evolvable):

```haskell
| {- | The caller supplied an empty event batch to an append surface.
  Appending zero events is always a programming mistake: before this
  guard existed, an empty batch silently took the global @$all@ row
  lock, fired NOTIFY triggers, and under 'NoStream' even created an
  empty stream. Rejected in the interpreter before any pool work.
  -}
  EmptyAppendBatch !StreamName
```

- Add the mirror `EmptyAppendBatchConflict !StreamName` to `AppendConflict` (the
  `Tx`-flavored sum at lines 193–204) and extend `appendConflictToStoreError`
  (lines 210–214) with `EmptyAppendBatchConflict sn -> EmptyAppendBatch sn`.
- Export nothing new beyond the constructors (both types already export `(..)`).

**Step 2 — guard the interpreter.** In `kiroku-store/src/Kiroku/Store/Effect.hs`:

- `AppendToStream` branch (line 132): immediately after
  `rejectReservedApplicationStream name`, add

```haskell
case events of
    [] -> throwError (EmptyAppendBatch (StreamName name))
    _ -> pure ()
```

- `AppendMultiStream` branch (line 201): first, short-circuit the empty *operation
  list* — `AppendMultiStream` with `null ops` returns `pure []` before any other work
  (no lock round trip, no transaction). Then, after the existing reserved-name `find`,
  reject the first operation whose event list is empty:

```haskell
case find (\(_, _, evts) -> null evts) ops of
    Just (sn, _, _) -> throwError (EmptyAppendBatch sn)
    Nothing -> pure ()
```

**Step 3 — guard the transactional surface.** In
`kiroku-store/src/Kiroku/Store/Transaction.hs`:

- `appendToStreamTx` (lines 153–164) returns `Either AppendConflict AppendResult` and
  cannot throw; add a guard so `null prepared` returns
  `pure (Left (EmptyAppendBatchConflict sn))` without dispatching any statement.
- `runTransactionAppendingWith` (lines 300–320) already rejects `$all` before opening
  the transaction; add a second guard clause `| null events = pure (Left
  (EmptyAppendBatch sn))` so the wrapper never opens a transaction for an empty batch
  (the continuation is not invoked, matching the `$all` rejection's behavior).

**Step 4 — fix the documentation.**

- `kiroku-store/src/Kiroku/Store/Append.hs` lines 62–68: replace the false "the
  underlying CTE returns 0 rows, which the interpreter maps to a constructor that
  depends on the supplied ExpectedVersion" paragraph with: passing `[]` is rejected
  with `EmptyAppendBatch` before any database work. Add `EmptyAppendBatch` to the
  Errors list above it. Update the `appendMultiStream` haddock (line 104): empty
  *ops list* returns `[]` without a round trip; any per-stream empty *event* list is
  rejected with `EmptyAppendBatch`.
- `Transaction.hs` lines 150–151 ("Empty event lists are a programming mistake — see
  ..."): state that `appendToStreamTx` returns `Left (EmptyAppendBatchConflict …)`
  and `runTransactionAppending*` return `Left (EmptyAppendBatch …)` without opening a
  transaction.
- **Finding G**, same file pass: in `Error.hs`, rewrite the `WrongExpectedVersion`
  haddock (lines 45–50) and the `WrongExpectedVersionConflict` haddock (lines
  193–199) so they no longer claim the actual version is sometimes recovered. Truthful
  wording: "The third field is `StreamVersion 0` on every empty-CTE rejection: the
  append statement returns zero rows on a version mismatch and the store does not
  issue an extra read to recover the actual version. Callers needing the live version
  must read the stream (e.g. `getStream`)."

**Step 5 — tests.** Add a `describe "empty append batches"` group in
`kiroku-store/test/Main.hs` near the `appendToStream` tests (line 99):

- `appendToStream (StreamName "empty-nostream") NoStream []` returns
  `Left (EmptyAppendBatch (StreamName "empty-nostream"))`, **and** `getStream` on that
  name returns `Nothing` (regression for the phantom-stream-creation bug), **and** a
  subsequent `readAllForward (GlobalPosition 0) 10` is unchanged from before the call
  (proves `$all` was untouched).
- Same assertion for `ExactVersion 0`, `StreamExists`, and `AnyVersion` against an
  existing stream: error returned, stream version unchanged.
- `appendMultiStream [(ok, NoStream, [ev]), (bad, NoStream, [])]` returns
  `Left (EmptyAppendBatch bad)` and `getStream ok` is `Nothing` (nothing committed).
- `appendMultiStream []` returns `Right []`.
- In `kiroku-store/test/Test/Transaction.hs`: `runTransactionAppending sn NoStream []
  (\_ -> pure ())` returns `Left (EmptyAppendBatch sn)` and the continuation does not
  run (track with an `IORef`).

Also grep the library and sibling packages for internal callers that could now feed an
empty list into these surfaces (`grep -rn "appendToStream\|appendMultiStream\|appendToStreamTx" --include='*.hs' kiroku-store/src kiroku-cli kiroku-metrics kiroku-jitsurei shibuya-kiroku-adapter`)
and confirm none can pass `[]` structurally; note findings in Surprises & Discoveries.

Acceptance: new tests pass; `cabal build all` is warning-clean for incomplete patterns
(the new constructors are additive — if any in-repo consumer matches exhaustively on
`StoreError`/`AppendConflict`, add the new case there); full suite green.


### Milestone 3 — Typed link errors and one-shot deadlock retry

Scope: findings C and D. At the end of this milestone, `linkToStream` failures are
pattern-matchable, and a single-stream append that loses a deadlock race is retried once
instead of surfacing `UnexpectedServerError "40P01"`.

**Step 1 — link error mapper.** In `kiroku-store/src/Kiroku/Store/Error.hs`:

- Add two `StoreError` constructors:

```haskell
| {- | A 'Kiroku.Store.Link.linkToStream' call tried to link an event
  into a target stream that already contains it. Maps the @23505@
  unique violation on the @stream_events_pkey@ primary key
  (@(event_id, stream_id)@). Carries 'Just' the offending event id
  when the server's detail string was parseable.
  -}
  EventAlreadyLinked !StreamName !(Maybe EventId)
| {- | A 'Kiroku.Store.Link.linkToStream' call referenced an event id
  that does not exist (never appended, or hard-deleted). The link CTE
  surfaces this as a @23502@ not-null violation on
  @stream_events.original_stream_id@; the whole batch rolls back.
  -}
  LinkSourceEventMissing !StreamName
```

- Add and export `mapLinkUsageError :: StreamName -> UsageError -> StoreError`. It walks
  the error with the existing `extractServerError` (lines 340–347): SQLSTATE `23505`
  whose message or detail mentions `stream_events_pkey` maps to `EventAlreadyLinked`;
  SQLSTATE `23502` maps to `LinkSourceEventMissing`; everything else falls back to a
  new shared `mapGenericUsageError :: UsageError -> StoreError` (also used as the
  documented non-append fallback): `ConnectionUsageError → ConnectionLost`,
  `AcquisitionTimeoutUsageError → PoolAcquisitionTimeout`, other server errors →
  `UnexpectedServerError code message`, anything else → `ConnectionError (show …)`.
- Event-id extraction: the composite-key detail reads
  `Key (event_id, stream_id)=(<uuid>, <id>) already exists.` — the existing
  `extractUuidFromDetail` (lines 261–269) uses `T.takeWhile (/= ')')` and therefore
  fails on the composite form. Add a first-component variant (take after `"=("`, then
  `T.takeWhile (\c -> c /= ',' && c /= ')')`, trim, `UUID.fromText`); keep the payload
  `Maybe` so unparseable locales degrade gracefully, mirroring `DuplicateEvent`.

**Step 2 — route the interpreter.** In `Effect.hs`, rewrite the `LinkToStream` branch
(lines 187–195) to stop using `usePool` and map errors itself:

```haskell
LinkToStream (StreamName name) eventIds -> do
    rejectReservedApplicationStream name
    let uuids = V.fromList [uid | EventId uid <- eventIds]
    result <-
        liftIO $
            Pool.use (store ^. #pool) $
                Session.statement (uuids, name) SQL.linkToStreamStmt
    case result of
        Left usageErr -> throwError (mapLinkUsageError (StreamName name) usageErr)
        Right Nothing -> throwError (StreamNotFound (StreamName name))
        Right (Just r) -> pure r
```

Update `kiroku-store/src/Kiroku/Store/Link.hs`'s precondition haddock (lines 33–35) to
name the typed errors instead of describing a raw PK violation.

**Step 3 — tighten the link tests.** In `kiroku-store/test/Main.hs`, the double-link test
(lines 530–538) currently accepts `Left _`; change it to require
`Left (EventAlreadyLinked (StreamName "linked-dup") mEid)` and assert
`mEid == Just eid` (the ephemeral-pg server runs with a C/English locale, so the detail
parse is deterministic in CI). The missing-source tests (lines 545–553 and 555–565)
change from `Left _` to `Left (LinkSourceEventMissing _)`. Their existing no-partial-
commit assertions stay.

**Step 4 — transient-error predicate and retry.** In `Error.hs`, add and export:

```haskell
-- | True iff the error is a PostgreSQL transient transaction abort:
-- SQLSTATE 40001 (serialization_failure) or 40P01 (deadlock_detected).
-- Exactly the codes hasql-transaction's automatic retry recognises.
isTransientSerializationError :: UsageError -> Bool
isTransientSerializationError ue = case extractServerError ue of
    Just (Errors.ServerError code _ _ _ _) -> code == "40001" || code == "40P01"
    Nothing -> False
```

In `Effect.hs`'s `AppendToStream` branch, name the existing `Pool.use … case expected of …`
expression (lines 138–146) `runOnce` and retry it at most once:

```haskell
firstAttempt <- runOnce
result <- case firstAttempt of
    Left usageErr | isTransientSerializationError usageErr -> runOnce
    _ -> pure firstAttempt
```

Idempotency holds because event ids were generated before the first attempt
(`prepareEvents`) and a `40P01`/`40001` victim's transaction committed nothing. Document
the one-shot policy in a comment referencing this plan. Do not add retries anywhere else
— `AppendMultiStream`, `RunTransaction`, and `runTransactionAppending` already go through
`TxSessions.transaction`, which retries these codes internally.

**Step 5 — tests for D.**

- Pure unit test (no database; place beside the `extractStreamNameFromDetail` unit
  tests if present, else in a small new `describe` in `test/Main.hs`):
  `isTransientSerializationError` is `True` for a constructed
  `SessionUsageError (Errors.StatementSessionError 1 0 "" [] True
  (Errors.ServerStatementError (Errors.ServerError "40P01" "deadlock detected" Nothing
  Nothing Nothing)))`, ditto `"40001"`, and `False` for `"23505"` and for
  `AcquisitionTimeoutUsageError`. (All constructors are exported by `Hasql.Errors` and
  `Hasql.Pool` — verified against the hasql source.)
- Best-effort stress regression in `kiroku-store/test/Test/Concurrency.hs` (modeled on
  the existing F11 test, line 216): for ~25 rounds, race
  `appendMultiStream [(a_i, NoStream, [ev]), (b_i, AnyVersion, [ev])]` against
  `appendToStream b_i NoStream [ev]` on fresh names `a_i`/`b_i` via
  `Async.concurrently`. Acceptable outcomes per side: `Right _`,
  `Left (StreamAlreadyExists _)`, `Left (WrongExpectedVersion …)`,
  `Left (StreamNotFound _)`; the assertion is that no outcome is ever
  `Left (UnexpectedServerError code _)` with `code` of `"40P01"`/`"40001"`. This test
  is probabilistic — it may pass vacuously on a fast machine — but it must never fail,
  and before the fix it *can* fail, which is the regression value. Note this
  explicitly in the test's comment.

Acceptance: tightened link tests pass (they fail against the pre-M3 interpreter, which
is the bite-check — run them once before Step 2 to observe
`Left (ConnectionError …)`); predicate unit tests pass; stress test never reports a
transient SQLSTATE; full suite green.


### Milestone 4 — Streaming-read termination, empty-lookup short-circuit

Scope: findings E and F. At the end of this milestone, `readStreamForwardStream` stops
paging as soon as it sees a short page, pages are flattened without an intermediate
list, and `lookupStreamNames []` performs no database work.

**Step 1 — pager.** In `kiroku-store/src/Kiroku/Store/Read.hs`, rewrite
`readStreamForwardStream`'s pager (lines 69–79) to carry a `Maybe`-cursor state so a
short page is the last page:

```haskell
readStreamForwardStream name startVer pageSize =
    Stream.concatMap fromVector pages
  where
    pages = Stream.unfoldrM nextPage (Just startVer)
    nextPage Nothing = pure Nothing
    nextPage (Just cursor) = do
        events <- readStreamForward name cursor pageSize
        if V.null events
            then pure Nothing
            else do
                let nextState
                        | V.length events < fromIntegral pageSize = Nothing
                        | otherwise = Just (V.last events ^. #streamVersion)
                pure (Just (events, nextState))

    fromVector :: Vector a -> Stream (Eff es) a
    fromVector v = Stream.unfoldr (\i -> (,i + 1) <$> v V.!? i) 0
```

(`fromVector` replaces `Stream.fromList . V.toList`; per the Decision Log, streamly-core
0.3 has no built-in `Vector` unfold.) Update the function's haddock: termination is now
"until a page comes back shorter than `pageSize`"; note the one residual case — a stream
whose length is an exact multiple of `pageSize` still pays one final empty probe, which
is unavoidable without knowing the stream length up front.

**Step 2 — empty lookup.** In `Effect.hs`, add a first pattern to the interpreter:

```haskell
LookupStreamNames [] -> pure Map.empty
```

ahead of the general `LookupStreamNames sids` branch (line 181). Update the
`lookupStreamNames` haddock in `Read.hs` (lines 191–192) from "without a database round
trip's worth of work (an empty `ANY(ARRAY[])` matches nothing)" to "without any database
round trip (the interpreter short-circuits)".

**Step 3 — round-trip-count tests.** Both fixes are invisible at the `Store`-effect
boundary, so the tests count pool checkouts via the hasql-pool observation hook (per the
Decision Log). In `kiroku-store/test/Test/ReadStream.hs` (and a small new block for the
lookup), use `withTestStoreSettings` to install a counting handler:

```haskell
ref <- newIORef (0 :: Int)
let handler (ConnectionObservation _ (StatusChangeObservation InUseConnectionStatus)) =
        modifyIORef' ref (+ 1)
    handler _ = pure ()
```

(Names per `Hasql.Pool.Observation`; check the module when writing the test — the
existing `describe "observationHandler"` block in `test/Main.hs` line 1756 shows the
plumbing through `ConnectionSettings.observationHandler`. Each `Pool.use` produces
exactly one `InUseConnectionStatus` transition.) Protocol for a deterministic count:
do all appends first, wait for the publisher to drain (`waitForPublisher` from
`Test.Helpers`) so the notifier/publisher stop using the pool, snapshot the counter,
run the operation under test, snapshot again, assert the delta.

- E: 5 events, `readStreamForwardStream name (StreamVersion 0) 2`, drain with
  `Stream.toList` — delta must be exactly 3 (was 4). Also assert the element results
  unchanged (the existing `Test.ReadStream` behavioral tests already cover order,
  boundaries, nonzero cursor — they must all still pass).
- F: `lookupStreamNames []` — delta must be 0 and the result `Right Map.empty`.
  Companion control: `lookupStreamNames [someRealId]` — delta 1 (proves the
  instrument works).

Acceptance: count tests pass with the exact deltas; all pre-existing
`Test.ReadStream` and `StreamNameLookup` tests pass unchanged; full suite green.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` with the nix
dev shell active (direnv does this automatically; otherwise `nix develop`).

1. Baseline: `cabal build all && cabal test kiroku-store:kiroku-store-test
   --test-show-details=direct` — must be green before starting. Note the test count.
2. M1 step 1 (tests only), then run the bite-check:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "paginates backward"'
```

   Expected: both new tests FAIL with mismatched version lists (newest events returned
   where older ones were expected), similar to:

```text
Failures:
  1) readStreamBackward paginates backward using stream version as an exclusive cursor
       expected: [StreamVersion 3,StreamVersion 2]
        but got: [StreamVersion 5,StreamVersion 4]
2 examples, 2 failures
```

   Capture the real transcript into Surprises & Discoveries.
3. M1 steps 2–4 (SQL predicate, interpreter sentinel, haddocks), then re-run the same
   command — expected `2 examples, 0 failures` — followed by the full suite.
4. Commit (conventional commits, e.g.
   `fix(kiroku-store)!: make backward reads paginate with exclusive < cursors`; the `!`
   is justified — callers that depended on the buggy `>` behavior at nonzero cursors
   will observe different results).
5. M2: error constructors → interpreter guards → Tx guards → docs (incl. finding G) →
   tests. Bite-check trick: write the `NoStream []` test first; against pre-fix code it
   fails with `Right …` and `getStream` returning `Just …` (the phantom stream). Then
   apply the guards and watch it flip. Full suite, commit
   (`feat(kiroku-store): reject empty append batches with EmptyAppendBatch`).
6. M3: run the tightened link tests before changing the interpreter (expected: fail with
   `Left (ConnectionError …)` in the "got" position), then land the mapper + routing +
   retry + predicate unit tests + stress test. Full suite, commit
   (`feat(kiroku-store): typed link errors and one-shot transient append retry`).
7. M4: pager + lookup short-circuit + observation-count tests. Full suite, commit
   (`perf(kiroku-store): stop paying empty-page and empty-lookup round trips`).
8. Finish: `cabal build all && cabal test all` (the sibling packages' suites must also
   stay green — the only cross-package risk is a new `StoreError` constructor reaching
   an exhaustive match, which the build surfaces as `-Wincomplete-patterns`). Optional
   but recommended given the append-path edit:
   `just bench-regression` if `kiroku-store/bench/results/baseline.csv` exists (the
   guard fails on >10% slowdown; a `null`-check guard must not move the needle). Update
   `docs/masterplans/9-…md` Progress (the three EP-4 entries) and this plan's Progress
   and Outcomes sections.


## Validation and Acceptance

The whole plan is validated by the `kiroku-store-test` suite plus targeted behavior
checks. Each item below is phrased as observable behavior with concrete inputs.

- **Backward pagination (A).** Given a stream with versions 1–5, pages of 2 read via
  `readStreamBackward` with cursors `0, 4, 2, 1` return exactly
  `[5,4]`, `[3,2]`, `[1]`, `[]`. Given `$all` with positions 1–3, `readAllBackward`
  with cursors `0, 2, 1` returns `[3,2]`, `[1]`, `[]`. The tests demonstrably failed
  before the fix (transcript recorded in Surprises & Discoveries).
- **Empty batches (B).** `appendToStream s NoStream []` returns
  `Left (EmptyAppendBatch s)` and afterwards `getStream s == Nothing` and the `$all`
  head position is unchanged. Same error for the other three `ExpectedVersion`s with
  no version movement. `appendMultiStream` with one empty per-stream batch commits
  nothing; `appendMultiStream []` returns `Right []`. `runTransactionAppending`
  returns `Left (EmptyAppendBatch s)` without running the continuation.
- **Link errors (C).** Linking the same event twice into the same target yields
  `Left (EventAlreadyLinked target (Just eid))`; linking a never-existing event id
  yields `Left (LinkSourceEventMissing target)`; both with the existing
  no-partial-commit assertions intact. Before the fix the same scenarios yield
  `Left (ConnectionError …)` — run the tightened tests once pre-fix to observe.
- **Deadlock retry (D).** `isTransientSerializationError` unit tests pass for
  `40001`/`40P01` and reject `23505`/timeout. The concurrency stress test never
  surfaces `UnexpectedServerError "40P01"`/`"40001"` from `appendToStream`.
- **Streaming reads (E).** With the pool observation counter quiesced, draining
  `readStreamForwardStream` over 5 events at page size 2 costs exactly 3 pool
  checkouts (4 before the fix), and all pre-existing `Test.ReadStream` assertions
  (order, no duplicates/gaps at page boundaries, nonzero cursor, empty stream) hold.
- **Empty lookup (F).** `lookupStreamNames []` costs 0 pool checkouts and returns
  `Right Map.empty`; `lookupStreamNames [realId]` costs exactly 1.
- **Docs (G and others).** `WrongExpectedVersion` / `WrongExpectedVersionConflict`
  haddocks no longer claim the actual version is sometimes recovered; `Append.hs` no
  longer claims `[]` is mapped via the empty-CTE path; `Read.hs` backward haddocks
  describe the interpreter sentinel; `Link.hs` names the typed errors. Verify with
  `cabal haddock kiroku-store` building cleanly.
- **Suite-level.** `cabal test all` green; `cabal build all` free of new warnings.


## Idempotence and Recovery

Every step is a plain edit to Haskell source plus test additions — no migrations, no
generated files, no destructive operations. All steps can be re-run safely: `cabal test`
is read-only with respect to the repo (ephemeral-pg databases are created and destroyed
per run), and re-applying an already-applied edit is a no-op diff. If a milestone goes
sideways, `git restore` the touched files (each milestone is an independent commit, so
`git revert` of a single milestone is always possible without untangling the others —
this is why the Concrete Steps commit after every milestone).

Two recovery notes. First, M1 changes observable behavior at nonzero backward cursors;
if an unknown consumer depended on the buggy behavior (none exists in this repo —
verified by grep), the revert is the single M1 commit. Second, the M3 stress test is
probabilistic: if it flakes in CI for reasons unrelated to transient SQLSTATEs (e.g.
timeout pressure), reduce rounds or relax timing, but never weaken the
"no `40P01`/`40001` surfaces" assertion — that is the regression it guards.


## Interfaces and Dependencies

No new package dependencies. Everything uses libraries already in
`kiroku-store/kiroku-store.cabal`: `hasql >=1.10 && <1.11` (`Hasql.Errors` exports
`SessionError (..)`, `ServerError (..)` — constructors are buildable in tests),
`hasql-pool >=1.2 && <1.5` (`Hasql.Pool.Observation` for the test counters),
`hasql-transaction >=1.1 && <1.3` (its internal retry of `40001`/`40P01` is the
precedent for M3), `streamly-core >=0.3 && <0.4` (no `Vector` unfold — hence the local
`unfoldr` helper), `effectful-core`, `vector`, `containers`. Dependency sources are on
disk via `mori registry show <project> --full` (hasql family under
`/Users/shinzui/Keikaku/hub/haskell/hasql-project`, streamly under
`…/streamly-project`).

Signatures that must exist at the end of each milestone (full module paths):

- M1: no signature changes; `Kiroku.Store.SQL.readStreamBackwardSQL` /
  `readAllBackwardSQL` use `<`; `Kiroku.Store.Effect.runStorePool`'s backward branches
  map cursor 0 to `maxBound`.
- M2: `Kiroku.Store.Error.StoreError` gains `EmptyAppendBatch !StreamName`;
  `Kiroku.Store.Error.AppendConflict` gains `EmptyAppendBatchConflict !StreamName`;
  `appendConflictToStoreError` covers it. No public function signatures change.
- M3: `Kiroku.Store.Error.StoreError` gains `EventAlreadyLinked !StreamName !(Maybe
  EventId)` and `LinkSourceEventMissing !StreamName`;
  `Kiroku.Store.Error.mapLinkUsageError :: StreamName -> UsageError -> StoreError`,
  `Kiroku.Store.Error.mapGenericUsageError :: UsageError -> StoreError`, and
  `Kiroku.Store.Error.isTransientSerializationError :: UsageError -> Bool` are
  exported (extend the export list at the top of `Error.hs`).
- M4: `Kiroku.Store.Read.readStreamForwardStream :: (HasCallStack, Store :> es) =>
  StreamName -> StreamVersion -> Int32 -> Stream (Eff es) RecordedEvent` — signature
  unchanged, termination contract documented; `LookupStreamNames []` is handled in
  `Kiroku.Store.Effect.runStorePool` without pool access.

Consumers and contracts to respect: the `Store` effect's constructor set
(`Kiroku.Store.Effect.Store`) is unchanged, so mock interpreters keep compiling; the
new `StoreError` constructors are additive (the documented evolution policy), with the
keiro git-pin bump recorded as a post-merge follow-up; and the two MasterPlan-level
constraints — CTE-shaped append SQL and no stream-name field on `RecordedEvent` —
are untouched by design.


---

*Revision note (2026-06-14).* M1 implementation update: recorded the failing
backward-pagination bite-check, marked the M1 progress items complete, added the active
MasterPlan intention to frontmatter, and captured the passing targeted and full
`kiroku-store-test` validation results.
