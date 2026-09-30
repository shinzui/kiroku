---
id: 93
slug: hold-the-consumer-group-member-guard-for-the-worker-s-lifetime
title: "Hold the consumer-group member guard for the worker's lifetime"
kind: exec-plan
created_at: 2026-09-30T21:45:00Z
intention: "intention_01m3t4842ae5vs772q428rbywa"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T21:45:00Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-30T22:19:31Z
      mode: "update"
      note: "Reconciled with plan 92: IR-15 acceptance recorded, dependent adapter plan and release coordination noted, stale patch versions corrected"
---

# Hold the consumer-group member guard for the worker's lifetime

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku is a PostgreSQL event store written in Haskell (package `kiroku-store`). A
*subscription* is a long-lived worker that reads events after a saved position (its
*checkpoint*) and hands them to an application handler. A *consumer group* splits one
subscription into `size` *members*, numbered `0 .. size-1`; each member owns a disjoint slice of
the streams and saves its own checkpoint under the key `(subscription name, member)`. The
operational rule that keeps a group correct is that exactly one live process runs each member
index. When two processes run the same member, both deliver the same events and both write the
same checkpoint row, so every event in that slice is handled twice.

The configuration field `consumerGroupGuard` on `SubscriptionConfigM` promises to refuse a
duplicate member. Today it does not. The worker runs one statement,
`SELECT pg_try_advisory_xact_lock(...)`, on a pooled connection. That lock is *transaction
scoped*: PostgreSQL releases it the instant the statement's implicit transaction ends, and the
connection goes back to the pool. So the guard sees a peer only if the peer is probing in the
same instant. A second process started a moment later takes the lock successfully and runs the
same member. The code comment, the field's Haddock, and the user guide all say so, but a field
named "guard" is trusted more than it deserves. Improvement request IR-15,
[`docs/improvement-requests/hold-the-consumer-group-member-guard-for-the-workers-lifetime.md`](../improvement-requests/hold-the-consumer-group-member-guard-for-the-workers-lifetime.md)
(`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-15`), filed by Notification Hub
after it had to hold the lock itself, asks Kiroku to hold the lock for the worker's whole
lifetime. Improvement request IR-17
(`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-17`) is blocked on this: a
verification suite started two Shibuya-adapter processes on one member and observed every one
of 40 events handled twice.

This plan evaluates the request and honors it. After this plan, with `consumerGroupGuard = True`,
a subscription worker opens one dedicated PostgreSQL connection, takes a *session-level*
advisory lock keyed on `(name, member)` on that connection, and keeps the connection open until
the worker stops. A second process configured as the same member fails start-up with
`ConsumerGroupGuardConflict` for as long as the first is running, and starts once the first has
stopped or crashed, because a session's locks die with the session. If the dedicated connection
is lost while the worker runs (a database restart, a failover, an idle-session timeout), a
heartbeat notices within thirty seconds, re-takes the lock on a fresh connection, and stops the
worker with `ConsumerGroupGuardLost` if a peer took the member in the meantime.

The user's constraint on this work is that it must not degrade performance. It cannot, and the
plan proves it. With the guard off (the default) the code path is one pattern match at start-up,
identical to today. With the guard on, every cost is paid once at start-up or on an idle
dedicated connection off every data path: one extra connection per guarded member, one connect
handshake at start-up (which replaces today's pool checkout and statement), and one trivial
statement every thirty seconds. Appends, reads, the publisher, catch-up fetches, live fetches,
and checkpoint writes are untouched. The authoritative gates of
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) are run before and after, and
two new benchmark cells quantify the opt-in start-up cost so the number is on record.


## Progress

- [x] (2026-09-30) Gate: record acceptance of IR-15 in the request file and the bundle log (M1, first step). Done while reconciling this plan with plan 92: IR-15 reads `status: accepted` and its Status section names this plan; the 2026-09-30 log entry covers IR-15 and IR-17.
- [ ] M1: add `acquireDedicatedConnection` to `KirokuStore`, the `Kiroku.Store.Subscription.MemberGuard` module, the `MemberGuard` phase and `KirokuEventSubscriptionGuardReacquired` event, and the `ConsumerGroupGuardLost` exception; thread the connector through `runWorker`; replace the probe with the lifetime-held lock; fail closed on guard errors.
- [ ] M1: add exhaustive-match arms in `kiroku-metrics` and `kiroku-otel`; build all packages green.
- [ ] M1: `Test.ConsumerGroupGuard` covers conflict-while-running across two stores and within one store, replacement after stop and after a terminated holder, lock visibility in `pg_locks`, the documented self-conflict, and fail-closed on a guard error.
- [ ] M1: `Test.PerformanceStructure` pins zero guard backends with the guard off, exactly one with it on, and equal pool checkouts to `Live` for guard on and off.
- [ ] M2: heartbeat and reacquisition on the dedicated connection with the `withMemberGuardTickForTest` seam; tests for reacquire after a terminated guard backend and for `ConsumerGroupGuardLost` when a peer took the member.
- [ ] M3: two `consumer-group-guard` benchmark cells; baseline refreshed with the reason recorded; `just perf-check` and `just perf-telemetry` green; numbers recorded in Surprises & Discoveries.
- [ ] M4: Haddock, user guide, architecture doc, capability catalog, production tuning guide, and changelog updated; ADR-11 created and ADR-2 amended; bundle logs written; validation commands green.
- [ ] M4: version bumps and dependency bounds prepared; IR-15 moved to `completed` after publication, which is confirmation-gated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Honor IR-15. Implement the lifetime-held guard in `kiroku-store` rather than
  documenting the probe away or leaving the workaround to applications.
  Rationale: The probe's own comment and plan 29's Decision Log (2026-05-20,
  [`docs/plans/29-consumer-group-subscription-runtime-and-per-member-workers.md`](29-consumer-group-subscription-runtime-and-per-member-workers.md))
  already record the lifetime-held session lock as the intended follow-up; two downstream
  projects have now paid for its absence (Notification Hub holds the lock itself; the Keiro
  verification suite reproduced double processing behind IR-17). The change has no hot-path
  cost, so the user's performance constraint is satisfied by construction and verified by gate.
  Date: 2026-09-30

- Decision: Keep the lock key exactly as today, `hashtextextended('<name>:<member>', 0)`, and
  document it as stable and database-global (not schema-scoped).
  Rationale: Notification Hub already takes this key on its own connection so that a
  Kiroku-guarded process elsewhere is still refused; changing the key would silently let the two
  guards coexist. The key ignores the store's `schema` today; keeping that is a documented
  limitation (two stores in different schemas of one database with the same `(name, member)`
  conflict), not something to fix here.
  Date: 2026-09-30

- Decision: A database error while taking the guard fails start-up loudly (fail closed),
  replacing today's degrade-open behavior.
  Rationale: The extra connection introduces a guard-specific failure that the pool does not
  share: `max_connections` exhaustion. Degrading open would run the worker unguarded exactly when
  the operator most needs to know, which is the overpromise IR-15 exists to remove. Start-up
  already fails loudly when the checkpoint cannot be loaded, so the shape is consistent. The
  error is emitted as `KirokuEventSubscriptionDbError name MemberGuard err ctx` before the throw.
  Date: 2026-09-30

