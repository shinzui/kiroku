## 0.13.0.0 — 2026-10-28

### Breaking Changes

- The closed `Store` effect gains `GetStoreIdentity`, `LookupEventReferences`,
  `PreviewCompaction`, `ApplyCompaction` and `GetCompactionLedger`; exhaustive
  custom interpreters must add arms.
- `StoreError` gains retryable `CompactionConcurrentMutation`. An affected apply
  transaction rolled back; preview again before retrying. Direct transaction
  composers can also receive existing `UnexpectedServerError` SQLSTATE `23503`
  for a concurrent foreign-key reference and must treat it identically.
- Exhaustive `KirokuEvent` observers must handle `KirokuEventCompactionPreviewed`,
  `KirokuEventCompactionRefused`, `KirokuEventCompactionApplied` and
  `KirokuEventCompactionAlreadyApplied`.

### New Features

- Add `Kiroku.Store.Compaction`, `.Types` and `.SQL`: immutable digest-sealed
  manifests, explicit reference policies, typed refusals, canonical SHA-256
  encodings, deterministic reports and durable ledger records. JSON decoding
  verifies manifest and report digests.
- Add read-only `previewCompaction` / `previewCompactionTx`. The effect uses one
  pooled connection and one repeatable-read snapshot without row locks or writes.
- Add atomic `applyCompaction` / `applyCompactionTx`: revalidate exact witnesses
  under the retention coordinator then ascending stream-ID locks, refuse active
  replay-history leases, and delete only selected events and acknowledged links.
  Retained envelopes, versions, positions and stream heads stay unchanged; ordinary
  append/read SQL and triggers gain no work. Causation refusal is validation-time
  best-effort. Reference/count races roll back the whole transaction.
- Add `compactionLedger` / `compactionLedgerTx`. The append-only record commits
  with deletion; an identical reapply returns that original record. Keep the
  reviewed manifest and archived envelopes because the ledger omits event IDs.
- Add `StoreIdentity`, `storeIdentity` and `storeIdentityTx`. Restored clones share
  their source identity. These APIs and compaction require migration `0017` from
  `kiroku-store-migrations` 0.7.3.0; older schemas report a missing relation.
- Add `lookupEventReferences` / `lookupEventReferencesTx`: home/global/link
  memberships, dead-letter counts and causation dependents outside the requested
  set. Unknown IDs are omitted, duplicates deduplicated and empty input uses no
  connection. Membership and dead-letter reads batch at 10,000 IDs on one checkout;
  causation exclusions cover the complete request.
- Document the reviewed workflow, lease margins, 10k initial operational chunks,
  audit and separate PostgreSQL space reclamation in the
  [operator guide](https://github.com/shinzui/kiroku/blob/master/docs/user/compaction.md).
