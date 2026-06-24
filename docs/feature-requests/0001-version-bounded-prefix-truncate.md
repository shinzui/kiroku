# Feature Request 0001: Version-bounded prefix-truncate for a single stream

- **Status:** Proposed — 2026-06-24
- **Requested by:** notification-hub (Nadeem)
- **Driving use case:** notification-hub "close-the-book" preference compaction —
  `docs/plans/24-true-preference-compaction-via-kiroku-prefix-truncate.md` and
  `docs/masterplans/4-notification-hub-phase-2-delivery-tracking-outbox-runtime-foundation.md`
  in the notification-hub repository.
- **Affected package:** `kiroku-store` (`Kiroku.Store.Lifecycle`, `Kiroku.Store.Effect`,
  the interpreter, and `kiroku-store-migrations`).

## Summary

Add a first-class lifecycle operation that **permanently removes the events of one stream
whose per-stream version is below a caller-supplied bound**, preserving the event at that
version and everything after it. In other words, a *prefix-truncate*: delete `[v0, V)` of a
stream, keep `[V, …]`.

Today `Kiroku.Store.Lifecycle` offers only whole-stream lifecycle operations:

```haskell
softDeleteStream :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
hardDeleteStream :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
undeleteStream   :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
```

backed by the `Store` effect constructors:

```haskell
SoftDeleteStream :: StreamName -> Store m (Maybe StreamId)
HardDeleteStream :: StreamName -> Store m (Maybe StreamId)
UndeleteStream   :: StreamName -> Store m (Maybe StreamId)
```

There is **no version-bounded delete**: a caller can drop a whole stream or none of it. A
verification of `Kiroku.Store.Lifecycle` at the current pin and at `kiroku` HEAD (`322096c`)
confirmed no such primitive exists.

## Motivation

The event-sourcing "close-the-book" (a.k.a. snapshot-and-compact) pattern keeps long-lived
streams bounded: when a stream accumulates many events, the application writes a single
*snapshot* event capturing current aggregate state, then deletes every event **before** the
snapshot so that rehydration only ever reads from the snapshot forward. notification-hub's
preference streams are exactly this shape — a recipient who adjusts notification preferences
over years can accumulate hundreds of events in one `preference-<recipientId>` stream, and the
service's data-lifecycle design (`docs/spec/ARCHITECTURE.md` → "Close-the-Book for Preference
Streams") calls for truncating the pre-snapshot prefix.

`hardDeleteStream` cannot serve this: it removes the *entire* stream, including the snapshot
the application just wrote. `softDeleteStream` hides the stream but reclaims nothing and breaks
rehydration. The capability that is missing is "delete everything in this stream older than
version V, keep V and newer."

### Why a first-class primitive rather than an application-side workaround

Without this primitive, notification-hub's EP-24 plans to replicate kiroku's own hard-delete
transaction outside kiroku — via the public `Kiroku.Store.Transaction.runTransaction` escape
hatch — by: setting the `kiroku.enable_hard_deletes` session GUC, then deleting the
`stream_events` junction rows, dead-letter rows, and orphaned `events` rows for the target
stream, but **bounded by `version < V`** and **omitting** the final `streams`-row delete (so
the stream survives with only `[V, …]`).

That works, but it duplicates kiroku-internal invariants (the junction → dead-letter →
orphan-event deletion order, the GUC handshake, the `$all`/`ReservedStreamName` guards, the
`protect_deletion` / `protect_truncation` trigger contract) in an application that has no
stable contract on them. Any change to kiroku's deletion internals silently breaks the
workaround. Keeping the invariant inside kiroku — where the migrations, triggers, and
interpreter already live together — is the correct home.

## Proposed API

A new `Lifecycle` function and matching `Store` constructor. Naming follows the existing
`hardDeleteStream` (it is a hard, irreversible delete of a *prefix*):