- Decision: Detect loss of the dedicated connection with a heartbeat on that connection every
  thirty seconds, reacquire the lock on a fresh connection with a capped backoff, and stop the
  worker with `ConsumerGroupGuardLost` only when a peer holds the lock. Never stop the worker
  merely because the database is unreachable.
  Rationale: Without detection the guard silently evaporates after any failover, which is the
  same trust problem as today with a longer fuse. The heartbeat also keeps the idle session alive
  through `idle_session_timeout` and NAT idle timers. Stopping on unreachability would kill
  workers that otherwise ride out an outage through their existing `Reconnecting` state. The
  cost is one trivial statement per thirty seconds per guarded member on a connection that
  nothing else uses; it is not on any data path.
  Date: 2026-09-30

- Decision: The heartbeat interval is a fixed constant with a process-local test seam, not a
  configuration field.
  Rationale: One more `SubscriptionConfigM` field is a breaking change for every record-literal
  call site and a surface the 1.0 review would have to defend; the existing
  `withFetchBatchHookForTest` pattern already gives tests deterministic control without public
  surface.
  Date: 2026-09-30

- Decision: Expose the connection source as a new `KirokuStore` field,
  `acquireDedicatedConnection :: IO (Either ConnectionError Connection)`, and pass it to
  `runWorker` as a new parameter.
  Rationale: The store handle does not keep the connection string; the notifier receives it in a
  closure at start. A closure field mirrors that, avoids a second path to the password-bearing
  string, and lets a test substitute a failing connector through an ordinary record update.
  Both changes are breaking under the PVP, but the guard's semantic change already requires a
  major bump, so the cost is paid once.
  Date: 2026-09-30

- Decision: Do not wait for MasterPlan 12 (plans 81 to 85), and keep the new
  `ConsumerGroupGuardLost` outside the future `SomeSubscriptionStartupFailure` family.
  Rationale: Plan 82, which introduces that family, has not started; its milestone routes
  `ConsumerGroupGuardConflict` under the parent and can do so unchanged. `ConsumerGroupGuardLost`
  is a mid-life crash reason, not a start-up refusal, so it does not belong in that family.
  Date: 2026-09-30

- Decision: Add two historical benchmark cells for member start-up with the guard off and on,
  and refresh the baseline CSV once, recording this benchmark-set change as the reason.
  Rationale: The only place a guard-on cost exists is start-up; a same-machine pair of cells is
  the honest way to put a number on it, and `just perf-telemetry` then tracks it. The refresh is
  the documented consequence of adding a historical cell (`docs/PERF-REGRESSION-GATES.md`).
  Date: 2026-09-30

- Decision: Keep IR-17 (adapter exposure) out of scope; this plan only unblocks it.
  Rationale: The user asked for IR-15. IR-17 is a separate, dependent request on
  `shibuya-kiroku-adapter`'s configuration record with its own acceptance runs in another project.
  IR-17 is planned by [plan 92](92-expose-the-lifetime-member-guard-in-the-shibuya-adapter.md), which gates on this plan's
  milestones 1 and 2 and forwards `ConsumerGroupGuardConflict`, `ConsumerGroupGuardLost`, and the
  released store version; a change to any of those must be reflected in plan 92's Context section.
  Date: 2026-09-30

- Decision: Coordinate the release with plan 92. If plan 92 is implemented before this plan's
  release milestone runs, `shibuya-kiroku-adapter` ships in the same confirmation-gated cohort as a
  PVP major carrying the new field, and the bound-only adapter patch proposed in Milestone 4 is
  skipped; otherwise this plan releases the bound-only patch and plan 92 releases the adapter
  major afterwards.
  Rationale: The adapter must raise its `kiroku-store` bound either way; shipping it twice in one
  day is avoidable when both plans are done, and still correct when they are not.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### Where things are

Everything in this plan is in the `kiroku-store` package unless stated otherwise. Paths are
repository-relative.

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` is the subscription worker: the loop that
resolves the checkpoint, catches up from history, goes live, delivers batches, and saves
checkpoints. Its entry point is `runWorker`, called once per subscription from `subscribe` in
`kiroku-store/src/Kiroku/Store/Subscription.hs` (line 200). `runWorker` takes the store's
`hasql-pool` `Pool` and runs every database statement through `Pool.use`, which checks a
connection out, runs the statement, and returns it. The guard today is the function
`guardMember` near the bottom of `Worker.hs`:

```haskell
guardMember :: Pool -> SubscriptionName -> Int32 -> IO ()
guardMember pool subName@(SubscriptionName n) mem = do
    let probe :: Statement (Text, Int32) Bool
        probe =
            preparable
                "SELECT pg_try_advisory_xact_lock(hashtextextended($1 || ':' || $2::text, 0))"
                ( contrazip2
                    (E.param (E.nonNullable E.text))
                    (E.param (E.nonNullable E.int4))
                )
                (D.singleRow (D.column (D.nonNullable D.bool)))
    result <- Pool.use pool (Session.statement (n, mem) probe)
    case result of
        Right True -> pure () -- got the lock; no concurrent holder right now
        Right False -> throwIO (ConsumerGroupGuardConflict subName mem)
        Left _ -> pure () -- DB error: degrade open (do not block startup)
```

It is called at the top of `runWorker`'s `body`, before the checkpoint is loaded:

```haskell
    let body = do
            case (consumerGroupGuard config, consumerGroup config) of
                (True, Just (ConsumerGroup m _)) -> guardMember pool subName m
                _ -> pure ()
            resolution <- loadCheckpoint pool config emit
            ...
            loop (CatchingUp checkpoint 0)
