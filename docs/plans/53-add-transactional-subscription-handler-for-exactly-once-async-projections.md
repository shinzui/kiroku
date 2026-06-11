---
id: 53
slug: add-transactional-subscription-handler-for-exactly-once-async-projections
title: "Add transactional subscription handler for exactly-once async projections"
kind: exec-plan
created_at: 2026-06-03T14:43:05Z
intention: "intention_01kt6yzdtve4h97er05ygf03jv"
---

# Add transactional subscription handler for exactly-once async projections

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A "subscription" in this repository is a long-running worker that walks the event
log forward and hands each stored event to a user-supplied function called a
"handler". A "projection" is the common use of a subscription: the handler writes
some derived state into its own SQL table (a "read model") so the application can
query it cheaply. A "checkpoint" is the durable record of how far the worker has
gotten: a row in the `subscriptions` table whose `last_seen` column holds the
global position of the last event the worker finished. When the worker restarts,
it resumes from `last_seen + 1`.

Today the handler runs in one database connection and the checkpoint advance runs
in a *different* database connection, one after the other. If the process crashes
after the handler's projection write commits but before the checkpoint advance
commits, the worker restarts, re-reads the same event, and applies it a second
time. That is "at-least-once" delivery: every event is delivered one or more
times, so a projection handler must be written defensively (idempotently) to
tolerate seeing the same event twice. There is no way today to get "exactly-once"
delivery, where each event's effect on the read model lands exactly one time.

After this change, a subscriber can opt into a new handler shape whose SQL writes
and the worker's checkpoint advance commit together in **one** PostgreSQL
transaction. A crash can no longer land between the projection write and the
checkpoint: either both commit or neither does. The handler author no longer has
to make the projection idempotent to be correct. Concretely, a downstream
consumer (for example the `keiro` framework's async-projection worker, which
calls kiroku-store directly) can build a read model that is provably never
double-applied and never skipped.

You will be able to see it working by running a new test that: (1) drives a
transactional handler that inserts one projection row per event plus advances the
checkpoint, and asserts the read-model row count equals the event count and the
checkpoint equals the last event's position; and (2) drives a handler that
*aborts* (signals retry or dead-letter) and asserts the projection row it
attempted to write is **not** present in the table afterward — proving the write
and the checkpoint share a transaction that rolled back together.

This plan is scoped to the **kiroku-store** package. It deliberately does *not*
change `shibuya-kiroku-adapter` or `shibuya-core`; the "Plan of Work" explains
why exactly-once through the Shibuya adapter needs a separate upstream change and
why the direct kiroku-store consumer (keiro) does not need it.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add the transactional handler type `EventHandlerTx` and the optional
  `handlerTx` field on `SubscriptionConfig`, defaulting to `Nothing`; re-export
  the type. Existing build and tests unaffected.
- [ ] M2: Add the `Tx.Transaction`-flavored checkpoint helper and the worker's
  transactional delivery path in `processEvents` / `deliver`, gated on
  `handlerTx` being present.
- [ ] M3: Confirm `subscribe` needs no signature change (the config field is the
  whole surface) and the no-op IO path is byte-for-byte unchanged.
- [ ] M4: Add the exactly-once acceptance test and the rollback (abort) test;
  both green.
- [ ] M5: Document the deferred Shibuya-adapter integration and update
  `kiroku-store/CHANGELOG.md`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Make exactly-once an *opt-in* second handler shape carried by a new
  optional `handlerTx` field on `SubscriptionConfig`, rather than changing the
  existing `handler` field's type or adding a separate `subscribeInTransaction`
  entry point.
  Rationale: The existing `handler :: RecordedEvent -> IO SubscriptionResult`
  surface and every current caller (tests, the `subscriptionAckStream` bridge,
  the Shibuya adapter) must keep compiling and behaving identically. An optional
  field is purely additive: when it is `Nothing` the worker takes the exact
  current code path; when it is `Just h` the worker takes the new transactional
  path. Reusing the same `subscribe` entry point keeps the worker startup, FSM,
  registry, and observability wiring identical for both modes.
  Date: 2026-06-03.

