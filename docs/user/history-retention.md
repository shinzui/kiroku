# Replay-History Retention

Kiroku offers two opt-in coordination tools for work that must see stable
history:

- a durable, renewable retention lease for a long `$all` or category rebuild;
- a transaction-scoped stream guard for a short, one-stream repair.

Neither tool changes ordinary append or read behavior. A lease prevents
supported hard delete and authorized direct `DELETE` or `TRUNCATE`; it does not
block append, soft delete, undelete, or logical truncate. A stream guard blocks
every mutation that could change that stream's ordered history until the
caller's transaction commits or rolls back.

## Long Rebuilds

Construct validated operational metadata, acquire a lease, and retain the
returned `protectedThrough` position as the inclusive rebuild ceiling:

```haskell
import Data.Time.Clock (secondsToDiffTime)
import Kiroku.Store

rebuildRequest :: Either HistoryRetentionRequestError HistoryRetentionLeaseRequest
rebuildRequest = do
  owner <- mkHistoryRetentionLeaseOwner "orders-v2-rebuild"
  reason <- mkHistoryRetentionLeaseReason "rebuild orders projection into v2"
  duration <- mkHistoryRetentionLeaseDuration (secondsToDiffTime 900)
  pure HistoryRetentionLeaseRequest
    { owner = owner
    , reason = reason
    , duration = duration
    }

startRebuild request = do
  lease <- acquireHistoryRetentionLease request
  let HistoryRetentionLease
        { leaseId = acquiredId
        , owner = acquiredOwner
        , protectedThrough = ceiling
        } = lease
      handle = HistoryRetentionLeaseHandle acquiredId acquiredOwner
  -- Page readAllForward/readCategory from position zero, ignoring rows after
  -- ceiling. Renew handle before expiresAt while the rebuild is still active.
  pure (handle, ceiling)
```

Lease duration is validated from one second through one hour. PostgreSQL
computes `createdAt`, `renewedAt`, and `expiresAt`; application wall-clock time
is not authoritative. Schedule renewal with margin for database latency and
outages, and handle every `HistoryRetentionRenewalError`. Renewal never
resurrects an expired or released lease. Always release the lease after a
successful or abandoned rebuild:

```haskell
finishRebuild handle = releaseHistoryRetentionLease handle
```

Release is idempotent. If a process crashes, no worker is needed to expire its
lease: destructive work becomes available after the database-derived expiry.
With the maximum duration, an abandoned lease can delay deletion for at most
one hour from its last successful acquisition or renewal. The expired row
remains visible as operational evidence until pruning.

For atomic composition with application rebuild metadata, use
`acquireHistoryRetentionLeaseTx`, `renewHistoryRetentionLeaseTx`, and
`releaseHistoryRetentionLeaseTx` inside `runTransaction`. Transaction
combinators write durable evidence but do not emit process-local `KirokuEvent`
values; the Effectful wrappers emit them after commit.

## Inventory And Pruning

`historyRetentionLeaseInventory` returns a bounded, deterministic inventory.
Its `Active`, `Expired`, and `Released` states are derived with database time.
Limits must be between 1 and 1,000:

```haskell
listLeases =
  case mkHistoryRetentionInventoryLimit 100 of
    Left invalid -> error (show invalid)
    Right limit ->
      historyRetentionLeaseInventory (HistoryRetentionInventoryQuery limit)
```

`pruneHistoryRetentionLeases cutoff` deletes only expired or released rows
whose terminal timestamp is strictly older than `cutoff`. Pruning is optional
hygiene; it never changes whether a lease is active.

## One-Transaction Stream Repair

Lock and read the stream in the same caller-owned transaction:

```haskell
repairStream stream = runTransaction $ do
  locked <- lockStreamHistoryForReplayTx stream
  case locked of
    Left unavailable -> pure (Left unavailable)
    Right info -> do
      events <- readStreamForwardTx stream (StreamVersion 0) 256
      -- Validate info.deletedAt/info.truncateBefore, then update the repair
      -- target here. The guard remains held through this whole transaction.
      pure (Right (info, events))
```

The guard returns exact metadata for soft-deleted and logically truncated
streams so the caller can refuse incomplete history. It returns a typed error
for a missing stream or `$all`. While held, append, link, soft delete,
undelete, logical truncate, and any supported hard delete that would remove a
home or linked junction all wait.

`readStreamForwardTx` uses the production exclusive-lower cursor and ascending
ordering, but it deliberately does not run `ConnectionSettings.decodeHook`:
`Hasql.Transaction.Transaction` has no `IO`. Apply equivalent decoding after
the transaction if your application depends on that hook.

If one transaction deliberately combines both tools, acquire or renew the
lease first, then take the stream guard. This follows Kiroku's coordinator,
ascending-stream-row, junction/payload lock order.

## Ownership, Authorization, And Direct SQL

The owner attached to a lease prevents accidental renewal or release under the
wrong operational identity. It is not a secret and is not an authorization
boundary. PostgreSQL roles and grants remain the security boundary.

Supported `hardDeleteStream` returns
`HistoryRetentionActive stream conflict` while any lease is active. Direct
GUC-enabled `DELETE` or `TRUNCATE` of Kiroku data tables receives SQLSTATE
`KR001`. There is no ordinary bypass: release the active leases or wait for
expiry. Disabling retention triggers as a PostgreSQL superuser is outside the
application guarantee and belongs only in a coordinated emergency maintenance
window after lease owners and destructive callers have been stopped.

See [Production Deployment](../PRODUCTION-DEPLOYMENT.md) for grants,
monitoring, and emergency-maintenance guidance.
