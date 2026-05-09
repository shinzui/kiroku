---
id: 11
slug: single-stream-runtransaction-combinator
title: "Single-stream RunTransaction combinator"
kind: exec-plan
created_at: 2026-05-09T03:44:25Z
intention: "intention_01kr5da0hjev99rb45j1z8a1pm"
---

# Single-stream RunTransaction combinator


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture


Today, `appendToStream` writes events using a single SQL CTE inside `Hasql.Pool.use`,
with no Haskell-layer transaction wrapping it. A caller who needs to atomically combine
"append events to one stream" with "write a row to my own table" cannot do so through the
public API: they must either fork the `KirokuStore` connection pool themselves and replay
the SQL, or they must serialize the work into two independent Postgres transactions and
hope nothing fails between them.

This ExecPlan adds a public combinator that lets a caller compose a single-stream append
with arbitrary additional `Hasql.Transaction.Transaction` work in one ACID transaction.
The downstream consumer driving this need is `keiro` (a sister project that owns user-facing
projection tables and wants to write a projection row in the same transaction as the event
append).

After this change, a `keiro` engineer can write the following and observe the projection
row land iff the append commits, with one round-trip to Postgres:

    -- pseudo-code, exact API in Interfaces section below
    runTransactionAppending name (ExactVersion v) events $ \appendResult -> do
        Hasql.Transaction.statement
            (myProjectionRow (streamId appendResult) (streamVersion appendResult))
            insertProjectionRowStmt
        pure appendResult

User-visible proof of working behavior:

1. A new HSpec test in `kiroku-store/test/Test/Transaction.hs` (created by this plan)
   appends 3 events plus inserts a row into a test side-table inside one
   `runTransactionAppending` call. It asserts both writes are visible after commit.
2. A second test injects a deliberate `Tx.condemn` (which marks the transaction for rollback)
   inside the callback after a successful append; it asserts that neither the event row
   nor the side-table row is visible after the call returns.
3. A third test triggers a version conflict (`ExactVersion` mismatch). The callback never
   runs, the call returns `Left (WrongExpectedVersion …)`, and the side-table row is
   absent.

The behavior is built on a single new effect constructor — `RunTransaction` — that acts as
a deliberate, named escape hatch from the abstract `Store` effect into Hasql's transactional
SQL world. The high-level convenience wrapper `runTransactionAppending` is implemented in
terms of that escape hatch and a new building block `appendToStreamTx`, which can also be
called directly inside any `RunTransaction` block when the caller needs full control.


## Progress


Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — `RunTransaction` constructor and reinterpretation of existing transactional cases:

- [x] Add `RunTransaction :: Hasql.Transaction.Transaction a -> Store m a` to `Store` in
      `kiroku-store/src/Kiroku/Store/Effect.hs`. *(2026-05-09 — added both `RunTransaction`
      and `RunTransactionNoRetry` to keep the retry/no-retry pair symmetric from day one.)*
- [x] Add the corresponding interpreter branch in `runStorePool` that wraps the user's
      `Transaction a` with `TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write`
      and maps Hasql `UsageError` to `StoreError.ConnectionError`. *(2026-05-09 — extracted
      a private `runTxOnPool` helper parameterised on the
      `transaction`/`transactionNoRetry` entry point so both constructors share one code
      path.)*
- [x] Add public smart constructors `runTransaction` and `runTransactionNoRetry` in the
      new module `Kiroku.Store.Transaction` (per Decision Log entry placing transactional
      surface in its own module). *(2026-05-09)*
- [x] Add a regression-only HSpec test that uses `runTransaction` to execute a no-op
      `Transaction` (`Tx.statement () selectOneStmt`, where `selectOneStmt` is a local
      `SELECT 1::int4`) and observes the expected return value. *(2026-05-09 — wired
      into `kiroku-store/test/Test/Transaction.hs`; full test suite is 102 examples, 0
      failures.)*

Milestone 2 — Public `Tx`-flavored append building block:

- [x] Extract the per-statement dispatch into a Tx-flavored helper
      `appendDispatchTx :: ExpectedVersion -> SQL.AppendParams -> Tx.Transaction (Maybe
      AppendResult)`. *(2026-05-09 — placed in `Kiroku.Store.Effect` next to
      `prepareEvents`/`buildAppendParams`; surfaced under a `-- $internal` haddock
      group. `appendMultiStream`'s inline dispatch is now a one-liner that calls the
      shared helper.)*
