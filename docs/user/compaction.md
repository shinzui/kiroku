# Selective event compaction

Selective compaction physically deletes a reviewed set of originated events while
keeping their streams live. Kiroku never decides that an event is redundant:
the consumer proves that, archives its envelopes, and supplies an immutable,
digest-sealed manifest. Apply revalidates every witness before its first delete.
Retained envelopes, IDs, memberships, versions and positions stay unchanged.

| Operation | History visible to reads | Physical deletion | Reversible |
|---|---|---|---|
| Logical `setStreamTruncateBefore` | Hides older per-stream rows; `$all` stays complete | None | Yes |
| Whole-stream `hardDeleteStream` | Removes the stream and its originated events everywhere | Whole-stream scope | No |
| Selective compaction | Skips only selected events and explicitly acknowledged links | Manifest scope | No |

If version 207 is compacted from a stream headed at 412, reads return 206 then
208; version 208 keeps its number. The head stays 412, and an expected-version
append from 412 produces 413. Exclusive cursors, category and `$all` reads, and
subscription checkpoints continue across physical gaps. This capability requires
migration `0017` before runtime use.

## Build, review, rehearse and apply

Read `storeIdentity` and call `lookupEventReferences` with the candidate event IDs.
Each inventory gives the home stream/name/version, global position, every linked
membership, dead-letter count and causation dependents outside the complete
requested set. Unknown IDs are omitted. Empty input checks out no connection;
large input is batched internally without changing whole-request causation
exclusions. Treat inventory as advisory under concurrent mutation: preview is the
stable-snapshot check and apply is authoritative.

The consumer builds `CompactionSelection` values from its reviewed archive and
these witnesses. Acknowledge only links whose removal was also reviewed. Supply
one `StreamHeadWitness` for every origin and acknowledged-link target; no unused
or duplicate head is allowed. `getStream` supplies the head version. Use
`RefuseDeadLetters` and `RefuseCausationDependents` unless the review explicitly
accepts removal of dead letters or dangling causation. Those policies are sealed
inside the manifest, rather than flags applied after review.

```haskell
-- The host already owns store, reviewedSelections and reviewedHeads.
Right identity <- runStoreIO store storeIdentity
let Right operation = mkCompactionOperation "archive://campaign-42/manifest-1"
    input = CompactionManifestInput identity operation
              RefuseDeadLetters RefuseCausationDependents
              reviewedHeads reviewedSelections Nothing
case mkCompactionManifest input of
  Left invalid -> print invalid
  Right manifest -> do
    preview <- runStoreIO store (previewCompaction manifest)
    print preview
    -- Archive the manifest JSON and review both digests before authorizing apply.
```

`mkCompactionManifest` validates input, canonicalizes ordering and computes the
manifest digest. JSON decoding requires that digest and verifies it. Preview
returns either all determinable typed refusals, `CompactionPreviewReady report`,
or `CompactionPreviewAlreadyApplied record`. It takes one read-only repeatable-read
snapshot and no row locks. Review the manifest and report digests, rehearse the
same manifest against a restored clone, then preview production and apply through
the authorized host. A clone shares its source identity by design.

```haskell
result <- runStoreIO store (applyCompaction manifest)
let Right limit = mkCompactionLedgerLimit 50
ledger <- runStoreIO store (compactionLedger (CompactionLedgerQuery limit))
```

A refusal changes no rows. A successful apply returns `CompactionAppliedNow` with
its durable record. Reapply returns `CompactionAlreadyApplied` with the identical
record; preview also recognizes it. A recorded digest whose selected IDs survive
refuses as `CompactionLedgerConflict`, requiring investigation of restores or ID
reuse. Row absence alone never establishes that a manifest was applied.

## Embeddable commands

These commands run in a host that owns a `KirokuStore` and embeds
`kirokuSubparser`. The standalone remote client refuses them; there is no HTTP
apply endpoint. The host supplies authorization and its database connection.

```bash
host kiroku store identity --format json
host kiroku compaction preview --manifest manifest.json
host kiroku compaction apply --manifest manifest.json --confirm-digest REVIEWED_SHA256
host kiroku compaction ledger --limit 50 --format json
```

Apply requires `--confirm-digest` equal to the file's manifest digest, checked
before a database call. Exit 0 means success or already applied, 2 means refusal
(including confirmation mismatch), and 1 means a file, usage or store failure.
JSON output is one JSON document, including refusals and failures. Hosts can use
`executeKirokuCommandWithStore` to receive text and an `ExitCode` without printing
or exiting. See [operator-cli.md](operator-cli.md).