```

`body` is run under `try`; any exception becomes a `KirokuEventSubscriptionStopped` event with
reason `StopWorkerCrashed e` and is rethrown so the caller's `wait` sees it. That is the
"existing lifecycle event" IR-15 refers to.

`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` holds `SubscriptionConfigM` with the
`consumerGroupGuard :: !Bool` field (line 348) and the exception
`ConsumerGroupGuardConflict { conflictName, conflictMember }` (line 499), both with Haddock that
describes the probe. `defaultSubscriptionConfig` sets the field to `False`.

`kiroku-store/src/Kiroku/Store/Connection.hs` defines the store handle `KirokuStore` (line 142)
and `withStore`, which acquires the pool, starts the notifier on a dedicated connection, and
starts the publisher. The handle carries `pool`, `schema`, `notifier`, `publisher`,
`eventHandler`, `storeSettings`, and `subscriptionRegistry`; it does not carry the connection
string. The string reaches the notifier as an argument of `Notifier.startNotifier`.

`kiroku-store/src/Kiroku/Store/Notification.hs` is the pattern this plan copies. `acquireOrThrow`
opens a raw `Hasql.Connection.Connection` outside the pool with
`Connection.acquire (Conn.connectionString connStr)`, runs
`SET application_name = 'kiroku-listener'` so operators can find it in `pg_stat_activity`, and
the listener loop keeps the current connection in a `TVar` so reconnection can replace it and
`stopNotifier` releases whichever one is live. Its reconnect schedule is
`reconnectDelayMicros n = min 30s (1s * 2^(n-1))`.

`kiroku-store/src/Kiroku/Store/Observability.hs` defines `KirokuEvent`, the structured events a
store emits through `ConnectionSettings.eventHandler`, and `SubscriptionDbPhase`
(`LoadCheckpoint | FetchBatch | SaveCheckpoint`), the phase carried by
`KirokuEventSubscriptionDbError`. Both are matched exhaustively, under
`-Werror=incomplete-patterns`, in `kiroku-metrics/src/Kiroku/Metrics/Collector.hs` (`applyEvent`
from line 163, `bumpDbPhase` at line 232) and in `kiroku-otel/src/Kiroku/Otel/Subscription.hs`
(`onEvent` from line 217). Adding a constructor to either type breaks those builds until an arm
is added.

Tests live in `kiroku-store/test/`; `Test.Helpers` provides `withTestStore`,
`withTestStoreSettings`, `waitWithTimeout`, `terminateBackend`, and friends, and
`Kiroku.Test.Postgres.withMigratedTestDatabase` (package `kiroku-test-support`) gives a fresh
migrated database per test on a shared ephemeral PostgreSQL. The existing guard test is
`consumerGroupGuard fails fast when another holder holds the (name, member) lock` in
`kiroku-store/test/Test/ConsumerGroup.hs` (line 276): it takes the *session* lock on a raw
connection and asserts that a guarded worker is refused. Structural performance invariants are
in `kiroku-store/test/Test/PerformanceStructure.hs`, whose `withObservedStore` counts pool
checkouts through `observationHandler`. Benchmarks are in `kiroku-store/bench/Main.hs`
(`tasty-bench`, historical CSV at `kiroku-store/bench/results/baseline.csv`) and the controlled
workload gate in `kiroku-store/bench/RegressionGate.hs`. The `justfile` at the root defines
`just test`, `just perf-check`, `just perf-telemetry`, `just bench-baseline-check`,
`just bench-baseline`, `just adr-validate`, and `just capabilities-validate`.

### PostgreSQL facts this plan relies on

An *advisory lock* is an application-defined lock PostgreSQL manages but never interprets. It is
keyed by one 64-bit integer. `pg_try_advisory_lock(key)` takes a *session-level* lock without
waiting and returns `true` if it got it, `false` if another session holds it. A session-level
lock is held until `pg_advisory_unlock(key)` or until the session (the connection) ends,
including by crash or `pg_terminate_backend`. `pg_try_advisory_xact_lock(key)` takes a
*transaction-level* lock, released when the transaction ends; a statement outside an explicit
transaction is its own transaction, which is why today's probe releases at once. The same
session may take a session-level lock it already holds; the lock count increments and each take
needs a matching release, but session end releases everything. Different sessions never share a
lock, which is why an application that holds the key on its own connection conflicts with a
Kiroku worker holding it on Kiroku's connection.

`hashtextextended(text, seed)` returns a 64-bit hash, stable across sessions and servers of the
same major version, so every process computes the same key from the same text. The key text is
`<subscription name>:<member>`. Held advisory locks appear in the `pg_locks` view with
`locktype = 'advisory'`, `objsubid = 1` for 64-bit keys, and the key split into `classid` (high
32 bits) and `objid` (low 32 bits). `pg_stat_activity` lists every backend with its
`application_name`, which a client sets with `SET application_name = '...'`.

Session-level locks require that one client connection map to one server session for its whole
life. A transaction-mode connection pooler such as PgBouncer in `pool_mode = transaction` breaks
that; it also breaks `LISTEN`, which Kiroku's notifier already needs, so this plan adds no new
deployment requirement but must document the shared one.

### hasql facts this plan relies on

`Hasql.Connection.acquire :: Settings -> IO (Either ConnectionError Connection)` opens one raw
connection; `Hasql.Connection.Settings.connectionString :: Text -> Settings` builds settings from
a libpq string. `Hasql.Connection.use :: Connection -> Session a -> IO (Either SessionError a)`
runs a session on that connection, holding an internal `MVar` for the duration, and returns
errors as values. `Hasql.Connection.release :: Connection -> IO ()` closes it. `Hasql.Pool.UsageError`
has constructors `ConnectionUsageError ConnectionError`, `SessionUsageError SessionError`, and
`AcquisitionTimeoutUsageError`; the first two let this plan carry raw-connection errors in the
existing `KirokuEventSubscriptionDbError`, which takes a `UsageError`. The bounds in
`kiroku-store/kiroku-store.cabal` are `hasql >=1.10 && <1.11` and `hasql-pool >=1.2 && <1.5`;
the corpus checkout used for this plan is hasql 1.10.3.5 and hasql-pool 1.4.2.

### Cross-repository context

Notification Hub is registered as `mori://tan/notification-hub` (the request file writes the
namespace as `shinzui`; the registry's qualified name is `tan/notification-hub`). Its ADR at
project-relative `docs/adr/application-owned-delivery-capacity.md` (artifact-level URI pending)
records that its worker registry takes `pg_try_advisory_lock(hashtextextended($1 || ':' || $2::text, 0))`
on a dedicated connection for the row's lifetime with `consumerGroupGuard = False`, "keyed as
Kiroku keys its probe, so a duplicate member is refused at start-up and a crashed holder never
blocks its replacement", and lists "the member lock duplicates a key Kiroku computes" as a cost.
After this plan, that application can either keep its lock and leave the Kiroku guard off, or
drop its lock and turn the Kiroku guard on; it must not do both, because the two sessions would
conflict (see acceptance 3 of IR-15). The Keiro consumer (`mori://shinzui/keiro`) does not set
`consumerGroupGuard` anywhere, so its behavior is unchanged.

### Dependent plan

