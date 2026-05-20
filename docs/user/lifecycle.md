# Stream Lifecycle

Kiroku gives streams two kinds of deletion: a reversible **soft delete** that
hides a stream while keeping its history, and an irreversible **hard delete**
that removes rows for maintenance or GDPR-style erasure. This guide covers
both, plus restoring a soft-deleted stream. For the table-level mechanics see
[Database Schema](schema.md).

All three operations reject the reserved name `$all` with
`ReservedStreamName`, so callers cannot hide, remove, or restore the internal
global stream.

## Soft Delete

```haskell
softDeleteStream ::
  (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
```

`softDeleteStream` sets `deleted_at` on the stream row without removing any
events. A soft-deleted stream is:

- **invisible** to `readStreamForward` / `readStreamBackward` (they return an
  empty vector) and to `appendToStream` (which fails with `StreamNotFound` or
  `StreamAlreadyExists` depending on the `ExpectedVersion`);
- **still visible** in the global `$all` stream and in `readCategory` — the
  global log is append-only, so its history survives the hide.

It returns `Just streamId` on success, or `Nothing` if the stream did not
exist or was already soft-deleted. Reverse it with `undeleteStream`.

Soft delete is the right default for "this aggregate is closed / archived /
no longer active" — the history remains auditable and reads of `$all` and
the category are unaffected.

## Undelete

```haskell
undeleteStream ::
  (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
```

`undeleteStream` clears `deleted_at`. Reads of the restored stream return its
full history, and subsequent appends behave as if the soft delete never
happened. It returns `Just streamId` on success, or `Nothing` if the stream
is missing or was not soft-deleted (already live).

## Hard Delete

```haskell
hardDeleteStream ::
  (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
```

`hardDeleteStream` permanently removes a stream, its links, and its events
where they are not referenced by other streams. It is intended for
maintenance and GDPR-style erasure. There is **no undo** — for reversible
deletes use `softDeleteStream`. It returns `Just streamId` on success, or
`Nothing` if the stream did not exist.

### Event-Preservation Semantics

The interpreter cleans up the stream's junction rows (`stream_events`) first,
then deletes orphaned `events` rows. An event that was **linked** into a
stream *not* part of this deletion is preserved, so the surviving linked
stream stays readable. Only events with no remaining stream entries are
removed. See [Linking Events](linking.md) for how links interact with
deletes.

### Authorization Model

Hard delete is gated by a session-local PostgreSQL GUC,
`kiroku.enable_hard_deletes`, which the interpreter sets inside its own
transaction:

```sql
SET LOCAL kiroku.enable_hard_deletes = 'on';
```

Without that setting, the `protect_deletion` and `protect_truncation`
triggers reject any direct `DELETE` or `TRUNCATE` against `events`,
`stream_events`, and `streams`.

**The GUC is an advisory protection, not a security boundary.** Any session
with `DELETE` privilege can issue `SET LOCAL` itself — PostgreSQL grants it to
every session. The trigger exists to make *accidental* deletes (a typo, an
ad-hoc operator query, an ORM that does not know the tables are append-only)
fail loudly, not to enforce role-based access control.

For stricter control, prefer one of:

- Run the application as a low-privilege role with only `INSERT, UPDATE,
  SELECT` on the data tables (no `DELETE`). Soft delete via `softDeleteStream`
  still works. Issue hard deletes from a separate, more privileged role gated
  by your own access controls.
- Or wrap calls to `hardDeleteStream` in your application's authorization
  layer before they reach the function. Do not read the `protect_deletion`
  trigger as a security boundary.

### Auditing Hard Deletes

`hardDeleteStream` writes no in-band audit row. Operators who need an audit
trail should capture it in one of two ways:

- The store emits `KirokuEventHardDeleteIssued streamName streamId` on a
  successful hard delete — a fail-safe signal you can route through
  `eventHandler` (see [Observability](observability.md)).
- For compliance-grade auditing, record an application-level event **before**
  calling `hardDeleteStream`, so the intent is durably logged even if the
  process dies mid-operation. See `docs/PRODUCTION-DEPLOYMENT.md`.

## Choosing Soft vs. Hard

| | Soft delete | Hard delete |
| --- | --- | --- |
| Reversible | Yes (`undeleteStream`) | No |
| History in `$all` / category | Preserved | Removed |
| Direct stream reads/appends | Hidden / rejected | Stream gone |
| Typical use | Archiving, closing an aggregate | Maintenance, GDPR erasure |
| Privilege needed | `UPDATE` | `DELETE` + the GUC |

Default to soft delete. Reach for hard delete only when data must genuinely
be removed, and route it through privilege separation and auditing as above.

## See Also

- [Database Schema](schema.md) — `deleted_at`, the deletion triggers, and the
  maintenance GUC.
- [Linking Events](linking.md) — how hard delete preserves linked events.
- [Observability](observability.md) — the hard-delete audit event.