## Manifest document and canonical encoding

This fixed, digest-verified example is also the public encoding test vector.
Construct live documents with the library rather than editing a digest by hand.

```json
{
  "format": "kiroku-compaction-manifest/1",
  "store_identity": "00000000-0000-7000-8000-000000000001",
  "operation": "compact",
  "dead_letter_policy": "refuse",
  "causation_policy": "refuse",
  "stream_heads": [{"stream": "orders-1", "head_version": 7}],
  "selections": [{
    "event_id": "00000000-0000-7000-8000-0000000000aa",
    "origin_stream": "orders-1",
    "origin_version": 3,
    "global_position": 42,
    "acknowledged_links": []
  }],
  "digest": "965e364734a98abdc509ceb0b4f082ab7a2dbd66713d56ce77d2071e55589d08"
}
```

`format` and `digest` are required. The root digest is SHA-256 over the following
binary concatenation, independent of JSON key order or whitespace. Integers are
big-endian; text is a four-byte unsigned UTF-8 byte length followed by those bytes;
UUIDs occupy 16 raw network-order bytes. A counted vector starts with a four-byte
unsigned element count.

1. ASCII `kiroku-compaction-manifest/1` and LF.
2. Store UUID, length-prefixed operation, one dead-letter policy byte and one
   causation policy byte (`0` refuses; `1` removes/allows).
3. Counted stream heads, sorted by UTF-8 stream-name bytes: name then signed
   eight-byte head version.
4. Counted selections, sorted by global position: event UUID, origin name,
   signed eight-byte origin version and global position, then counted links.
   Links sort by name bytes then version and encode name plus signed eight-byte
   version.

The report digest uses prefix `kiroku-compaction-report/1` and LF, the 32 raw
manifest-digest bytes, store UUID, operation and policy bytes as above, then eight
signed eight-byte values in this order: selected events, home memberships, global
memberships, link memberships, dead letters removed, causation dependents, lowest
global position, highest global position. Counted affected stream heads follow.
The report's own digest is excluded. See the [codec source](../../kiroku-store/src/Kiroku/Store/Compaction/Types.hs)
and [golden/property tests](../../kiroku-store/test/Test/CompactionManifest.hs).

## Refusals and recovery

| Refusal | Meaning and action |
|---|---|
| `CompactionStoreIdentityMismatch` | The destination identity differs; select the reviewed store or rebuild the manifest. |
| `CompactionHistoryRetentionActive` | A lease protects history; wait for its release/expiry and preview again. |
| `CompactionStreamMissing` | A named stream no longer exists; review topology and rebuild witnesses. |
| `CompactionStreamSoftDeleted` | A touched stream is soft-deleted; resolve its lifecycle intentionally. |
| `CompactionStreamHeadDrift` | An append or link advanced a head; re-review and capture current witnesses. |
| `CompactionSelectedEventMissing` | An unrecorded selection is absent; investigate rather than widening deletion. |
| `CompactionWitnessMismatch` | Origin/version/global membership differs; rebuild from verified inventory. |
| `CompactionUnexpectedLink` | A live link was not acknowledged; review that membership explicitly. |
| `CompactionAcknowledgedLinkMissing` | A reviewed link witness is absent or differs; refresh the review. |
| `CompactionDeadLettersPresent` | Dead letters would dangle; retain the event or explicitly review `RemoveDeadLetters`. |
| `CompactionCausationDependentsPresent` | Other retained events refer to this event; retain it or review `AllowDanglingCausation`. |
| `CompactionLedgerConflict` | The digest is recorded but selected IDs survive; investigate inconsistent restoration or reuse. |

Causation refusal is validation-time best-effort. Causation IDs have no foreign
key and apply locks no unlisted stream, so a dependent appended elsewhere after
validation is not detected. A concurrent link or dead letter instead aborts the
whole apply through count checks or foreign keys. The effect surfaces retryable
`CompactionConcurrentMutation`: nothing committed; preview again before retrying.
A direct `applyCompactionTx` composer may receive `UnexpectedServerError "23503"`
for the foreign-key race and must treat it identically.

## Leases, locks and chunk sizing

Apply checks identity before locking, then takes the history-retention coordinator.
Any active lease refuses. Ledgered no-ops return before stream locks. New work locks
every affected stream in ascending internal ID order and reruns the shared preview
validator before deletion. Held `lockStreamHistoryForReplayTx` guards block apply;
appends to locked streams wait, then continue from the unchanged head. Composers
must perform lease work before stream guards. See [history-retention.md](history-retention.md).