Plan 92, [`docs/plans/92-expose-the-lifetime-member-guard-in-the-shibuya-adapter.md`](92-expose-the-lifetime-member-guard-in-the-shibuya-adapter.md)
(`mori://shinzui/kiroku/plans/92-expose-the-lifetime-member-guard-in-the-shibuya-adapter`), is the IR-17 plan: it adds
`consumerGroupGuard` to `shibuya-kiroku-adapter`'s `KirokuAdapterConfig` and
`KirokuConsumerGroupConfig`, forwards it to the store subscription, and re-exports
`ConsumerGroupGuardConflict` and `ConsumerGroupGuardLost`. It gates on this plan's milestones 1
and 2 and raises the adapter's `kiroku-store` bound to the version this plan releases. Renaming
either exception, changing where a refusal surfaces (the worker thread and the handle's `wait`),
or releasing a different store version must be reflected in plan 92's Context section.

### Relevant ADRs

[ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md) records consumer groups as
static, hash-partitioned competing consumers with "an optional PostgreSQL advisory lock per
`(group, member)`" guarding the one-live-process invariant, off by default. This plan makes that
sentence true and amends the ADR to say what is held and for how long.

[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) makes `just perf-check`
(structural checks plus the controlled workload gate) the authoritative performance evidence and
the historical CSV non-failing telemetry. This plan adds structural invariants for the guard and
two historical cells, and runs the gates before and after.

[ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md)
records conventions for MasterPlan 12 that are not yet in the code: construction-time
validation and one exception parent for start-up refusals. Neither has landed (the `Progress`
section of
[`docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md`](../masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md)
shows every plan unchecked), so this plan targets today's `ConsumerGroup` record and standalone
exceptions and stays compatible with plan 82's later routing of `ConsumerGroupGuardConflict`
under the parent.

[ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
freezes `kiroku-metrics` wire shapes to additive growth. This plan adds no metric series; the new
phase and event are absorbed by existing counters.

No ADR covers the guard's mechanism. Milestone 4 creates ADR-11 for it.


## Plan of Work

### Why this cannot degrade performance

Every path a benchmark or a production workload exercises is listed here with what changes.
Append (`Kiroku.Store.Append`): nothing. Reads (`Kiroku.Store.Read`): nothing. The publisher
(`Kiroku.Store.Subscription.EventPublisher`): nothing. The worker's checkpoint load, catch-up
fetch, live fetch, delivery, and checkpoint save: nothing; the guard code runs before
`loadCheckpoint` and then only in its own thread on its own connection. Guard off: one `case` on
two record fields at start-up, as today. Guard on: one raw connection opened at start-up (a TCP
or socket connect, authentication, two small statements), one PostgreSQL backend held idle for
the worker's lifetime, and one `SELECT true` every thirty seconds on that idle connection. Today's
guard costs one pool checkout and one statement; the new one uses the pool not at all, so a
guarded worker's pool footprint goes down by one checkout.

The evidence is collected in three tiers, matching ADR-5. Structural (Milestone 1): no guard
backend exists with the guard off; exactly one exists with it on; pool checkouts to `Live` are
equal with the guard on and off. Controlled workload (Milestone 3): `just perf-workload-gate` is
unchanged because none of its statements are touched. Historical (Milestone 3): the existing
`subscription category catch-up 100 events` cell is unchanged, and two new cells put a number on
the opt-in start-up cost.

### Milestone 1: hold the lock for the worker's lifetime

At the end of this milestone, a guarded member holds a session-level advisory lock on a
dedicated connection from before its checkpoint is read until the worker exits, a duplicate is
refused for that whole time, and a guard error fails start-up loudly. The heartbeat is not yet
wired (Milestone 2), but the types and events it needs exist so the public surface changes once.

**Accept the request.** Already done on 2026-09-30 while reconciling this plan with plan 92:
the file reads `status: accepted`, its Status section names this plan, and the 2026-09-30 log
entry covers IR-15 and IR-17. Verify with
`grep -n 'status: accepted' docs/improvement-requests/hold-the-consumer-group-member-guard-for-the-workers-lifetime.md`
and skip. If it were ever reverted: in
`docs/improvement-requests/hold-the-consumer-group-member-guard-for-the-workers-lifetime.md`
set `status: accepted`, bump `timestamp` to now, and add a paragraph to the `## Status` section
in the style of IR-11's file: "Accepted by kiroku on 2026-09-30. Implementation is planned by
[ExecPlan 93](../plans/93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime.md)
(`mori://shinzui/kiroku/plans/93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime`)
..." naming the lifetime-held lock, the fail-closed start-up, the heartbeat, and the
confirmation-gated release. Append an entry to `docs/improvement-requests/log.md` under a
`## 2026-09-30` heading (create it above the existing `## 2026-09-27`), in the bundle's style:
`* **Update**: IR-15 is accepted; [ExecPlan 93](...) (mori://...) plans ...`.

**Add the connector to the store handle.** In `kiroku-store/src/Kiroku/Store/Connection.hs`, add
to `KirokuStore` a field

```haskell
    , acquireDedicatedConnection :: !(IO (Either ConnectionError Connection))
    {- ^ Open one raw connection to the store's database outside the pool, with
    the store's connection string. Used by guarded consumer-group workers for
    the session-level member lock ('Kiroku.Store.Subscription.MemberGuard');
    the notifier holds its own. The caller owns the connection and must
    'Hasql.Connection.release' it.
    -}
```

importing `Hasql.Connection (Connection)` and `Hasql.Errors (ConnectionError)`. In `withStore`'s
`acquire`, set it to `Connection.acquire (Conn.connectionString cs)`. Nothing else in the record
changes.

**Create the guard module.** Add `kiroku-store/src/Kiroku/Store/Subscription/MemberGuard.hs` and
list it under `other-modules` in `kiroku-store/kiroku-store.cabal`. It exports
`withMemberGuard`, `memberGuardApplicationName`, `memberGuardHeartbeatMicros`, and
`withMemberGuardTickForTest`. Its core is:

```haskell
{- | Hold the session-level member lock on a dedicated connection around an
action. Acquires the connection, tags it @kiroku-member-guard@, takes
@pg_try_advisory_lock(hashtextextended(name || ':' || member, 0))@, runs the
action while a heartbeat watches the connection, and releases the connection
(and with it the lock) when the action exits by any route.

Throws 'ConsumerGroupGuardConflict' when another session holds the lock, a
'Hasql.Pool.UsageError' when the connection or the lock statement fails
(start-up fails closed), and 'ConsumerGroupGuardLost' when the heartbeat
re-took the lock after losing the connection and found a peer holding it.
-}
withMemberGuard ::
    IO (Either ConnectionError Connection) ->
    (KirokuEvent -> IO ()) ->
    SubscriptionName ->
    Int32 ->
    SubscriptionGroupContext ->
    IO a ->
    IO a
```

Implementation shape, which the implementer should follow closely because the ordering is the
point. Acquire with `bracketOnError` so an asynchronous exception between acquire and the
`TVar` write cannot leak the socket. On `Left err`, emit
`KirokuEventSubscriptionDbError name MemberGuard (ConnectionUsageError err) ctx` and throw
`ConnectionUsageError err`. Run `SET application_name = 'kiroku-member-guard'` with an
`unpreparable` statement, ignoring failure as the notifier does. Run the lock statement, written
with `pg_catalog.` qualification so a hostile `search_path` cannot shadow it:

```sql
SELECT pg_catalog.pg_try_advisory_lock(pg_catalog.hashtextextended($1 || ':' || $2::pg_catalog.text, 0))
```

as a `preparable` `Statement (Text, Int32) Bool` with the same `contrazip2` encoders and
`D.singleRow (D.column (D.nonNullable D.bool))` decoder as today's probe. On `Left e`, emit the
`MemberGuard` database error with `SessionUsageError e`, release, and throw `SessionUsageError e`.
On `Right False`, release and throw `ConsumerGroupGuardConflict name member`. On `Right True`,
store the connection in a `TVar (Maybe Connection)` cell and run

```haskell
    bracket_ (pure ()) (releaseCell cell) $ do
        outcome <- Async.race (heartbeat cell) action
        either throwIO pure outcome
```

where `releaseCell` atomically swaps the cell to `Nothing` and releases the connection it held, if
any. The cell is `Maybe` precisely so that a reconnect in progress (old connection already
released, new one not yet stored) can never lead to releasing a connection twice; nothing in this
plan relies on a double `release` being safe. `heartbeat` is defined in Milestone 2; in this
milestone it is `forever (threadDelay memberGuardHeartbeatMicros)` returning
`ConsumerGroupGuardLost` never, so `race` only ever returns `Right`. `Async.race` cancels the
other side when one finishes, so cancelling the worker (the user's `cancel`) cancels the
heartbeat, and a heartbeat that returns a loss cancels the worker body; exceptions from the body
propagate through `race` unchanged, so the outer `try` in `runWorker` classifies them as today.

`memberGuardApplicationName :: Text` is `"kiroku-member-guard"` and
`memberGuardHeartbeatMicros :: Int` is `30_000_000`, matching the publisher safety poll and the
notifier's reconnect cap so operators have one number to remember.

**Wire the worker.** In `Worker.hs`, add a parameter to `runWorker` after `Pool`:
`IO (Either ConnectionError Connection)`, documented as the dedicated-connection source. Replace
the `case` at the top of `body` and the `guardMember` function with

```haskell
    let guarded = case (consumerGroupGuard config, consumerGroup config) of
            (True, Just (ConsumerGroup m _)) -> withMemberGuard acquireConn emit subName m groupCtx
            _ -> id
        body = guarded $ do
            resolution <- loadCheckpoint pool config emit
            ...
```

so the lock is taken before the checkpoint is touched and released after the loop ends. Delete
`guardMember` and its comment; re-export `withMemberGuardTickForTest` from `Worker.hs` next to
the other `...ForTest` seams (the module is `other-modules`, and tests import seams from
`Worker`). In `Subscription.hs` line 200, pass `(store ^. #acquireDedicatedConnection)` as the
new argument. Update the `runWorker` Haddock's event list to mention the guard events.

**Extend the vocabulary.** In `Observability.hs`, add to `SubscriptionDbPhase`

```haskell
    | {- | The consumer-group member guard could not open its dedicated
      connection or run its lock or heartbeat statement. At start-up the
      worker fails closed; while running, the guard reconnects and re-takes
      the lock (see 'KirokuEventSubscriptionGuardReacquired').
      -}
      MemberGuard
```

and to `KirokuEvent`

```haskell
    | {- | A guarded consumer-group worker lost its dedicated guard connection,
      opened a new one, and re-took the member lock. The 'Int' is the attempt
      on which it succeeded, starting at @1@. If a peer held the lock instead,
      the worker stops with 'ConsumerGroupGuardLost' and no event of this kind
      is emitted.
      -}
      KirokuEventSubscriptionGuardReacquired !SubscriptionName !Int !SubscriptionGroupContext
```

In `Types.hs`, rewrite the `consumerGroupGuard` Haddock to describe what is held, on what, for
how long, what a crashed holder leaves behind (nothing), the connection cost, the fail-closed
start-up, the heartbeat, and the shared-key note for applications that hold the lock themselves.
Rewrite `ConsumerGroupGuardConflict`'s Haddock ("another session holds the member lock for this
`(name, member)`; that session may be another process running the member, or an application
holding Kiroku's key itself"). Add

```haskell
{- | Thrown from a running guarded worker when its dedicated guard connection
was lost and, on reconnecting, another session already held the member lock.
The worker stops so that only one live process runs the member; events in
flight replay on the next start under at-least-once delivery.
-}
data ConsumerGroupGuardLost = ConsumerGroupGuardLost
    { lostName :: !SubscriptionName
    , lostMember :: !Int32
    }
    deriving stock (Show)
    deriving anyclass (Exception)
```

and export it from `Types.hs` (which `Kiroku.Store` re-exports wholesale).

**Keep the sister packages building.** In `kiroku-metrics/src/Kiroku/Metrics/Collector.hs`, add
`MemberGuard -> c` to `bumpDbPhase` (the per-subscription `smDbErrorCount` still increments
through the existing `KirokuEventSubscriptionDbError` arm; no new Prometheus series) and
`KirokuEventSubscriptionGuardReacquired name _ _ -> touchSub km name id` to `applyEvent`. In
`kiroku-otel/src/Kiroku/Otel/Subscription.hs`, add
`KirokuEventSubscriptionGuardReacquired{} -> pure ()` next to the other untraced arms. If the
`kiroku-otel` test in `kiroku-otel/test/Main.hs` enumerates events, add the new one there too.
Check `kiroku-cli` and `kiroku-jitsurei` compile; they do not match on these types today.

**Tests.** Create `kiroku-store/test/Test/ConsumerGroupGuard.hs`, register it in
`kiroku-store/kiroku-store.cabal` (`other-modules` of `kiroku-store-test`) and in
`kiroku-store/test/Main.hs` beside `ConsumerGroup.spec`, under
`describe "consumer-group guard"`. Move the existing guard test out of `Test.ConsumerGroup` into
it, retitled `refuses start-up while an application holds Kiroku's key on its own session`
(this is IR-15 acceptance 3, answered as "it does conflict, and here is why"). Add a helper that
counts granted advisory locks for a key text held by `kiroku-member-guard` backends:

```sql
SELECT count(*)::int4
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
WHERE a.application_name = 'kiroku-member-guard'
  AND l.locktype = 'advisory' AND l.objsubid = 1 AND l.granted
  AND l.classid::bigint = ((pg_catalog.hashtextextended($1, 0) >> 32) & 4294967295)
  AND l.objid::bigint = (pg_catalog.hashtextextended($1, 0) & 4294967295)
```

and a helper that returns the pid of the guard backend for a key the same way. The tests, each
on a fresh `withMigratedTestDatabase`:

1. `refuses a duplicate member in a second store while the first is running`: open two stores on
   one connection string (two `withStore`, standing in for two processes). Start member 1 of 2 on
   a category in store A with the guard on and wait for `KirokuEventSubscriptionStarted` (or
   `currentState` to be `Just`). Start the same `(name, member)` in store B; `waitWithTimeout
   5_000_000` resolves `Right (Left e)` with `ConsumerGroupGuardConflict name 1`. Assert A's
   `currentState` is still `Just`. Cancel A, wait for it; start B again; it reaches `Started`.
2. `refuses a duplicate member within one store`: same as 1 with a single store and two
   `subscribe` calls.
3. `holds one granted session lock on a kiroku-member-guard backend for the worker's lifetime`:
   with a guarded member live, the lock-count helper returns 1 and the plain
   `pg_stat_activity` count of `kiroku-member-guard` backends is 1; after cancel and wait, poll up
   to five seconds until both are 0.
4. `a terminated holder leaves nothing behind and is replaced without operator action`: with
   member live in store A, `pg_terminate_backend` its guard pid (helper from
   `Test.Helpers.terminateBackend`), cancel A, then start the member in store B and observe
   `Started`. (Milestone 2 adds the case where A keeps running.)
5. `fails start-up closed when the guard connection cannot be opened`: build
   `store' = store & #acquireDedicatedConnection .~ pure (Left (OtherConnectionError "guard down"))`
   with an event-recording store; `subscribe store' cfg`; `wait` resolves `Left e` where
   `fromException e == Just (ConnectionUsageError (OtherConnectionError "guard down"))`; the
   recorded events contain `KirokuEventSubscriptionDbError name MemberGuard _ _` and a `Stopped`
   with `StopWorkerCrashed`, and contain no `KirokuEventSubscriptionStarted`; the checkpoint
   inventory is empty (the checkpoint row was never touched).
6. `guard off starts no guard backend and behaves as before`: a member with the guard off reaches
   `Started`; the `kiroku-member-guard` count is 0.

In `Test.PerformanceStructure`, under `describe "no-op paths use no pooled connection"`, add
`a guarded member takes its lock without a pool checkout`: on an idle store (no appends), start
member 0 of 2 on a never-used category with the guard off, wait until `currentState` is
`Just (Live _)`, cancel, and record the checkout delta; repeat with the guard on; the deltas are
equal. Add `a guarded member holds exactly one dedicated connection` asserting the
`pg_stat_activity` counts 0 (guard off) and 1 (guard on) while live.

Acceptance for Milestone 1 is the six guard tests and the two structural tests passing, every
package building, and the whole suite green:

```bash
cabal build all
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "consumer-group guard"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "performance structure"'
cabal test all
```

### Milestone 2: notice a lost guard connection and re-take the lock

At the end of this milestone, a guarded worker whose dedicated connection dies keeps running,
re-takes the lock on a new connection, and emits `KirokuEventSubscriptionGuardReacquired`; if a
peer holds the lock by then, the worker stops with `ConsumerGroupGuardLost`. Nothing on the pool
changes.

Replace the placeholder `heartbeat` in `MemberGuard.hs`:

```haskell
heartbeat :: TVar (Maybe Connection) -> IO ConsumerGroupGuardLost
heartbeat cell = loop
  where
    loop = do
        tick                                   -- threadDelay memberGuardHeartbeatMicros, or the test seam
        mConn <- readTVarIO cell
        case mConn of
            Nothing -> loop                    -- released by the bracket; we are being cancelled
            Just conn -> do
                r <- Connection.use conn pingStmt   -- SELECT true
                case r of
                    Right () -> loop
                    Left err -> do
                        emit (KirokuEventSubscriptionDbError name MemberGuard (SessionUsageError err) ctx)
                        reacquire 1
    reacquire attempt = do
        old <- atomically (swapTVar cell Nothing)
        mapM_ Connection.release old
        when (attempt > 1) (threadDelay (reconnectDelayMicros (attempt - 1)))
        r <- try (openAndLock)                 -- acquire, SET application_name, lock; bracketOnError releases on failure
        case r of
            Left (e :: UsageError) -> do
                emit (KirokuEventSubscriptionDbError name MemberGuard e ctx)
                reacquire (attempt + 1)
            Right (conn', False) -> do
                Connection.release conn'
                pure (ConsumerGroupGuardLost name member)
            Right (conn', True) -> do
                atomically (writeTVar cell (Just conn'))
                emit (KirokuEventSubscriptionGuardReacquired name attempt ctx)
                loop
```

The first reacquire attempt is immediate; later ones follow the notifier's schedule
(`1s, 2s, 4s, 8s, 16s, 30s, 30s, ...`), copied into this module as `reconnectDelayMicros` rather
than imported, so the guard does not depend on `Kiroku.Store.Notification`. The loop never gives
up on an unreachable database; only `Right (_, False)` ends it. Pinging with `SELECT true`
rather than re-running the lock statement keeps `pg_locks` at one clean row per member and makes
the ping's meaning unambiguous.

Add the test seam, in the style of `withFetchBatchHookForTest`: a `NOINLINE` global
`IORef (Maybe (IO ()))`; `withMemberGuardTickForTest :: IO () -> IO a -> IO a` installs an action
that `tick` runs instead of the sleep. A test passes `takeMVar tickVar` and controls exactly when
the heartbeat runs, which removes every timing race from the tests below.

Tests, added to `Test.ConsumerGroupGuard`:

7. `re-takes the lock on a new connection after its guard backend is terminated`: guarded member
   live in an event-recording store, seam installed. Record the guard pid. Terminate it. Put one
   tick. Wait (up to five seconds) for `KirokuEventSubscriptionGuardReacquired name 1 _` in the
   recorded events. Assert a `KirokuEventSubscriptionDbError name MemberGuard _ _` preceded it,
   the worker's `currentState` is still `Just`, the lock-count helper returns 1, and the guard
   pid differs from the recorded one.
8. `stops with ConsumerGroupGuardLost when a peer took the member while the guard was down`:
   as 7, but between terminating the backend and putting the tick, take the session lock on a
   raw test connection with `pg_advisory_lock(hashtextextended('name:member', 0))` (blocking; it
   returns as soon as the terminated backend's lock is gone). Put the tick. `wait` resolves
   `Left e` with `fromException e == Just (ConsumerGroupGuardLost name member)`, the recorded
   `Stopped` carries `StopWorkerCrashed`, and no `GuardReacquired` was emitted. Release the test
   connection.
9. `keeps running through an unreachable database until the lock is re-taken`: as 7, but make
   `acquireDedicatedConnection` fail twice before succeeding (an `IORef` counter around the real
   connector). After the tick, two `MemberGuard` database errors are recorded, then
   `KirokuEventSubscriptionGuardReacquired name 3 _`, and the worker is still live. Because the
   backoff before attempts 2 and 3 is 1 s and 2 s, this test takes about three seconds; keep it.

Acceptance for Milestone 2 is tests 7 to 9 passing alongside 1 to 6, plus the structural tests,
plus `cabal test all` green.

### Milestone 3: performance evidence

At the end of this milestone the authoritative gates have been run on the finished code, the
opt-in start-up cost is measured, and both are written into this plan.

In `kiroku-store/bench/Main.hs`, next to `runSubscriptionCatchup`, add
`runMemberStartup :: KirokuStore -> IORef Int -> Bool -> IO ()`: take a run id, append one event
to a fresh stream `guardbench<id>-s`, subscribe as member 0 of 1 on category `guardbench<id>`
with `consumerGroupGuard` set from the flag, a handler that returns `Stop` on the first event,
`missingCheckpointPolicy = FromBeginning`, and `wait` for the handle. The cell therefore times
subscribe, guard acquisition, checkpoint initialization, one catch-up fetch, one delivery, one
checkpoint save, worker exit, and guard release; the two cells differ only by the flag. Add a
group after `reliability-audit`:

```haskell
                        , bgroup
                            "consumer-group-guard"
                            [ bench "member startup guard off" $ whnfIO $ runMemberStartup store guardCounter False
                            , bench "member startup guard on" $ whnfIO $ runMemberStartup store guardCounter True
                            ]
```

Then, in order: `just bench-baseline-check` (expected to fail with a diff naming the two missing
rows), `just bench-baseline` (refreshes `kiroku-store/bench/results/baseline.csv`; review the
full diff; the reason is the benchmark-set change recorded in this plan's Decision Log),
`just bench-baseline-check` (green), `just perf-check` (green), and `just perf-telemetry`. Record
in Surprises & Discoveries the two new cells' timings and their ratio, the
`subscription category catch-up 100 events` timing against the previous baseline row (copy the
old row before refreshing), and the workload gate's ratios. The expectation is that the guard-on
cell is the guard-off cell plus a low single-digit-millisecond connect on a local socket, that
the catch-up cell moves only within run-to-run noise, and that the workload gate's ratios are
unchanged, because none of its statements were touched.

Acceptance for Milestone 3 is `just perf-check` exiting 0, `just bench-baseline-check` exiting 0,
and the numbers recorded here.

### Milestone 4: documentation, ADR, changelog, and release preparation

At the end of this milestone every place that describes the guard describes the new one, the
decision is durable in an ADR, the changelog and versions are ready, and publication awaits the
user's confirmation.

Documentation edits, each replacing the "startup detection probe, not a lifetime-held lock"
language:

- `docs/user/consumer-groups.md`: the field table row for `consumerGroupGuard` (line 104) and the
  paragraph under `## Operational Invariant` (lines 124 to 134). Say what is held (a session-level
  advisory lock on a dedicated connection), for how long (until the worker stops), what a crashed
  holder leaves behind (nothing; the session's locks die with it, and the replacement starts
  without operator action), the cost (one extra PostgreSQL connection per guarded member), the
  start-up failure (`ConsumerGroupGuardConflict` while a peer runs; a database error fails
  start-up), the heartbeat (a lost guard connection is re-taken within thirty seconds, and
  `ConsumerGroupGuardLost` stops the worker if a peer took the member), the shared key
  (`hashtextextended('<name>:<member>', 0)`, stable, database-global, and the reason an
  application holding the same key on its own connection is refused), and the session-mode
  pooler requirement.
- `docs/architecture/subscriptions.md`: the paragraph at line 400 under
  `## Consumer-Group Subscriptions`; add `Kiroku.Store.Subscription.MemberGuard` to
  `## Source Map`; delete the "Make `consumerGroupGuard` a lifetime-held session-level guard"
  bullet under `## Improvement Areas` (line 620).
- `docs/capabilities/partitioned-consumer-groups.md`: the description in the frontmatter
  ("optional startup conflict guard" becomes "optional lifetime-held member guard"), the first
  `## Limits` bullet, and an evidence entry for `kiroku-store/test/Test/ConsumerGroupGuard.hs`;
  bump `timestamp`; then `okf log add docs/capabilities --kind Update -m "CAP-13 now records the
  lifetime-held session-level member guard on a dedicated connection with heartbeat
  reacquisition (plan 93)."` and `just capabilities-validate`.
- `docs/PRODUCTION-TUNING.md`, `## Connection pool sizing`, item 2: state the connection budget
  as `poolSize + 1` (the listener) `+ the number of guarded consumer-group members in the
  process`, and that `idle_session_timeout`, if set, must exceed thirty seconds for the guard
  session (the heartbeat resets the idle clock) as it must for the listener.
- `docs/guides/consuming-the-event-log.md` (line 428) and `docs/guides/building-a-projection.md`
  (line 277) already say "set `consumerGroupGuard = True` in production to fail fast on a
  duplicated member"; that sentence is now fully true, so leave it, but check neither guide
  repeats the probe caveat.
- `kiroku-store/CHANGELOG.md`: a new `## 0.10.0.0 — Unreleased` section (date filled at release)
  with a `### Breaking Changes` entry naming: the guard's new semantics and connection cost; the
  fail-closed start-up replacing degrade-open; the new `KirokuStore` field and `runWorker`
  parameter; the new `MemberGuard` phase, `KirokuEventSubscriptionGuardReacquired` event, and
  `ConsumerGroupGuardLost` exception, with the note that exhaustive matches need new arms; the
  session-mode requirement shared with the listener; and the explicit statement that append,
  read, publisher, and worker data paths are unchanged and a guarded start-up no longer uses a
  pool checkout. Under `### Other Changes`, the two benchmark cells and the structural tests.

ADR work, following the skill's `ADR.md`. Run
`okf id next docs/adr --profile docs/adr/profile.dhall ADR` (it returned `ADR-11` on
2026-09-30; use whatever it returns). Create
`docs/adr/0011-consumer-group-member-guard-is-a-lifetime-session-lock-on-a-dedicated-connection.md`
with the bundle's frontmatter (`type: Architecture Decision Record`, `title`, one-sentence
`description`, `docId: ADR-11`, `status: Accepted`, `date`, `timestamp`, and a `generated` block
naming this plan's model), recording: the decision (session-level advisory lock on a dedicated
connection held for the worker's lifetime; key `hashtextextended('<name>:<member>', 0)` stable and
database-global; fail closed at start-up; heartbeat reacquisition; stop only when a peer holds
the lock), the consequences (one connection per guarded member; session-mode pooler required;
applications must not hold the same key on their own connection when the guard is on; no
hot-path cost, pinned by structural tests), and the alternatives rejected (transaction-scoped
probe; coupling the lock to the checkpoint-writing connection, rejected because it moves the
checkpoint write off the pool and ties reconnect handling to the data path; a lock table with
leases, rejected as out of scope per IR-15's boundaries). Amend
`docs/adr/0002-static-hash-partitioned-consumer-groups.md`: the advisory-lock bullet under
`## Decision` gains "held as a session-level lock on a dedicated connection for the worker's
lifetime (ADR-11)"; bump its `timestamp`. Add both to `docs/adr/index.md` in the bundle's list
style, then

```bash
okf log add docs/adr --kind Addition -m "ADR-11 records, for IR-15 and plan 93, that the consumer-group member guard is a session-level advisory lock held on a dedicated connection for the worker's lifetime, keyed hashtextextended('<name>:<member>', 0), failing start-up closed and re-taking the lock by heartbeat."
okf log add docs/adr --kind Update -m "ADR-2's optional advisory lock is now the lifetime-held session lock of ADR-11."
just adr-validate
```

Release preparation, confirmation-gated. Bump `kiroku-store` to `0.10.0.0` in
`kiroku-store/kiroku-store.cabal`. Every sister package pins `kiroku-store ^>=0.9.0.1`
(`kiroku-metrics` at three places, `kiroku-otel` at two, `shibuya-kiroku-adapter` at three,
`kiroku-cli` at two); change each to `^>=0.10.0.0` and add a changelog line to each package that
has one. Proposed versions, to be verified against Hackage and the annotated tags before
publication rather than trusted from the local tree, as the memory for this repository requires:
`kiroku-metrics 0.1.0.11`, `kiroku-otel 0.2.0.11`, `shibuya-kiroku-adapter 0.5.1.6`,
`kiroku-cli 0.2.0.9` (each a patch: new match arms or bounds only, no API change; the working
tree and the annotated tags already carry `kiroku-otel 0.2.0.10` and `kiroku-cli 0.2.0.8`, so the
first draft's proposal of those two numbers was stale). If plan 92 is implemented before this
release, the adapter ships as `0.6.0.0` with its new field in this cohort instead of `0.5.1.6`
(see the Decision Log). Present the
exact set to the user and publish nothing without their explicit confirmation; after publication,
set IR-15 to `completed` with a log entry, and note in IR-17's file that its prerequisite is
released.

Acceptance for Milestone 4 is `just adr-validate` and `just capabilities-validate` exiting 0,
`cabal build all` green with the new bounds, and the documentation reading correctly end to end
for someone who has never seen the probe.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`
unless stated. The test suites start their own ephemeral PostgreSQL; no service needs to be up.

Build and run the focused tests while working on Milestones 1 and 2:

```bash
cabal build all
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "consumer-group guard"'
```

Expected tail of a green run (names abbreviated):

```text
consumer-group guard
  refuses a duplicate member in a second store while the first is running [✔]
  refuses a duplicate member within one store [✔]
  holds one granted session lock on a kiroku-member-guard backend for the worker's lifetime [✔]
  a terminated holder leaves nothing behind and is replaced without operator action [✔]
  fails start-up closed when the guard connection cannot be opened [✔]
  guard off starts no guard backend and behaves as before [✔]
  refuses start-up while an application holds Kiroku's key on its own session [✔]
  re-takes the lock on a new connection after its guard backend is terminated [✔]
  stops with ConsumerGroupGuardLost when a peer took the member while the guard was down [✔]
  keeps running through an unreachable database until the lock is re-taken [✔]
```

Structural gate and full suite:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "performance structure"'
cabal test all
```

Milestone 3 sequence:

```bash
grep 'subscription category catch-up' kiroku-store/bench/results/baseline.csv   # keep this line for the record
just bench-baseline-check     # expected: exit 1, diff lists the two consumer-group-guard rows as missing
just bench-baseline           # refresh; review: git diff kiroku-store/bench/results/baseline.csv
just bench-baseline-check     # expected: exit 0
just perf-check               # expected: structural block green, workload gate ratios below 0.90
just perf-telemetry           # expected: exit 0; note the catch-up and guard cells
```

Milestone 4 validation:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
just adr-validate
just capabilities-validate
okf validate docs/improvement-requests --strict
```

The last command exits 1 on a clean tree because of missing-`reviews` recommendations; judge it
by the absence of any other error line, as this repository's memory records.

Commit after each milestone, in Conventional Commits form, on the current branch, with both
trailers:

```text
feat(subscription): hold the consumer-group member guard for the worker's lifetime

Take pg_try_advisory_lock on a dedicated connection before the checkpoint
is read and keep it until the worker exits; fail start-up closed on a
guard error. Guard off is unchanged; no pooled statement is added.

ExecPlan: docs/plans/93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime.md
Intention: intention_01m3t4842ae5vs772q428rbywa
```


## Validation and Acceptance

The user-visible acceptance, in IR-15's own terms:

1. Two processes (or two `withSubscription` calls in two stores on one database) configured as
   the same `(name, member)` with the guard on: the second fails start-up with
   `ConsumerGroupGuardConflict` while the first is running, and starts once the first has
   stopped. Proven by tests 1 and 2.
2. A process whose holder crashed (connection dropped) is replaced without operator action.
   Proven by test 4, and by tests 7 and 8 for the surviving process's side.
3. A process with the guard on that also holds the same session-level lock on its own connection
   is refused, and the documentation says so and why (locks are per session). Proven by the
   moved test and the user-guide paragraph.
4. Existing behavior with the guard off is unchanged. Proven by test 6, the unchanged
   `Test.ConsumerGroup` suite, the structural zero-backend check, and the unchanged historical
   cell.

The performance acceptance: `just perf-check` exits 0 after the change; the structural checks
pin that the guard uses no pool checkout and that the guard-off path opens no connection; the
`subscription category catch-up 100 events` cell is within noise of its previous row; the
guard-on start-up cell exceeds the guard-off cell by only a connect handshake, and the number is
written into Surprises & Discoveries.

A manual demonstration for a reader who wants to see it: run any consumer-group example twice
with the guard on (for instance adapt `kiroku-jitsurei/app/Main.hs` to set
`consumerGroupGuard = True` and start it in two terminals against one database). The second
process prints a `ConsumerGroupGuardConflict` for each member and exits; `psql -c "SELECT pid,
application_name FROM pg_stat_activity WHERE application_name = 'kiroku-member-guard'"` shows
one row per member of the first process; killing the first process makes those rows disappear
and lets the second start.


## Idempotence and Recovery

All code edits are additive or replace one function and can be re-applied from this plan. The
test suites create and drop their own databases; rerunning them is safe. The only step that
rewrites a checked-in artifact wholesale is `just bench-baseline`; before running it, copy the
old `subscription category catch-up 100 events` row into this plan, and if the refreshed CSV
looks wrong (a cell moved by more than noise for no reason this plan explains), restore it with
`git checkout -- kiroku-store/bench/results/baseline.csv`, investigate, and refresh again on a
quiet host. The OKF log commands append one entry each; running one twice adds a duplicate line
that must be removed by hand, so run each once. Version bumps and bound changes are plain text
edits; nothing is published until the user confirms, so there is no remote state to roll back
before that point. If Milestone 2 has to be reverted on its own, the `heartbeat` placeholder from
Milestone 1 restores a passive lifetime lock with no other change.


## Interfaces and Dependencies

Libraries already in `kiroku-store`'s `build-depends` and sufficient for this plan: `hasql`
(`Hasql.Connection`, `Hasql.Connection.Settings`, `Hasql.Session`, `Hasql.Statement`,
`Hasql.Encoders`, `Hasql.Decoders`, `Hasql.Errors`), `hasql-pool` (`Hasql.Pool.UsageError`),
`async` (`Control.Concurrent.Async.race`), `stm` (`TVar`), `contravariant-extras` (`contrazip2`),
`base` (`bracket`, `bracketOnError`, `try`, `throwIO`, `IORef`). No new dependency.

After Milestone 1 these must exist:

```haskell
-- Kiroku.Store.Connection
data KirokuStore = KirokuStore
    { pool :: !Pool
    , schema :: !Text
    , notifier :: !Notifier
    , publisher :: !EventPublisher
    , eventHandler :: !(Maybe (KirokuEvent -> IO ()))
    , storeSettings :: !StoreSettings
    , subscriptionRegistry :: !(TVar (Map (SubscriptionName, Int32) (Unique, TVar SubscriptionState)))
    , acquireDedicatedConnection :: !(IO (Either ConnectionError Connection))
    }

-- Kiroku.Store.Subscription.MemberGuard (other-modules)
withMemberGuard ::
    IO (Either ConnectionError Connection) ->
    (KirokuEvent -> IO ()) ->
    SubscriptionName -> Int32 -> SubscriptionGroupContext ->
    IO a -> IO a
memberGuardApplicationName :: Text          -- "kiroku-member-guard"
memberGuardHeartbeatMicros :: Int           -- 30_000_000
withMemberGuardTickForTest :: IO () -> IO a -> IO a

-- Kiroku.Store.Subscription.Worker (re-exports the seam)
runWorker ::
    (MonadIO m) =>
    Pool ->
    IO (Either ConnectionError Connection) ->
    LiveSource ->
    TVar SubscriptionState ->
    TVar GlobalPosition ->
    TVar (Map Text Word64) ->
    SubscriptionConfig ->
    Maybe (KirokuEvent -> IO ()) ->
    StoreSettings ->
    m ()
withMemberGuardTickForTest :: IO () -> IO a -> IO a

-- Kiroku.Store.Subscription.Types
data ConsumerGroupGuardLost = ConsumerGroupGuardLost
    { lostName :: !SubscriptionName, lostMember :: !Int32 }

-- Kiroku.Store.Observability
data SubscriptionDbPhase = LoadCheckpoint | FetchBatch | SaveCheckpoint | MemberGuard
-- KirokuEvent gains:
--   KirokuEventSubscriptionGuardReacquired !SubscriptionName !Int !SubscriptionGroupContext
```

After Milestone 2, `heartbeat :: TVar (Maybe Connection) -> IO ConsumerGroupGuardLost` inside
`MemberGuard.hs` is the real loop described above, and the seam governs its cadence.

After Milestone 3, `kiroku-store/bench/Main.hs` exports nothing new but contains
`runMemberStartup :: KirokuStore -> IORef Int -> Bool -> IO ()` and the `consumer-group-guard`
group, and `kiroku-store/bench/results/baseline.csv` has rows
`All.consumer-group-guard.member startup guard off` and `All.consumer-group-guard.member startup guard on`.

Services: PostgreSQL 17 or 18 as the test matrix already requires; the tests reach it through
`ephemeral-pg`. The guard connection inherits every libpq option in the store's connection string
(`connect_timeout`, `keepalives_*`, `tcp_user_timeout`); the plan adds none, and the production
guide should point operators at those options for the same reasons it does for the listener.


## Revision Notes

- 2026-09-30: Reconciled with plan 92, which was first drafted to cover IR-15 and IR-17 together and
  is now the IR-17 adapter plan depending on this one. Changes: the IR-15 acceptance step is
  recorded as done (the request file and bundle log already name this plan); a Dependent plan
  subsection and two Decision Log additions record the dependency and the release coordination;
  the proposed `kiroku-otel` and `kiroku-cli` patch versions were corrected against the tags
  already present in the working tree. No design decision of this plan changed.
