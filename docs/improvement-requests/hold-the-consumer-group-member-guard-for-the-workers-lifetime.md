---
type: Improvement Request
title: Hold the consumer-group member guard for the worker's lifetime
description: >-
  Make consumerGroupGuard exclude a concurrently running (name, member) for the worker's whole
  lifetime by holding a session-level advisory lock on a dedicated connection, instead of the
  transaction-scoped probe that releases at once and cannot see a running peer, so two processes
  configured as the same member are refused instead of double-processing.
generated:
  by: anthropic/claude-fable-5-1
  at: "2026-09-24T18:40:00Z"
timestamp: "2026-09-24T18:40:00Z"
requestId: IR-15
status: proposed
origin: mori://shinzui/notification-hub
---

# Improvement Request: Hold the Consumer-Group Member Guard for the Worker's Lifetime

## Status

Proposed by Notification Hub (`mori://shinzui/notification-hub`), found while implementing worker replicas under
`mori://shinzui/notification-hub/plans/75-run-delivery-queues-with-independent-truly-concurrent-capacity` on
2026-09-24. The application works around it today by holding its own session-level lock with
Kiroku's key (recorded in `mori://shinzui/notification-hub/adrs/application-owned-delivery-capacity`, artifact-level
URI pending), so this request is non-blocking.

## Context

`SubscriptionConfigM.consumerGroupGuard` (kiroku-store 0.8.0.0) promises that "two processes cannot
both run the same (name, member) at once". Its implementation, `guardMember` in
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, runs
`SELECT pg_try_advisory_xact_lock(hashtextextended($1 || ':' || $2::text, 0))` as one statement on
a pooled connection. The lock is transaction-scoped, the statement is its own transaction, and the
connection returns to the pool, so the lock is gone before the worker reads its checkpoint. A
second process started a moment later takes the same lock successfully and runs the same member
against the same checkpoint row, which is exactly the double-processing and checkpoint race the
guard exists to prevent. The code comment says so ("a startup /detection/ probe, not a
lifetime-held lock" with "full mutual exclusion" recorded as follow-up) and the field's Haddock
points readers at it, but a configuration field named "guard" that admits every peer except one
probing in the same instant is easy to trust more than it deserves.

Notification Hub's worker registry now takes `pg_try_advisory_lock` (session-level) on the same
`hashtextextended('<name>:<member>', 0)` key on a dedicated connection it holds for the row's
lifetime, refuses start-up on `false`, and sets `consumerGroupGuard = False`, because the probe
from another pool connection in the same process would otherwise collide with the lock it holds
itself. The key is shared deliberately so that a Kiroku-guarded process elsewhere is still refused.

## Requested Change

1. When `consumerGroupGuard` is `True`, acquire a session-level advisory lock
   (`pg_try_advisory_lock`) on a connection dedicated to the subscription worker (the
   `Kiroku.Store.Notification.Notifier` pattern the comment already names), keep it for the
   worker's lifetime, and release it with the connection when the worker stops.
2. Keep the key `hashtextextended('<name>:<member>', 0)` so applications that took the lock
   themselves in the meantime stay compatible, and document the key as stable.
3. Throw `ConsumerGroupGuardConflict` at start-up when the lock is held elsewhere, as today, and
   emit the existing lifecycle event; on a database error keep the documented degrade-open
   behavior or make it configurable, but say which in the Haddock.
4. Update the field's Haddock and the subscriptions guide so that "guard" describes what is held,
   for how long, and what a crashed holder leaves behind (nothing: the session's locks die with it).

## Boundaries

This request is about exclusion of a duplicate member at start-up and for the worker's lifetime.
It does not ask for automatic member assignment, rebalancing, lease renewal, or a lock table;
`Kiroku.Store.Subscription.Types.ConsumerGroup` and the checkpoint schema are unchanged.

## Acceptance

1. Two processes (or two `withSubscription` calls in two stores on one database) configured as the
   same `(name, member)` with the guard on: the second fails start-up with
   `ConsumerGroupGuardConflict` while the first is running, and starts once the first has stopped.
2. A process whose holder crashed (connection dropped) can be replaced without operator action.
3. A process with the guard on that also holds the same session-level lock on its own connection
   does not conflict with itself, or the documentation says that it does and why.
4. Existing behavior with the guard off is unchanged.

## Requested Deliverables

The lifetime-held guard in `kiroku-store` with a two-worker test, the Haddock and guide updates,
and a changelog entry with a PVP-appropriate bump, at kiroku's discretion.