The coordinator stays held throughout apply, delaying lease administration too.
A renewal issued with little lifetime remaining can expire while queued. Keep
measured chunk duration well inside the renewal margin. Operators who prefer a
bounded wait can set a maintenance-role/session `lock_timeout`; a timeout aborts
the transaction rather than leaving partial deletion.

A manifest has at most 100,000 selections. Start at 10,000 and chunk by stream so
each lock set stays small. Acknowledged-link fan-out can add many target streams;
the selection ceiling does not bound stream count or ledger JSON size. Disjoint
chunks can reuse the same head witnesses because compaction does not advance
heads; an intervening append/link deliberately invalidates them.

The [local sizing probe](../bench/compaction/2026-10-27/README.md) measured 0.21s,
1.18s and 2.35s for 10k, 50k and 100k selections with 10% links and dead letters.
These single observations conservatively bound coordinator hold on that fixture;
they are not a production latency guarantee. Measure the deployment's payloads,
fan-out and storage before increasing operational chunks.

## Storage, WAL and consumer consequences

Deletion leaves dead tuple versions, including associated payload storage.
Autovacuum or ordinary `VACUUM` makes space reusable within relation files; it
does not generally shrink those files. After a campaign run explicit
`VACUUM (ANALYZE)` on `kiroku.stream_events` and `kiroku.events`, and on
`kiroku.dead_letters` when removing many letters. A campaign may remain below
an installation's autovacuum trigger thresholds. Returning substantial heap file
space to the OS requires a rewrite such as `VACUUM FULL`, or a separately managed
repacking operation; `VACUUM FULL` takes an exclusive lock. These are PostgreSQL
maintenance operations, not part of Kiroku apply. [PostgreSQL vacuuming guide](https://www.postgresql.org/docs/18/routine-vacuuming.html).

Assess B-tree bloat in `stream_events_pkey`, `ux_stream_events_stream_version`
and `ix_stream_events_all_by_origin`. Vacuum can remove dead index entries and
allow reuse, but rebuilding with `REINDEX CONCURRENTLY` can reduce space occupied
by sparsely populated pages. Schedule and monitor it separately; it has its own
resource and concurrency constraints. [PostgreSQL REINDEX](https://www.postgresql.org/docs/18/sql-reindex.html).

Scattered deletes can produce substantial WAL, including full-page images for
pages first modified after a checkpoint when full-page writes are enabled. Large
campaigns may emit hundreds of megabytes, depending on layout and settings;
watch replication lag and space between chunks. [PostgreSQL WAL settings](https://www.postgresql.org/docs/18/runtime-config-wal.html).

Compacted IDs become appendable again, losing `DuplicateEvent` retry protection
for exactly those IDs. A subscription trying to dead-letter an already-compacted
event gets the existing `dead_letters.event_id` foreign-key failure behavior.
Removing the newest `$all` rows can decrease `visibleGlobalHeadPosition`; the
global append frontier and stream heads never move backward. Consumers that bound
replay by the visible head must tolerate that distinction.

## Authorization and audit

Use a separately authorized host/maintenance role. It needs `SELECT` on the
identity, ledger, streams, memberships, events, dead letters and lease inventory;
`UPDATE` on the coordinator and locked streams; `DELETE` on memberships and events;
`INSERT` on the ledger; and `DELETE` on dead letters only for `RemoveDeadLetters`.
Apply enables `kiroku.enable_hard_deletes` locally. That setting prevents accidents;
PostgreSQL privileges are the authorization boundary. See
[production privileges](../PRODUCTION-DEPLOYMENT.md).

The append-only ledger is durable evidence, listed newest first. It records counts,
policies, operation/archive locator, stream heads and digests, not the selected
IDs or removed envelopes. Keep the manifest and archive to answer which events a
compaction removed. Store readers preserve the stored report digest verbatim so
an audit can compare `compactionReportDigest` with it.

`KirokuEventCompactionPreviewed`, `KirokuEventCompactionRefused`,
`KirokuEventCompactionApplied` and `KirokuEventCompactionAlreadyApplied` are
process-local signals emitted after transaction completion; payload data is
excluded. Refusals carry the first finding and total count. See
[observability.md](observability.md) and
[ADR-22](../adr/0022-physical-event-compaction-is-manifest-driven-witness-validated-and-ledgered.md).
