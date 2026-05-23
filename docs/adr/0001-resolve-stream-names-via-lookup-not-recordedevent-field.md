# ADR-0001: Resolve stream names via an on-demand lookup API, not a `RecordedEvent` field

- **Status:** Accepted — 2026-05-22
- **Related:** ExecPlan `docs/plans/36-add-originalstreamname-to-recordedevent.md`;
  commit `743a573` (shipped) reverting `8a2bc87`/`859cd5a` (explored).

## Context

A `RecordedEvent` returned by a read carries only the surrogate
`originalStreamId :: StreamId` (a `BIGINT`), not the human-readable
`StreamName`. For single-stream reads the caller already knows the name. But for
*fan-in* reads — the global `$all` stream, category reads,
causation/correlation queries, and subscriptions — events come from many
streams, and Kiroku had no public way to turn `originalStreamId` back into a
name (the only lookups, `lookupStreamId`/`getStream`, go name → id). Consumers
were forced into raw SQL against the internal `streams` table.

The obvious fix is to add an `originalStreamName` field to `RecordedEvent` so
every read returns the name. The question was whether the convenience is worth
its cost on the read hot path (subscriptions drive most reads), against the
repo's standing **10% read-regression gate**.

## Decision

Do **not** add a stream-name field to `RecordedEvent`. Instead provide an
on-demand resolver in `Kiroku.Store.Read`:

```haskell
lookupStreamNames :: [StreamId] -> Eff es (Map StreamId StreamName)  -- batch, one round trip
lookupStreamName  :: StreamId   -> Eff es (Maybe StreamName)         -- singular convenience
```

These are the inverse of `lookupStreamId`. A consumer collects the distinct
`originalStreamId`s from a read batch and resolves them once. `RecordedEvent`
keeps carrying `originalStreamId`; its Haddock points at `lookupStreamNames`.

## Consequences

**Positive**

- The read hot path is unchanged — byte-identical SQL to before — so there is
  no regression by construction, not merely by measurement.
- Consumers pay only when, and only as much as, they need names: one round trip
  per batch for the distinct ids (typically far fewer than the batch size).
- No schema change, migration, or extra per-row storage.

**Negative**

- Recovering names is an explicit extra call, not automatic — slightly less
  ergonomic than a field. Consumers that want names per event must thread the
  resolved `Map` through their handler.
- A second round trip exists for the (common) subscription case that wants
  names; it is amortized across the whole batch rather than per event.

## Alternatives Considered

Both were fully implemented and benchmarked (same-machine A/B, `tasty-bench`,
100-event pages over a 100K-event fixture) before being rejected.

1. **Field sourced by a read-time `JOIN streams`.** Measured **~+12%** on `$all`
   and **~+9%** on single-stream reads; category reads (which already join
   `streams`) were flat — the control. Exceeds the 10% gate on the subscription
   hot path.

2. **Field sourced by a denormalized `stream_events.original_stream_name`
   column** (written at append/link time, read with no join). Hypothesis: the
   join was the cost. It was not — a back-to-back *no-field vs. denormalized* A/B
   still showed **~+13%** on `$all`:

   | `$all forward` (100-event page) | mean |
   | --- | --- |
   | no field (11-column rows) | ~955–988 µs |
   | field via join | ~1.08–1.14 ms |
   | field denormalized | ~1.09–1.12 ms |

   The join and denormalized variants are statistically identical. The cost is
   **decoding/transferring the extra `text` column on every read row** (~100
   values per page) plus wider heap tuples — inherent to *any*
   field-on-every-read design, so denormalization bought no read improvement
   while adding a migration, write cost, and storage. (The append path was
   confirmed flat: writing a value already held as a query parameter is free.)

The decisive insight was the **control experiment** (no-field vs. denormalized,
not just join vs. denormalized), which isolated the cost to the column itself
and showed no field could meet the gate.

A prior project lesson — "round-trip count dominates, SQL shape does not" — was
found to be **append-path-specific**: for reads, extra result columns and
per-row server work over a 100-row page are measurable (~13%).