- Decision: In transactional mode the checkpoint advances **per event**, inside
  the same transaction as that event's handler writes — not at the batch tail as
  the IO path does.
  Rationale: The whole point is that one event's projection write and its
  checkpoint commit atomically. Batching the checkpoint to the end of the vector
  would reintroduce a window where several events' writes are committed but the
  checkpoint still points before them. Per-event commit is the price of
  exactly-once; throughput tuning (grouping multiple events into one transaction)
  is a later optimization explicitly out of scope here.
  Date: 2026-06-03.

- Decision: On a `Retry` or `DeadLetter` disposition the worker rolls back the
  user's writes by calling `Hasql.Transaction.condemn` inside the transaction
  body, then applies the existing disposition logic (redeliver, or record the
  dead letter via the existing atomic `insertDeadLetterAndCheckpointStmt`).
  Rationale: `condemn` is documented (in `kiroku-store/src/Kiroku/Store/Transaction.hs`
  lines 92-96) to mark the transaction for rollback while still returning the
  value the body produced — exactly what is needed to read the handler's
  `SubscriptionResult` and discard its SQL side effects in one pass. The
  dead-letter path already advances the checkpoint atomically with the
  dead-letter insert in its own statement, so reusing it keeps dead-lettering
  exactly-once too.
  Date: 2026-06-03.

- Decision: Use the *no-retry* transaction mode
  (`Hasql.Transaction.Sessions.transactionNoRetry ReadCommitted Write`) for the
  transactional delivery path.
  Rationale: `Kiroku.Store.Transaction` already documents (lines 80-85) that the
  auto-retrying `transaction` re-runs the body on a serialization conflict, which
  is unacceptable when "the caller has been promised exactly-once semantics that
  an outside observer of intermediate state could break." A subscription handler
  may perform observable work, so re-running its body silently is wrong; on a
  conflict we surface the error and let the worker's existing restart/replay path
  re-deliver from the unadvanced checkpoint.
  Date: 2026-06-03.

- Decision: Scope this plan to kiroku-store only; defer Shibuya-adapter
  integration to a follow-up.
  Rationale: The Shibuya handler shape is `Ingested es msg -> Eff es AckDecision`
  (`shibuya-core/src/Shibuya/Handler.hs`), which returns a control decision in
  `Eff` with no access to a `Hasql.Transaction`. Threading a transaction through
  it requires a new shibuya-core handler variant — a separate upstream change.
  The first and most important consumer, keiro's async-projection worker,
  subscribes to kiroku-store directly (not through Shibuya), so the kiroku-store
  surface alone unblocks it.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before
editing anything.