```haskell
-- | Permanently remove the events of a stream whose per-stream version is
-- strictly below @before@, preserving the event at @before@ and all later
-- events. Intended for close-the-book compaction: write a snapshot event,
-- then truncate the prefix that precedes it.
--
-- Shares the hard-delete authorization model (the @kiroku.enable_hard_deletes@
-- session GUC + @protect_deletion@/@protect_truncation@ triggers) and the
-- orphan-event preservation semantics of 'hardDeleteStream': junction rows for
-- the truncated prefix are removed first, then events orphaned by that removal
-- are deleted, while events still linked from other streams are preserved.
--
-- The stream row itself is never removed (unlike 'hardDeleteStream'); the
-- stream remains live and appendable. Rejects the reserved @$all@ stream with
-- 'ReservedStreamName'. Returns the number of event-links removed (@Just n@),
-- or @Nothing@ if the stream did not exist. There is no undo.
hardTruncateStreamBefore ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    StreamVersion ->   -- ^ exclusive upper bound; keep events with version >= this
    Eff es (Maybe Int64)
```

```haskell
-- in Kiroku.Store.Effect
HardTruncateStreamBefore :: StreamName -> StreamVersion -> Store m (Maybe Int64)
```

(`StreamVersion` is the existing `newtype StreamVersion = StreamVersion Int64` in
`Kiroku.Store.Types`.)

### Semantics to pin down

1. **Bound is exclusive and version-based.** Delete links where the stream-local version is
   `< before`; keep `>= before`. The caller passes the snapshot event's version as `before`.
2. **`$all` / global log.** `hardDeleteStream` already removes orphaned events from `events`,
   so they leave the `$all` global read stream. Prefix-truncate should behave identically for
   the truncated prefix: pre-snapshot events that become orphaned are removed from `$all` too.
   This is acceptable and expected for compaction, but it is a deliberate semantic (the global
   log is no longer a complete history of the truncated stream) and should be documented as
   such — mirroring the note already on `hardDeleteStream`. If preserving `$all` history is
   desired, that should be a separate, explicitly-flagged variant.
3. **Stream survives.** Unlike `hardDeleteStream`, the `streams` row is preserved and the
   stream stays appendable; only its prefix of event-links/events is removed.
4. **Idempotence.** Re-running with the same `before` after a prior truncate removes nothing
   further and returns `Just 0` (or `Nothing` if the stream was meanwhile deleted) — safe to
   retry after a crash between snapshot-write and truncate.
5. **Concurrency.** Define behavior relative to concurrent appends (appends are `>= before` so
   are never in scope; the operation should take the same row locks the hard-delete path takes).
6. **Authorization.** Reuse `kiroku.enable_hard_deletes` and the existing triggers verbatim —
   no new authorization surface.

## Suggested implementation sketch

Mirror the existing `HardDeleteStream` interpreter arm (around `kiroku-store/src/Kiroku/Store/Effect.hs:299`),
adding the version bound:

- New SQL statement alongside the hard-delete statements (the prefix-truncate deletes
  `stream_events` for the stream where `version < $before`, then dead-letter rows for those
  links, then `events` rows orphaned by the removal — but does **not** delete the `streams`
  row).
- New `Store` constructor `HardTruncateStreamBefore` and its interpreter arm setting the
  `kiroku.enable_hard_deletes` GUC inside the transaction, exactly as `HardDeleteStream` does.
- Export `hardTruncateStreamBefore` from `Kiroku.Store.Lifecycle`.
- No new migration is required if the existing `protect_deletion` / `protect_truncation`
  triggers already admit `DELETE` under the GUC; confirm the triggers do not assume
  whole-stream deletion.

## Acceptance / tests

- A stream with N events; write a snapshot at version V; `hardTruncateStreamBefore name V`
  returns `Just (V)` (links removed) and a subsequent `readStreamForward` returns exactly the
  snapshot-forward events; the rehydrated aggregate state is identical to pre-truncate.
- Re-running the truncate is a no-op (`Just 0`).
- `$all` no longer returns the truncated prefix's orphaned events (documented behavior).
- Events linked from *other* streams are preserved (same preservation test `hardDeleteStream`
  has).
- `$all` as the stream name is rejected with `ReservedStreamName`.
- Direct `DELETE` without the GUC still trips `protect_deletion`.

## Downstream consumer

Once shipped and the notification-hub keiro/kiroku pins advance to a release containing it
(notification-hub EP-21, `docs/plans/21-keiro-kiroku-family-pin-bump-forward-realignment.md`),
notification-hub EP-24 will drop its `runTransaction`-based workaround and call
`hardTruncateStreamBefore` directly. Until then EP-24 ships the in-repo workaround, gated on the
projection frontier, so the feature is not on notification-hub's critical path.
