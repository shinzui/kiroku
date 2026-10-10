# Shared browse/prefix access research

This is a concrete alternative under review, not a production migration or a
transfer of the prior layout's write-cost acceptance. The user approved continuing
after the corrected observer cost report. The remaining product choice is whether
the new browsing API should use stable UTF-8 byte order or database locale order.
The byte-order choice is pending; no existing API, collation or index is changed.

## One browse index, no separate subscription prefix index

The proposed byte-order layout keeps the current unique-name constraint and the
small category index, and adds one partial index:

```sql
CREATE INDEX ix_streams_browse_name
ON kiroku.streams (stream_name COLLATE "C") WHERE stream_id <> 0;
```

It does **not** also install the benchmarked `(category, stream_name)` replacement.
This one browse index serves global names, literal prefixes, exact categories and
category-plus-prefix queries. Category enumeration retains its current index.
The uniqueness constraint, append lookups, error constraint identity, database
collation and existing category/event subscription indexes remain intact.

An exact category is the disjoint union of its bare name and names beginning with
`category + '-'`. Intersect these ranges with a requested literal prefix before
building the statement. A prefix's exclusive upper bound increments the last
incrementable Unicode scalar and truncates the suffix; skip the surrogate range.
An empty prefix or a prefix consisting entirely of maximum scalars has no finite
upper bound. Cursor comparisons and ORDER BY use the same explicit C collation.
This preserves `%` and `_` literally and includes bare names, empty categories,
Unicode and the valid `$all-x` application stream. Only stream id 0 is excluded.
Categories containing a hyphen cannot be produced by `split_part` and return empty.

The final query first takes an ordered, lower-bounded name page, then applies the
exclusive upper bound outside that LIMIT. Each category branch has its own LIMIT
before the small merge. This matters: putting both range ends inside the generic
prepared statement made the planner bitmap-scan and sort 1,005 rows at the smaller
fixture, despite the correct index. The bounded inner query examines at most one
page even for an absent prefix. In byte order all matching names precede the upper
bound, so filtering beyond that bound cannot hide later matches. It therefore
preserves ordinary short-page/exhaustion semantics; there are no empty continuation
pages through unrelated names. Production limits must be parameters and over-fetch
must be validated separately; this local diagnostic fixes LIMIT 11.

PostgreSQL documents that one index column supports one collation, and that normal
inequality operators cannot use `text_pattern_ops`. Merely changing operator class
does not preserve locale ORDER BY while also making arbitrary literal prefixes
contiguous. See [index collations](https://www.postgresql.org/docs/18/indexes-collations.html)
and [operator classes](https://www.postgresql.org/docs/18/indexes-opclass.html).
The proposed new API order is explicit; it never changes the deployment's collation.

## Plan 54 uses the existing global index

The current schema already carries originating category on global `stream_events`
rows (migration 0012). A namespace query can take at most 32 visible global entries
after an exclusive scan cursor using `ux_stream_events_stream_version`, then filter
that bounded materialized window by exact category or literal `namespace + ':'`.
Apply the captured upper head after the bounded scan to avoid the same generic-plan
bitmap/sort problem. Match consumer-group membership with the existing SQL rule:

```sql
(((hashtextextended(original_stream_id::text, 0) % size) + size) % size) = member
```

There is no `streams` join, no per-family stream probe and no added namespace index.
Catch-up necessarily inspects global history under this strategy, including unrelated
events; each fetch has bounded work. It trades sparse-family catch-up throughput for
bounded live work and no additional writer index. This is a distinct work bound from
IR-1's captured-head replay contract and does not implement that request.

The diagnostic returns matches, inspected count and last inspected global position,
including empty matching windows. The worker must keep inspection progress separate
from last delivered position, and continue across an empty matching window until the
captured frontier is exhausted. It may persist the inspected frontier only after all
matching events in that window resolve successfully. Stop, Retry, decode failure,
reconnect, hard-deletion gaps and concurrent appends need worker correctness tests.
A vector-only empty result must not mean caught-up. None of those worker changes is
implemented or accepted by this SQL research. Existing subscriptions stay unchanged.

## Evidence and reproduction

The bounded owned-cluster harness applies all current migrations to disposable
PostgreSQL 18.6 C and English ICU databases. Both generic and custom plans are
tested at 1K/20K streams per category and 1K/20K global event positions.
The final catalog uses the same deterministic UUIDv7 TypeID generator as the
earlier replacement research; preceding runs used short numeric suffixes. The unchanged
diagnostic budget is 64 examined rows and 64 buffers per case, with a five-minute
whole-run deadline, ten-second statement timeout and verified shutdown.

```bash
python3 scripts/mp13-browse-sql-prototype.py --scope shared-name-index \
  --output /tmp/mp13-shared-access-reproduction.json
```

The final run is `mp13-shared-access-typeid-20261010.json.gz`; inspect its
`correct_results`, `within_budget` and namespace scan-progress fields. All 224
cases pass: 176 browse cases (at most 12 examined rows / 12 buffers) and 48
namespace windows (at most 38 examined rows / 9 buffers). The final run took
22.92 seconds including setup and shutdown. The preceding complete short-name
run also passed all 224 cases; the TypeID check addresses name-length and seek
fixture coverage, not additional timed samples. Retained
earlier evidence includes the name-only and full-row generic-plan failures, the
bounded name success, a namespace fixture error (missing source-id text cast),
the namespace generic-plan failures, the corrected bounded namespace run,
and the final invalid-category and TypeID fixture checks.
All owned clusters stopped. These are EXPLAIN/correctness diagnostics, not timed
append trials or a statistically pooled sample. Script hashes and exact SQL are
inside each artifact; `sha256.json` covers the retained compressed bytes.

## Cost and next implementation gate

The prior replacement benchmark's throughput/WAL bounds apply to its exact layout,
not this alternative. This proposal keeps the category-only index instead of
replacing it and indexes only names for browsing. Read its retained size definitions
for footprint; do not infer write latency from size. In the final incremental
40,021-row catalog, the original three indexes total 4,554,752 bytes and the added
byte-name index is 3,334,144 bytes: total index bytes grow 73.2%. This fixture has
additional edge-case rows, and does not compare steady-state bloat or timed costs. If selected, the final shared
schema must receive one focused original-control comparison including fresh inserts
and existing writes with active readers, not an independent allowance per feature.
The prior failed browse prototypes and all valid append evidence remain retained.

Locale order would require a different reviewed prefix strategy; this byte-order
prototype cannot be installed as its implementation. No architecture is selected
while the order choice is pending, and ADR-15 already governs shared cost review.