`kiroku-store` is a PostgreSQL event-store library. Its root is
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store`. Throughout
this plan, file paths under `kiroku-store/` are relative to that directory unless
stated otherwise. The repository root (where you run `cabal`) is
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

The pieces you will touch:

- **The subscription worker.** `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`.
  This is the long-running loop. It fetches a batch of events from the database,
  delivers each event to the handler, and advances the checkpoint. The functions
  that matter:
  - `processEvents` (lines 596-666): given a fetched `Vector RecordedEvent`, it
    walks the batch, calls the handler per event, and on success advances the
    checkpoint. In the current code the checkpoint advance happens once at the
    batch tail (`go driving i` when `i >= V.length events`, lines 622-628) via a
    call to `saveCheckpoint`.
  - `deliver` (lines 643-666): delivers a single event, interprets the
    `SubscriptionResult` the handler returns (`Continue` / `Stop` / `Retry` /
    `DeadLetter`), and implements bounded retry and dead-lettering. It calls the
    handler with `handler config event` (line 645).
  - `saveCheckpoint` (lines 709-721): runs the checkpoint UPSERT in its **own**
    pool session: `Pool.use pool (Session.statement (name', mem, pos) SQL.saveCheckpointMemberStmt)`.
    This is the separate connection that creates the at-least-once window.
  - `writeDeadLetter` (lines 673-702): records a dead letter and advances the
    checkpoint past the event in **one** statement
    (`SQL.insertDeadLetterAndCheckpointStmt`, used at line 697). This is the
    existing precedent for "do work and advance the checkpoint atomically", but
    it does it with a single hand-written SQL statement rather than a multi-write
    transaction.

- **The handler type and config.**
  `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`.
  - `type EventHandlerM m = RecordedEvent -> m SubscriptionResult` and
    `type EventHandler = EventHandlerM IO` (lines 232-236).
  - `data SubscriptionResult = Continue | Stop | Retry !RetryDelay | DeadLetter !DeadLetterReason`
    (lines 148-165).
  - `SubscriptionConfig` (a record around line 250-280) carries `name`,
    `target`, `handler`, `consumerGroup`, `eventTypeFilter`, `selector`,
    `batchSize`, and `retryPolicy :: !RetryPolicy` (line ~274). There is a smart
    constructor `defaultSubscriptionConfig :: SubscriptionName -> SubscriptionTarget -> EventHandler -> SubscriptionConfig`
    used by tests, e.g.
    `kiroku-store/test/Test/ConsumerGroup.hs:84`:
    `defaultSubscriptionConfig (SubscriptionName nm) (Category (CategoryName cat)) h`.
    Callers customize other fields by record update, e.g. `{ consumerGroup = Just ... }`.

- **The transaction primitives you will compose with.**
  `kiroku-store/src/Kiroku/Store/Transaction.hs` already wraps the
  `hasql-transaction` library. The relevant facts (verified in that file):
  - It imports `import Hasql.Transaction qualified as Tx` (line 69). `Tx.Transaction`
    is a monad with no `MonadIO` instance; you build a transaction body out of
    `Tx.statement :: params -> Hasql.Statement.Statement params result -> Tx.Transaction result`
    calls and `Tx.condemn :: Tx.Transaction ()`.
  - `Tx.condemn` marks the whole transaction for rollback at commit time but the
    body still runs to completion and returns its value (documented lines 92-96).
    That is how you can read a `SubscriptionResult` out of a transaction whose SQL
    you intend to discard.
  - The standard isolation used everywhere in this codebase is
    `Hasql.Transaction.Sessions.ReadCommitted` in `Write` mode (documented lines
    87-90). You run a transaction body against a pool with
    `Hasql.Pool.use pool (Hasql.Transaction.Sessions.transactionNoRetry Hasql.Transaction.Sessions.ReadCommitted Hasql.Transaction.Sessions.Write body)`.
    The non-retrying variant is `transactionNoRetry`; the retrying one is
    `transaction`. We use `transactionNoRetry` (see Decision Log).

- **The checkpoint statement to reuse.**
  `SQL.saveCheckpointMemberStmt :: Hasql.Statement.Statement (Text, Int, Int64) ()`
  (defined in `kiroku-store/src/Kiroku/Store/SQL.hs` around line 1111, the
  `saveCheckpointMemberSQL` UPSERT). The same statement `saveCheckpoint` runs in a
  plain session can be run inside a `Tx.Transaction` with
  `Tx.statement (name', mem, pos) SQL.saveCheckpointMemberStmt`. Verify the exact
  parameter tuple order against the existing `saveCheckpoint` call at Worker.hs:718.

Terms used in this plan, in plain language:

- **Exactly-once** here means: a successfully delivered event's read-model write
  and its checkpoint advance are committed in the same transaction, so on any
  crash the read model and the checkpoint agree. It does *not* mean kiroku
  prevents an event from being *delivered* to the handler more than once — a
  crash before commit still re-delivers — it means a *committed* effect lands
  once. With a per-event checkpoint commit, the handler body is replayed only for
  the single in-flight event whose transaction did not commit, and that replay
  re-runs inside a fresh transaction, so the net committed effect is once.
- **At-least-once** is the current behavior: delivery is one-or-more times and
  the handler must be idempotent.
- **Disposition** is the worker's reaction to the handler's `SubscriptionResult`:
  advance (Continue), stop, redeliver after a delay (Retry), or record-and-skip
  (DeadLetter).


## Plan of Work

The work is five milestones. M1-M2 are the core; M3 is a verification that the
public entry point is unchanged; M4 proves the behavior; M5 documents the
boundary and the deferred adapter work. Each milestone leaves the tree compiling
and the existing test suite green.

### Milestone 1 — Add the transactional handler type and the opt-in config field

Scope: introduce the new handler shape and make `SubscriptionConfig` able to
carry it, with no worker behavior change yet. At the end of this milestone the
code compiles, every existing test passes unchanged, and a caller can *construct*
a config with a transactional handler even though the worker ignores it so far.

In `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`, next to the existing
`EventHandlerM` / `EventHandler` aliases (lines 232-236), add a transactional
handler alias:

```haskell
-- | A transactional event handler. Its 'Hasql.Transaction.Transaction' body
-- performs the read-model writes for one event and returns the disposition
-- ('Continue' / 'Stop' / 'Retry' / 'DeadLetter'). The subscription worker runs
-- this body and the checkpoint advance in a single transaction, so the writes
-- and the checkpoint commit together (exactly-once). 'Tx.Transaction' has no
-- 'MonadIO', so the body must be pure SQL plus pure decision logic.
type EventHandlerTx = RecordedEvent -> Tx.Transaction SubscriptionResult
```

Add `import qualified Hasql.Transaction as Tx` to the module's imports. Export
`EventHandlerTx` from the module's export list (find where `EventHandler` /
`EventHandlerM` are exported and add the new alias alongside).

In the `SubscriptionConfig` record, add an optional field next to `handler`:

```haskell
  , handlerTx :: !(Maybe EventHandlerTx)
  -- ^ Optional transactional handler. When 'Just', the worker delivers events
  -- through it and commits each event's writes with the checkpoint advance in
  -- one transaction (exactly-once). When 'Nothing' (the default), the worker
  -- uses 'handler' with the existing at-least-once semantics.
```

In `defaultSubscriptionConfig`, set `handlerTx = Nothing` so every existing
caller is unaffected. (Note: if `SubscriptionConfig` is the polymorphic
`SubscriptionConfigM m` parameterized over the handler's monad, add `handlerTx`
as a plain `Maybe EventHandlerTx` field — `Tx.Transaction` is concrete and does
not depend on `m`. Mirror exactly how the existing `handler` field is declared
and how `defaultSubscriptionConfig` initializes the record.)

Acceptance for M1: `cabal build kiroku-store` succeeds and
`cabal test kiroku-store` is fully green (no behavior changed). A throwaway `ghci`
expression constructing
`(defaultSubscriptionConfig n t ioHandler) { handlerTx = Just (\_ -> pure Continue) }`
type-checks.

### Milestone 2 — Worker transactional delivery path

Scope: make the worker actually use `handlerTx` when present. At the end, a
subscription whose config has `handlerTx = Just h` commits each event's writes
and checkpoint atomically; a subscription with `handlerTx = Nothing` runs the
existing code path byte-for-byte.

First add a `Tx.Transaction`-flavored checkpoint helper near `saveCheckpoint` in
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`:

```haskell
-- The checkpoint UPSERT as a transaction step, so it can commit in the same
-- transaction as a transactional handler's writes. Same statement and key
-- ('subscription_name', member) as 'saveCheckpoint'.
saveCheckpointTx :: SubscriptionConfig -> GlobalPosition -> Tx.Transaction ()
saveCheckpointTx config (GlobalPosition pos) =
    let SubscriptionName name' = name config
        mem = configMember config
     in Tx.statement (name', mem, pos) SQL.saveCheckpointMemberStmt
```

Add the imports the worker needs at the top of `Worker.hs`:
`import qualified Hasql.Transaction as Tx` and
`import qualified Hasql.Transaction.Sessions as Tx` (or import `transactionNoRetry`,
`ReadCommitted`, `Write` explicitly). The worker already imports `Hasql.Pool` as
`Pool` and `Hasql.Session` as `Session`; the transaction-sessions import is the
only new one.

Now thread the choice into delivery. In `processEvents` / `deliver`, branch on
`handlerTx config`:

- When `handlerTx config == Nothing`: call the existing code unchanged. Do not
  refactor the IO path; keep `saveCheckpoint` at the batch tail and the existing
  `deliver` retry/dead-letter logic exactly as they are.

- When `handlerTx config == Just h`: deliver each event through a transactional
  `deliverTx`. For event `event` at position `evtPos`, run one transaction:

```haskell
result <-
    Pool.use pool $
        Tx.transactionNoRetry Tx.ReadCommitted Tx.Write $ do
            r <- h event
            case r of
                Continue -> saveCheckpointTx config evtPos
                Stop     -> saveCheckpointTx config evtPos
                Retry _      -> Tx.condemn  -- roll back the handler's writes
                DeadLetter _ -> Tx.condemn  -- roll back; dead-letter recorded below
            pure r
```

`Pool.use` returns `Either Pool.UsageError SubscriptionResult`. On `Left err`,
mirror `saveCheckpoint`'s error handling: emit
`KirokuEventSubscriptionDbError subName SaveCheckpoint err (groupCtxOf config)`
and rethrow (`throwIO err`) so the worker replays from the unadvanced checkpoint
on restart — the event is neither lost nor double-committed. On `Right r`,
interpret `r` exactly as the IO `deliver` does, but note the checkpoint was
already advanced *inside the committed transaction* for `Continue` / `Stop`:

  - `Continue` → the transaction already advanced the checkpoint to `evtPos` and
    committed the writes; proceed to the next event. (Do **not** also call the
    batch-tail `saveCheckpoint` in this mode; the per-event commit already did it.)
  - `Stop` → the transaction committed writes and checkpoint up to `evtPos`;
    return `Nothing` (terminate the batch) as the IO path does.
  - `Retry delay` → the transaction rolled back (condemn), so the handler's
    writes did not persist; apply the existing bounded-retry logic: if
    `attempt >= maxAttempts` call the existing `writeDeadLetter` (which atomically
    records the dead letter and advances the checkpoint in its own statement),
    otherwise set the observable `Retrying` state, `threadDelay`, and re-run
    `deliverTx` for the same event with `attempt + 1`. This reuses the IO path's
    `Retrying`/`KirokuEventSubscriptionRetrying` bookkeeping verbatim — factor the
    retry/dead-letter tail of `deliver` so both `deliver` and `deliverTx` call it,
    or duplicate the small block; either is acceptable as long as the IO path's
    bytes do not change in the `Nothing` case.
  - `DeadLetter reason` → the transaction rolled back the handler's writes; call
    the existing `writeDeadLetter pool config evtPos event reason attempt emit`,
    which records the dead letter and advances the checkpoint atomically. Proceed
    to the next event.

Implementation note on structure: the cleanest shape is to keep `processEvents`
walking the batch (`go`), and at the point it currently calls `deliver` (line
634) choose `deliver` vs `deliverTx` based on `handlerTx config`. The batch-tail
checkpoint at lines 622-628 must run **only** in the IO path; in the
transactional path each event already checkpointed, so the `i >= V.length events`
arm should simply `pure (Just newPos)` without calling `saveCheckpoint` again
(advancing the checkpoint to the same position twice is harmless because the
UPSERT uses `GREATEST(...)`, but skipping the redundant session is cleaner and
keeps the "no separate checkpoint session in tx mode" invariant true).

Acceptance for M2: `cabal build kiroku-store` succeeds. The existing test suite
(`cabal test kiroku-store`) stays green — in particular
`Test/SubscriptionRetryDeadLetter.hs`, which exercises the IO path, must be
unchanged and passing, proving the `Nothing` branch did not regress.

### Milestone 3 — Confirm the public entry point is unchanged

Scope: verify that no signature outside the worker changed. The whole feature
rides on the new optional config field, so `subscribe`
(`kiroku-store/src/Kiroku/Store/Subscription.hs`) and `runWorker`
(`Worker.hs:132`) keep their signatures; they already take the whole
`SubscriptionConfig` and pass it to `processEvents`. Read `subscribe` and confirm
it forwards `config` untouched. Confirm `subscriptionAckStream`
(`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`) — the pull-based bridge
used by the Shibuya adapter — is **not** changed by this plan; it installs its own
IO `bridgeHandler` and leaves `handlerTx = Nothing`, so it is unaffected.

Acceptance for M3: a one-paragraph note added to this plan's Surprises &
Discoveries confirming which public signatures were inspected and that none
changed; `git diff --stat` shows edits confined to `Types.hs`, `Worker.hs`, and
test/doc files.

### Milestone 4 — Prove exactly-once with a failure-injection test

Scope: a new test module that demonstrates the two behaviors that distinguish
exactly-once from at-least-once. At the end, the test is green and a reader can
see atomicity from the assertions.

Create `kiroku-store/test/Test/SubscriptionTransactional.hs`, modeled on
`kiroku-store/test/Test/SubscriptionRetryDeadLetter.hs` (its structure for
spinning up a store, appending events, subscribing, and asserting checkpoint /
dead-letter state) and using the fixtures in `kiroku-store/test/Test/Helpers.hs`
(`withTestStore`, the append helpers, `readCheckpoint`, and the
live/catch-up wait utilities). Register the new module in the test suite the same
way the others are (add it to the `other-modules` of the test stanza in
`kiroku-store/kiroku-store.cabal` and to the test driver that lists specs).

The test creates an application-owned read-model table for the projection to
write into. Because kiroku-store's test database is migrated from
`kiroku-store-migrations/sql-migrations/`, create the read-model table at the
start of the test with a plain `CREATE TABLE IF NOT EXISTS` executed through the
pool (do **not** add a framework migration for a test table). For example a table
`tx_projection (event_id UUID PRIMARY KEY, global_position BIGINT NOT NULL)`.

Test 1 — happy path commits atomically:

- Append N events (say 5) to one stream.
- Subscribe with a config whose `handlerTx = Just h`, where `h event` runs
  `Tx.statement` to `INSERT INTO tx_projection (event_id, global_position) VALUES (..)`
  for the event and returns `Continue`.
- Wait for the subscription to reach the last position (reuse the wait helper the
  other subscription tests use; if none fits, poll `readCheckpoint` until it
  equals the last event's global position or a timeout fires).
- Assert: `SELECT count(*) FROM tx_projection` equals N; `readCheckpoint` equals
  the last event's global position. This shows the projection rows and the
  checkpoint advanced together.

Test 2 — abort rolls back the projection write together with the checkpoint:

- Append 1 event.
- Subscribe with a `handlerTx = Just h` where `h event` *first* runs an
  `INSERT INTO tx_projection ...` for the event and *then* returns
  `DeadLetter (DeadLetterPoison "injected")`.
- Wait until the event is dead-lettered (assert via the same `readDeadLetters`
  helper `Test/SubscriptionRetryDeadLetter.hs` uses, or by polling the
  `dead_letters` table) and the checkpoint has advanced past the event (the
  dead-letter path advances it atomically).
- Assert: `SELECT count(*) FROM tx_projection` is **0** — the handler's attempted
  INSERT was rolled back by `condemn`, proving the handler's writes and the
  disposition share a transaction. This is the assertion that fails on an
  at-least-once design and passes here.

Optional Test 3 — retry does not partially apply:

- Append 1 event; `handlerTx` inserts a row then returns `Retry` for the first
  two attempts and `Continue` on the third. Assert the final `tx_projection` has
  exactly one row (the earlier attempts' inserts were rolled back) and the
  checkpoint advanced once. This demonstrates that a redelivered event does not
  accumulate duplicate writes.

Acceptance for M4: `cabal test kiroku-store` runs the new module green, and the
two key assertions (count == N with checkpoint == last; count == 0 after a
dead-lettering abort) are present and passing.

### Milestone 5 — Document the boundary and update the changelog

Scope: make the new surface discoverable and record the deliberate scope.

Add a `### Unreleased` entry to `kiroku-store/CHANGELOG.md` under "New Features"
describing the transactional handler: the new `EventHandlerTx` type, the optional
`SubscriptionConfig.handlerTx` field, and the exactly-once guarantee (per-event
writes plus checkpoint commit in one `ReadCommitted`/`Write` transaction; `Retry`
and `DeadLetter` roll back the handler's writes via `condemn`). State explicitly
that the existing `handler` path is unchanged and remains the default
at-least-once mode.

In this plan's Surprises & Discoveries, record the Shibuya-adapter boundary: the
Shibuya handler returns `Eff es AckDecision` with no transaction, so exactly-once
through the adapter needs a follow-up shibuya-core handler variant; kiroku-store
direct consumers (keiro) get exactly-once today through `handlerTx`.

Acceptance for M5: the CHANGELOG renders, names the new identifiers exactly, and
the boundary note is present.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless stated otherwise.

Build just the store package after each edit:

```bash
cabal build kiroku-store
```

Run the store test suite:

```bash
cabal test kiroku-store
```

Expected on success (exact phrasing depends on the test driver; the point is zero
failures):

```text
All N tests passed (… s)
```

Run only the new transactional spec while iterating (if the suite uses
`hspec`/`tasty` match filtering, pass the test-suite's filter flag; otherwise run
the whole suite). For an hspec-based suite the pattern is:

```bash
cabal test kiroku-store --test-options='--match "transactional"'
```

After adding a new `.sql`-free read-model table inside the test, no migration
rebuild is needed. If you ever add or change a file under
`kiroku-store-migrations/sql-migrations/`, be aware Template-Haskell-embedded
migrations may not recompile on a *new* file; force it with `cabal clean` or a
content change to the embedding module before trusting "Up to date". This plan
adds **no** framework migration, so this caveat should not bite — it is recorded
only so a reader who deviates is not surprised.


## Validation and Acceptance

The feature is validated behaviorally, not by compilation alone.

1. Build and full suite green:

```bash
cabal build kiroku-store && cabal test kiroku-store
```

2. The two distinguishing assertions in `Test/SubscriptionTransactional.hs`:
   - After driving a `Continue`-returning transactional handler over N appended
     events, `SELECT count(*) FROM tx_projection` equals N **and** the
     `subscriptions.last_seen` checkpoint equals the last event's global
     position. This proves writes and checkpoint advanced together.
   - After driving a handler that INSERTs then returns `DeadLetter`,
     `SELECT count(*) FROM tx_projection` equals **0** while the checkpoint has
     advanced past the event (the dead-letter row exists). This proves the
     handler's SQL and the disposition are one transaction that rolled back
     together — the property an at-least-once design cannot satisfy.

3. Regression: `Test/SubscriptionRetryDeadLetter.hs` (the IO at-least-once path)
   remains unmodified and green, proving the default path did not change.

Interpretation: if Test 2's count is non-zero, the handler's write committed
independently of the disposition — the transaction boundary is wrong and the
feature does not provide exactly-once. If Test 1's count is less than N or the
checkpoint lags, the per-event commit is not happening.


## Idempotence and Recovery

Every edit is additive and safe to re-run:

- M1 adds a type alias and an optional record field defaulting to `Nothing`;
  re-running the edit (or rebuilding) changes nothing for existing callers.
- M2's new code path is reached only when `handlerTx` is `Just`; the `Nothing`
  path is the untouched original, so a partially applied M2 cannot corrupt
  existing subscriptions.
- The checkpoint UPSERT uses `GREATEST(subscriptions.last_seen, EXCLUDED.last_seen)`,
  so even if a checkpoint advance runs twice for the same position (it should not
  in tx mode) it is idempotent and never moves the checkpoint backward.
- The test creates its read-model table with `CREATE TABLE IF NOT EXISTS` and can
  be re-run against a fresh ephemeral database from `withTestStore` without
  manual cleanup.

If M2 is left half-done (compiles but the test fails), recovery is to re-read the
`deliver` retry/dead-letter tail and confirm `deliverTx` reuses it; no data
migration or rollback is involved because nothing in the durable schema changed.


## Interfaces and Dependencies

Libraries (all already dependencies of `kiroku-store`; no cabal dependency
additions):

- `hasql-transaction` — provides `Hasql.Transaction.Transaction`,
  `Hasql.Transaction.statement`, `Hasql.Transaction.condemn`, and
  `Hasql.Transaction.Sessions.{transactionNoRetry, ReadCommitted, Write}`. Already
  used by `kiroku-store/src/Kiroku/Store/Transaction.hs`.
- `hasql` / `hasql-pool` — `Hasql.Pool.use`, `Hasql.Session.statement`. Already
  used by the worker.

Signatures that must exist at the end of each milestone (full module paths):

- End of M1, in `Kiroku.Store.Subscription.Types`:
  - `type EventHandlerTx = RecordedEvent -> Hasql.Transaction.Transaction SubscriptionResult`
  - `SubscriptionConfig` gains `handlerTx :: !(Maybe EventHandlerTx)`, initialized
    to `Nothing` by `defaultSubscriptionConfig`. Both `EventHandlerTx` and the
    field are exported.

- End of M2, in `Kiroku.Store.Subscription.Worker` (internal, not necessarily
  exported):
  - `saveCheckpointTx :: SubscriptionConfig -> GlobalPosition -> Hasql.Transaction.Transaction ()`
  - a transactional delivery path (`deliverTx` or an inline branch) reached when
    `handlerTx config` is `Just`, running
    `Hasql.Pool.use pool (Hasql.Transaction.Sessions.transactionNoRetry ReadCommitted Write body)`
    where `body` runs the handler, conditionally appends `saveCheckpointTx`, and
    calls `Hasql.Transaction.condemn` on `Retry`/`DeadLetter`.

- End of M4:
  - `kiroku-store/test/Test/SubscriptionTransactional.hs` exists, is registered in
    `kiroku-store/kiroku-store.cabal`'s test stanza, and passes.

No public signature changes outside the new `Types` exports; `subscribe`,
`runWorker`, `subscriptionAckStream`, and the Shibuya adapter are untouched.