- [x] Add public combinator `appendToStreamTx :: StreamName -> ExpectedVersion ->
      [PreparedEvent] -> UTCTime -> Hasql.Transaction.Transaction (Either AppendConflict
      AppendResult)` exported from `Kiroku.Store.Transaction`. Add `AppendConflict` and
      `appendConflictToStoreError` to `Kiroku.Store.Error`, plus a pure
      `emptyResultConflict` helper that mirrors the existing `emptyResultError`
      semantics. *(2026-05-09)*
- [x] **`AppendToStream` interpreter left unchanged.** *(2026-05-09 — see Decision Log
      entry on the M2 plan-text contradiction. The existing `Session.statement`-based
      single-CTE path is preserved; only `appendMultiStream` now uses the shared
      Tx-flavored dispatch.)*
- [x] Tests in `kiroku-store/test/Test/Transaction.hs` driving `appendToStreamTx` directly
      inside `runTransaction`: success-with-side-row, condemn-after-success rolling back
      both the append and the side row, and version-conflict returning `Left`. *(2026-05-09
      — full test suite is now 105 examples, 0 failures.)*

Milestone 3 — Convenience wrapper for the keiro use case:

- [x] Add `runTransactionAppending` and `runTransactionAppendingNoRetry` to
      `Kiroku.Store.Transaction`. Both reject `$all` up front, prep UUIDv7 ids and
      `getCurrentTime` in `Eff`, call `appendToStreamTx` inside the transaction body,
      `Tx.condemn` on `Left AppendConflict`, and run the caller's continuation on
      `Right AppendResult`. The retry/no-retry pair is implemented via a shared
      `runTransactionAppendingWith` that takes a rank-N `Store` constructor argument.
      *(2026-05-09 — added `IOE :> es` to both wrapper signatures; see Decision Log
      entry on the constraint that the plan's interface sketch missed.)*
- [x] Tests in `kiroku-store/test/Test/Transaction.hs`: success path (3 events + side
      row, version 3, both visible), callback-condemn path (Right return value but
      both writes rolled back), version-conflict path (`Right (Left
      WrongExpectedVersion)`, side row absent), reserved-stream rejection (`Right
      (Left (ReservedStreamName \"$all\"))`, side row absent). *(2026-05-09)*
- [x] Document the chosen retry mode (`transaction` vs `transactionNoRetry`) and its
      consequences in the Haddock for `runTransactionAppending` and `runTransaction`.
      *(2026-05-09 — module-level prose plus per-binding notes on retry, condemn,
      reserved-stream rejection ordering, and the IO/Tx prep boundary.)*

Milestone 4 — Public surface and documentation:

- [ ] Re-export `Kiroku.Store.Transaction` from `kiroku-store/src/Kiroku/Store.hs`.
- [ ] Update Haddock module headers so the difference between
      `appendToStream` (Pool, no Haskell-layer txn) and `runTransactionAppending`
      (txn-aware) is unambiguous to a first-time reader.
- [ ] Add a `CHANGELOG.md` entry (kiroku-store) describing the new public surface.


## Surprises & Discoveries


Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-05-09 — The `kiroku-store:bench:kiroku-shibuya-overhead` benchmark fails to
  compile on `master` independently of this plan: `bench/ShibuyaOverhead.hs:209`
  builds an `Envelope` whose `attributes` strict field is missing (the upstream
  `hs-opentelemetry-api` shape changed). Confirmed pre-existing via `git stash &&
  cabal build kiroku-store:bench:kiroku-shibuya-overhead`. Out of scope for this
  plan; targeted builds of `lib:kiroku-store` and `test:kiroku-store-test` are
  used for verification.


## Decision Log


- Decision: Adopt Option C — a single `RunTransaction` effect constructor plus public
  `Tx`-flavored building blocks — rather than Option A (a constructor whose callback returns
  `Tx.Transaction a`) or Option B (a standalone combinator outside the effect).
  Rationale: Option A scatters Hasql types across multiple `Store` constructors, one per
  use case; Option B leaks no Hasql into the effect but offers no extension point for future
  transactional operations (link-in-txn, multi-append-in-txn, etc.). Option C centralizes
  the "Hasql leak" in exactly one named escape hatch (`RunTransaction`) and lets us grow
  the family of `*Tx` building blocks without touching the effect ADT again. The cost is a
  documented limitation: mock/in-memory `Store` interpreters cannot meaningfully execute an
  opaque `Tx.Transaction a` and must reject `RunTransaction` (see Costs section in Plan of
  Work).
  Date: 2026-05-09

- Decision: Place public Tx-flavored building blocks in a new module
  `Kiroku.Store.Transaction`, not in `Kiroku.Store.Append`.
  Rationale: `Kiroku.Store.Append` currently exports two functions (`appendToStream`,
  `appendMultiStream`) and its haddock describes them as the "default, non-transactional"
  surface. Mixing transactional combinators in would muddy that contract. A separate module
  also gives us a natural home for future `linkToStreamTx`, `softDeleteStreamTx`, etc.,
  if and when they are needed.
  Date: 2026-05-09

- Decision: Drop the `StreamId` parameter from the user-supplied callback that the original
  sketch carried as `(StreamId -> AppendResult -> Hasql.Transaction.Transaction a)`.
  Rationale: `AppendResult` already carries `streamId :: StreamId` (`Types.hs:225-237`). The
  callback signature simplifies to `(AppendResult -> Hasql.Transaction.Transaction a)`
  without information loss.
  Date: 2026-05-09

- Decision: Surface append conflicts through an `Either AppendConflict AppendResult` return
  in `appendToStreamTx` rather than via `Tx.condemn` + a sentinel value, and rather than
  via a typeclass-based throw mechanism.
  Rationale: `Hasql.Transaction.Transaction` is `newtype Transaction = Transaction (StateT
  Bool B.Session a)` with no user-exception channel — failures are surfaced either by
  raising a Hasql `UsageError` (commit-time) or by calling `Tx.condemn` (which sets the
  state to mark the transaction for rollback at commit). Returning `Either` lets the caller
  decide whether to `Tx.condemn`, branch around the conflict, or attempt a recovery action.
  The convenience wrapper `runTransactionAppending` lifts this into `Either StoreError a`
  at the `Eff` boundary, matching how the rest of `Store` already reports errors.
  Date: 2026-05-09

- Decision: Default to `TxSessions.transaction` (with automatic Postgres-conflict retry)
  inside the `RunTransaction` interpreter, but expose a sibling `runTransactionNoRetry`
  using `TxSessions.transactionNoRetry`.
  Rationale: `transaction` matches what `appendMultiStream`/`HardDeleteStream` already do
  (`Effect.hs:163-166, 196-198`). However, automatic retry runs the user's `Transaction a`
  *more than once* under serialization conflicts, which is fine for pure SQL but hazardous
  if the caller has been promised "exactly once" semantics. `Transaction` has no `MonadIO`
  so the body cannot embed IO side effects directly, but a caller could still observe
  multiple writes (each retry's prior partial work rolls back; the new attempt runs again).
  Document the retry behavior loudly and offer the no-retry sibling for callers that need
  it. Use `ReadCommitted` isolation as the default (mirrors existing transactional sites).
  Date: 2026-05-09

- Decision: During M2, leave the existing `AppendToStream` interpreter branch unchanged
  rather than re-routing it through the new Tx-flavored helper.
  Rationale: The plan text simultaneously asks to "Re-implement the `AppendToStream`
  constructor's interpreter branch in terms of `appendPreparedTx` running under a
  one-statement `Tx.Transaction` inside `Pool.use`" and to "Keep `Pool.use`-based
  dispatch (no `TxSessions.transaction`) as the default — wrapping a single statement
  in a transaction would change retry semantics and is out of scope." These cannot
  both hold: a `Tx.Transaction` value can only be executed by `TxSessions.transaction`
  / `transactionNoRetry`. Resolving in favor of the second clause preserves production
  retry semantics. The shared `appendDispatchTx` helper still benefits the
  `appendMultiStream` interpreter (which already runs inside a `Tx.Transaction`) and
  the new public `appendToStreamTx`. The duplication between `appendDispatchTx` and
  the inline `case expected of …` in `AppendToStream` is four lines and entirely
  mechanical.
  Date: 2026-05-09

- Decision: `runTransactionAppending` (and the no-retry sibling) carry an `IOE :> es`
  constraint in addition to `Store :> es`.
  Rationale: The plan's Interfaces section sketched the signature with only `Store :> es`,
  but the wrapper must call `liftIO getCurrentTime` and `prepareEventsIO` (a `MonadIO`
  helper) before entering the transaction body. `Tx.Transaction` has no `MonadIO` so this
  prep cannot move inside. In practice, every caller that can interpret `Store` already
  carries `IOE :> es` (the production interpreter `runStorePool` requires it), so adding
  the constraint surfaces what was already implied without expanding requirements. The
  alternative — bundling the prep into a new `Store` constructor — was considered but
  rejected as adding more constructors to absorb behavior that belongs in the wrapper.
  Date: 2026-05-09

- Decision: `AppendConflict` does not include a `ReservedStreamConflict` constructor.
  Rationale: `appendToStreamTx` does not enforce reserved-stream rejection — that is the
  caller's responsibility (or `runTransactionAppending`\'s, which checks before opening
  the transaction). Inside the transaction body, by the time
  `appendDispatchTx` runs, the stream name has already been accepted at the SQL layer;
  there is no path that surfaces `ReservedStreamConflict` from `appendToStreamTx`. The
  high-level wrapper surfaces `Kiroku.Store.Error.ReservedStreamName` directly without
  going through `AppendConflict`.
  Date: 2026-05-09

- Decision: Mock/in-memory `Store` interpreters are out of scope for this plan and will
  reject `RunTransaction` with a runtime error.
  Rationale: A mock interpreter has no way to execute an opaque `Tx.Transaction a` against
  in-memory state. The honest options are (i) reject — clear error, undeniable contract;
  (ii) require parallel pure building blocks for each `Tx`-flavored operation, doubling
  surface area. We pick (i) for now; if a serious mocking need emerges, revisit with a
  separate plan.
  Date: 2026-05-09


## Outcomes & Retrospective


Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation


This section assumes no prior knowledge of `kiroku-store`, `effectful`, or `hasql`. Read
the named files in order before editing.

### What kiroku-store is

`kiroku-store` is the Haskell event-store library at `kiroku-store/` in this repository.
It exposes a typed effect (`Store`, defined in `kiroku-store/src/Kiroku/Store/Effect.hs`)
with operations to append, read, link, and delete streams of events stored in PostgreSQL.
Callers run programs in the `effectful` framework's `Eff` monad and interpret the `Store`
effect against PostgreSQL using `runStorePool`. The interpreter currently uses two
different connection-acquisition styles depending on whether the operation is transactional:

- Most operations use `usePool :: Pool -> Hasql.Session.Session a -> Eff es a`
  (`Effect.hs:233-242`), which calls `Hasql.Pool.use pool session`. A `Hasql.Session.Session`
  is a sequence of one or more SQL statements run on a single connection, but **without** a
  surrounding `BEGIN ... COMMIT` from the Haskell side. Each `Session.statement` inside is
  its own implicit transaction. `appendToStream` (`Effect.hs:76-96`) uses this style: the
  whole append is one CTE-based SQL statement that does the version check and the insert
  atomically inside Postgres.
- Two operations — `appendMultiStream` (`Effect.hs:124-179`) and `HardDeleteStream`
  (`Effect.hs:184-206`) — run multiple SQL statements as a single Haskell-layer transaction
  by calling `Hasql.Transaction.Sessions.transaction TxSessions.ReadCommitted
  TxSessions.Write txn`, where `txn :: Hasql.Transaction.Transaction a`. This wraps the
  body in `BEGIN ... COMMIT` and (with the default `transaction` entry point) retries on
  PostgreSQL serialization conflicts.

There is currently no public way for a caller to add their **own** `Hasql.Transaction`
work alongside an `appendToStream`. That gap is what this plan closes.

### What hasql-transaction looks like

`hasql-transaction` is a third-party library located on disk at
`/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-transaction` (registered with
mori). The relevant modules and types:

- `Hasql.Transaction` (`src/library/Hasql/Transaction.hs`) re-exports
  the `Transaction` newtype, `condemn`, `sql`, and `statement`.
- `Hasql.Transaction.Private.Transaction` defines:

      newtype Transaction a = Transaction (StateT Bool B.Session a)
        deriving (Functor, Applicative, Monad)

      statement :: a -> Hasql.Statement.Statement a b -> Transaction b
      sql       :: ByteString -> Transaction ()
      condemn   :: Transaction ()      -- sets the state Bool to False;
                                       -- transaction rolls back at commit time

  Critically, **`Transaction` has no `MonadIO` instance**. You cannot call `liftIO` inside
  it. Any IO (UUID generation, `getCurrentTime`) must happen *outside* the transaction
  body, with the prepared values passed in as parameters.

- `Hasql.Transaction.Sessions` exposes:

      transaction        :: IsolationLevel -> Mode -> Transaction a -> Hasql.Session.Session a
      transactionNoRetry :: IsolationLevel -> Mode -> Transaction a -> Hasql.Session.Session a

  `transaction` retries automatically on PostgreSQL conflict errors (the body may run more
  than once). `transactionNoRetry` does not retry. Both ultimately call into
  `Hasql.Transaction.Private.Sessions.inRetryingTransaction`.

### Term definitions

- "Hasql session" — a `Hasql.Session.Session a` value: a sequence of SQL statements run
  against one pool connection. Run via `Hasql.Pool.use pool session`. Not transactional
  from the Haskell side; each statement commits independently.
- "Hasql transaction" — a `Hasql.Transaction.Transaction a` value run via
  `Hasql.Transaction.Sessions.transaction`, which wraps execution in `BEGIN`/`COMMIT` on a
  single connection.
- "Effectful constructor" — a data constructor inside `data Store :: Effect where ...`.
  Each constructor names an operation; the `interpret_` block in `runStorePool` pattern-
  matches on each constructor to give it meaning.
- "ExpectedVersion" — `kiroku-store/src/Kiroku/Store/Types.hs` defines
  `data ExpectedVersion = ExactVersion StreamVersion | StreamExists | NoStream | AnyVersion`.
  It is the precondition the SQL CTE checks before allowing an append. The CTE returns 0
  rows if the precondition fails; the interpreter maps that empty result to a typed error.
- "AppendResult" — `Types.hs:225-237`: `AppendResult { streamId :: StreamId,
  streamVersion :: StreamVersion, globalPosition :: GlobalPosition }`. Already carries the
  stream id, which is why we drop it from the callback signature.
- "Reserved stream" — `$all` is the global read stream and cannot be appended to as an
  application stream. Existing operations call `rejectReservedApplicationStream`
  (`Effect.hs:248-254`) before doing any work; this plan must do the same.

### Files this plan will touch

Reading list, in order:

1. `kiroku-store/src/Kiroku/Store/Effect.hs` — the `Store` effect ADT and `runStorePool`.
2. `kiroku-store/src/Kiroku/Store/Append.hs` — the public `appendToStream` /
   `appendMultiStream` smart constructors.
3. `kiroku-store/src/Kiroku/Store/Types.hs` — `AppendResult`, `StreamId`, etc.
4. `kiroku-store/src/Kiroku/Store/SQL.hs` — the four `appendExpectedVersion`,
   `appendStreamExists`, `appendNoStream`, `appendAnyVersion` `Statement`s used inside the
   transactional and non-transactional append paths.
5. `kiroku-store/src/Kiroku/Store/Error.hs` — `StoreError`, `mapUsageError`,
   `emptyResultError`. We will add `AppendConflict` here.
6. `kiroku-store/src/Kiroku/Store.hs` — the umbrella module that re-exports the public API.
7. `kiroku-store/test/Main.hs` and `test/Test/*.hs` — existing test patterns to follow.


## Plan of Work


The work is broken into four milestones. Each ends in a state where the test suite is
green and the codebase compiles cleanly. Costs and hazards are listed up front so they
inform every milestone's design decisions.

### Costs and Hazards (read first)

1. **`Store` effect now leaks Hasql types.** `RunTransaction :: Hasql.Transaction.Transaction
   a -> Store m a` references a third-party library type in the abstract effect ADT. Any
   future re-implementation of `Store` (in-memory mock, alternate database backend) must
   either reject `RunTransaction` at runtime or supply a way to interpret arbitrary
   `Hasql.Transaction` values, which is not generally possible. Documented and accepted.
2. **UUID and timestamp prep cannot live inside `Tx.Transaction`.** `Transaction` lacks
   `MonadIO`. `appendToStreamTx` therefore takes pre-prepared events and a pre-captured
   `UTCTime`. The convenience wrapper `runTransactionAppending` does this prep in `Eff`
   before calling `RunTransaction`.
3. **Automatic retry under `TxSessions.transaction` may run the user's callback more than
   once.** The current default. While the body is pure-SQL, "writes happen twice in the
   log" is not literally true (each retry's prior partial work is rolled back), but a
   reader-after-write side test from outside the txn scope could see attempt N's partial
   state vs attempt N+1's. Surface this with a sibling `runTransactionNoRetry`/
   `runTransactionAppendingNoRetry` and document loudly.
4. **Two ways to append now coexist** — the existing `appendToStream` (Pool, no Haskell-
   layer txn) and `runTransactionAppending` (txn-aware). Documentation must steer callers
   to the correct one. Default guidance: use `appendToStream` unless you need to combine
   the append with other SQL atomically.
5. **Conflict semantics inside the txn are caller-driven.** `appendToStreamTx` returns
   `Either AppendConflict AppendResult`. Callers who don't `Tx.condemn` after a `Left` will
   commit a transaction containing only their own side-table writes (no event append). The
   `runTransactionAppending` wrapper inverts this default: a `Left` result causes
   `Tx.condemn` and surfaces a `StoreError` at the `Eff` boundary; the callback is never
   invoked.
6. **Tests must run a real Postgres.** All tests in this plan extend the existing
   `kiroku-store/test/Main.hs` flow, which already provisions ephemeral Postgres via
   `shinzui/ephemeral-pg`. No new test infrastructure required.
7. **`KirokuEvent` observability is not extended in this plan.** Existing events
   (`KirokuEventHardDeleteIssued`, etc.) fire from specific interpreter branches.
   `RunTransaction` does not know what the caller's transaction "did", so we emit no event
   from the constructor branch itself. Callers can emit their own events from inside the
   transaction body if needed.

### Milestone 1 — Effect constructor and minimal wiring

Scope: introduce `RunTransaction` as a new constructor on `Store` and a smart constructor
`runTransaction` that ships it. Validate by writing a one-statement test that exercises
the wiring end-to-end. No semantic changes to existing operations.

What exists at the end: a caller can write

    runTransaction $ do
        Tx.statement () SQL.someTrivialStmt

inside an `Eff` program with `Store :> es` and have it commit. On `UsageError`, the call
raises `StoreError.ConnectionError`.

Files edited:

- `kiroku-store/src/Kiroku/Store/Effect.hs`: add `RunTransaction` constructor; add interpreter
  branch.
- `kiroku-store/src/Kiroku/Store/Transaction.hs` (new file): export `runTransaction` smart
  constructor.
- `kiroku-store/src/Kiroku/Store.hs`: add the new module to umbrella exports.
- `kiroku-store/kiroku-store.cabal`: list the new module under `exposed-modules`.
- `kiroku-store/test/Test/Transaction.hs` (new file): single-statement smoke test.
- `kiroku-store/test/Main.hs`: register the new test module.

Acceptance: `cabal test kiroku-store-tests` (or `bun run test` if a top-level script
exists — see Concrete Steps for the canonical command) passes including the new test.

### Milestone 2 — `appendToStreamTx` building block

Scope: extract the per-`ExpectedVersion` dispatch from the existing `AppendToStream`
interpreter branch into a `Hasql.Transaction.Transaction`-flavored helper, and expose it
publicly so callers inside `runTransaction` blocks can append.

What exists at the end: `appendToStreamTx :: StreamName -> ExpectedVersion ->
[PreparedEvent] -> UTCTime -> Hasql.Transaction.Transaction (Either AppendConflict
AppendResult)` is exported from `Kiroku.Store.Transaction`. The existing `AppendToStream`
interpreter branch has been re-implemented to call this helper inside a one-shot
`Hasql.Session.Session` (without `TxSessions.transaction`). All existing append tests
pass without modification.

New type: `data AppendConflict = WrongExpectedVersion StreamName ExpectedVersion |
StreamNotFoundConflict StreamName | StreamAlreadyExistsConflict StreamName |
ReservedStreamConflict StreamName` (or reuse existing `StoreError` constructors —
see Decision Log). Final shape decided during implementation; the public wrapper translates
to `StoreError`.

Files edited:

- `kiroku-store/src/Kiroku/Store/Effect.hs`: extract per-`ExpectedVersion` dispatch into a
  helper that returns `Tx.Transaction (Maybe AppendResult)`.
- `kiroku-store/src/Kiroku/Store/Transaction.hs`: export `appendToStreamTx` and the
  `AppendConflict` shape.
- `kiroku-store/src/Kiroku/Store/Error.hs`: add `AppendConflict` if introduced as a
  separate type, plus a converter `appendConflictToStoreError :: AppendConflict ->
  StoreError`.
- `kiroku-store/test/Test/Transaction.hs`: tests that drive `appendToStreamTx` directly
  inside `runTransaction`, including a `Tx.condemn`-after-success case.

Acceptance: existing append test suite (`test/Main.hs:536+` and the single-stream describes)
passes without modification. New tests in `test/Test/Transaction.hs` pass. `appendToStream`
behavior in production is unchanged.

### Milestone 3 — Convenience wrapper `runTransactionAppending`

Scope: wire the building blocks into a single high-ergonomics combinator that is the
intended primary API for keiro and similar consumers.

What exists at the end:

    runTransactionAppending
      :: (HasCallStack, Store :> es)
      => StreamName
      -> ExpectedVersion
      -> [EventData]
      -> (AppendResult -> Hasql.Transaction.Transaction a)
      -> Eff es (Either StoreError a)

is exported from `Kiroku.Store.Transaction`. The implementation:

1. Calls `rejectReservedApplicationStream` before doing any IO.
2. In `Eff`: generates UUIDv7 event ids for any event lacking one (via `prepareEvents`),
   captures `getCurrentTime`.
3. Calls `RunTransaction $ do appendResult <- appendToStreamTx ...; case appendResult of
   Left c -> Tx.condemn $> Left (appendConflictToStoreError c); Right ar -> Right <$> k ar`.
4. Maps the resulting `Either StoreError a` to the caller.

A sibling `runTransactionAppendingNoRetry` is exported with identical signature, using
`TxSessions.transactionNoRetry` under the hood.

Files edited:

- `kiroku-store/src/Kiroku/Store/Transaction.hs`: implement the wrapper(s).
- `kiroku-store/test/Test/Transaction.hs`: end-to-end tests (success, condemn-by-callback,
  version conflict, reserved stream).

Acceptance: tests pass, including a test that creates a side table inside the test setup,
appends 3 events plus inserts a side-table row inside `runTransactionAppending`, and
asserts both writes are visible after commit; and a test that triggers a version conflict
and asserts the side-table row is absent.

### Milestone 4 — Public surface and documentation

Scope: ensure the new module is reachable from `import Kiroku.Store`, that the haddocks on
the existing `appendToStream` and the new combinators describe their relationship clearly,
and that the change is captured in the changelog.

Files edited:

- `kiroku-store/src/Kiroku/Store.hs`: re-export `Kiroku.Store.Transaction`.
- `kiroku-store/src/Kiroku/Store/Append.hs`: add a "When to use this vs.
  `runTransactionAppending`" haddock paragraph to `appendToStream`.
- `kiroku-store/src/Kiroku/Store/Transaction.hs`: full haddock module-level prose covering
  retry semantics, conflict handling, mock-interpreter caveat, and a worked example.
- `kiroku-store/CHANGELOG.md` (or whichever changelog convention the package uses; verify
  before editing): note the new public surface.

Acceptance: `cabal haddock kiroku-store` produces no warnings about the new module; a
human reading the new haddock can answer "should I use `appendToStream` or
`runTransactionAppending` here?" without consulting other documents.


## Concrete Steps


All commands are run from the repository root unless stated otherwise.

### Build the package

    cabal build kiroku-store

Expected output: `Building library 'kiroku-store' ...` followed by `Linking ...` and a
clean exit.

### Run the test suite

    cabal test kiroku-store --test-show-details=streaming

Expected output ends with a summary line of the form:

    All N tests passed (X.YZs)

If the kiroku project uses a different canonical test entry point (e.g., a `bun` or `just`
script defined in repo tooling), prefer that. Verify with:

    grep -rE "cabal test|bun run test|just test" Justfile package.json bun.lockb 2>/dev/null

### Inspect the new effect surface

After Milestone 1:

    grep -n "RunTransaction\b" kiroku-store/src/Kiroku/Store/Effect.hs

Expected: at least two hits — the constructor declaration and the interpreter branch.

After Milestone 3:

    grep -n "runTransactionAppending" kiroku-store/src/Kiroku/Store/Transaction.hs

Expected: the function signature plus body, plus an export-list entry.

### Validate the worked example

After Milestone 3, the new test file `kiroku-store/test/Test/Transaction.hs` should
contain three or more `it` blocks. Run only the transaction tests:

    cabal test kiroku-store --test-options="--match \"runTransactionAppending\""

Expected output: each `it` description followed by `OK`, with no `FAIL` lines.


## Validation and Acceptance


The change is effective when **all** of the following are observed.

1. **Compilation.** `cabal build kiroku-store` succeeds with no new warnings.

2. **Backwards compatibility.** The pre-existing test suite (everything in
   `kiroku-store/test/Main.hs` and `kiroku-store/test/Test/*.hs` that existed before this
   plan) passes unchanged. No test was modified to accommodate the new code.

3. **End-to-end success path.** A new test in `kiroku-store/test/Test/Transaction.hs`
   does the following inside one `runTransactionAppending` call:

       SQL setup (in test fixture):
           CREATE TABLE test_side_table (id BIGINT PRIMARY KEY, payload TEXT NOT NULL);

       Test body:
           result <- runStoreIO store $ runTransactionAppending
               (StreamName "txn-success-1") NoStream
               [makeEvent "Created" (object ["x" .= 1])]
               (\appendResult -> do
                   let StreamId sid = streamId appendResult
                   Tx.statement (sid, "hello") insertSideRowStmt
                   pure appendResult)

   Expected: `result` is `Right (Right ar)` (outer `Right` from `runStoreIO`'s
   `Either StoreError`, inner `Right` from `runTransactionAppending`'s
   `Either StoreError`); both the events row and the `test_side_table` row are visible to
   a follow-up read.

4. **Callback-condemn rolls back.** A second test runs the same shape but the callback
   calls `Tx.condemn` after writing to `test_side_table`. Expected: `runTransactionAppending`
   returns successfully with whatever the callback returned, but no events are visible
   on the stream and the side row is absent.

5. **Version conflict skips the callback.** A third test pre-populates the stream with one
   event, then calls `runTransactionAppending` with `ExactVersion (StreamVersion 99)` and
   a callback that increments a shared `IORef`. Expected: `Right (Left
   (WrongExpectedVersion …))`, the `IORef` is unchanged (callback never ran), and no
   side-table row exists.

6. **Reserved stream rejected before opening the transaction.** A fourth test calls
   `runTransactionAppending (StreamName "$all") AnyVersion [evt] cb`. Expected:
   `Right (Left (ReservedStreamName (StreamName "$all")))`; no side-table writes occur
   because the transaction was never opened.

7. **`runTransaction` standalone use.** A fifth test runs `runTransaction $ do
   Tx.statement () SQL.selectVersionStmt` and confirms the return value is the
   PostgreSQL server version string. Validates the bare escape hatch works.

8. **Haddock cleanliness.** `cabal haddock kiroku-store` reports no missing-doc warnings
   for any new exported identifier.


## Idempotence and Recovery


Every step in this plan is additive. No SQL schema changes, no migrations, no destructive
edits to existing public APIs. The implementer can:

- Re-run `cabal build` and `cabal test` arbitrarily; tests provision their own ephemeral
  Postgres via `shinzui/ephemeral-pg` and tear it down between runs.
- Revert any milestone independently by `git revert` of its commits — the milestones
  produce strictly additive surface area until Milestone 4's haddock edits.
- If Milestone 2's refactor of the `AppendToStream` interpreter branch introduces a
  regression, the safest recovery is to revert that single commit; the prior CTE-based
  branch is the authoritative behavior. The new public `appendToStreamTx` can still be
  shipped as a parallel implementation and the existing branch left untouched if the
  refactor proves risky.

If a partial Milestone 3 ships `runTransactionAppending` without the no-retry sibling, the
plan can be resumed from that state — the Decision Log records the obligation, and the
sibling is purely additive.


## Interfaces and Dependencies


### Final public surface

After Milestone 4, the following identifiers are exported from
`Kiroku.Store.Transaction` and re-exported from `Kiroku.Store`:

    -- The escape hatch.
    runTransaction
      :: (HasCallStack, Store :> es)
      => Hasql.Transaction.Transaction a
      -> Eff es a

    runTransactionNoRetry
      :: (HasCallStack, Store :> es)
      => Hasql.Transaction.Transaction a
      -> Eff es a

    -- The Tx-flavored building block.
    appendToStreamTx
      :: StreamName
      -> ExpectedVersion
      -> [PreparedEvent]            -- caller pre-prepares (UUID v7 ids)
      -> UTCTime                    -- caller captures createdAt
      -> Hasql.Transaction.Transaction (Either AppendConflict AppendResult)

    -- The convenience wrapper (primary API for keiro).
    runTransactionAppending
      :: (HasCallStack, Store :> es)
      => StreamName
      -> ExpectedVersion
      -> [EventData]
      -> (AppendResult -> Hasql.Transaction.Transaction a)
      -> Eff es (Either StoreError a)

    runTransactionAppendingNoRetry
      :: (HasCallStack, Store :> es)
      => StreamName
      -> ExpectedVersion
      -> [EventData]
      -> (AppendResult -> Hasql.Transaction.Transaction a)
      -> Eff es (Either StoreError a)

    data AppendConflict
      = WrongExpectedVersion StreamName ExpectedVersion
      | StreamNotFoundConflict StreamName
      | StreamAlreadyExistsConflict StreamName
      | ReservedStreamConflict StreamName

    appendConflictToStoreError :: AppendConflict -> StoreError

`PreparedEvent` is currently a private type in `Kiroku.Store.Effect`. To expose
`appendToStreamTx`, it must be either (a) promoted to a public type in
`Kiroku.Store.Types` or (b) wrapped in a public `newtype` in `Kiroku.Store.Transaction`
that constructs from `[EventData]` plus IO-prepared event ids. Decide during Milestone 2.

### New private/internal surface

Added to `Kiroku.Store.Effect`:

    data Store :: Effect where
        ...existing constructors...
        RunTransaction :: Hasql.Transaction.Transaction a -> Store m a

    -- Interpreter branch in runStorePool:
    RunTransaction tx -> do
        result <- liftIO $ Pool.use (store ^. #pool) $
            TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write tx
        case result of
            Left usageErr -> throwError (ConnectionError (T.pack (show usageErr)))
            Right a       -> pure a

A `RunTransactionNoRetry` constructor sibling is added, identical except for using
`TxSessions.transactionNoRetry`.

### Dependencies

No new dependencies. `kiroku-store.cabal` already lists `hasql`, `hasql-pool`,
`hasql-transaction` (verified via `mori show --full` against
`shinzui/kiroku/packages/kiroku-store`). The new module simply uses APIs that are already
in-tree.

### Backwards compatibility

`appendToStream` and `appendMultiStream` keep their current signatures and behavior. The
existing test suite must pass unchanged. The new module is purely additive; no caller is
forced to migrate.
