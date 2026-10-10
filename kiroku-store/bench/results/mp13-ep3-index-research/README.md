# EP-3 shared index and benchmark research

This is research, not a migration or append-cost acceptance. The candidate replaces
`ix_streams_category(category)` with a default-opclass B-tree on
`(category, stream_name)`. The replacement was made only in disposable databases.
No production schema, API, benchmark payload or remote cell was changed.

The candidate gives category equality a name-ordered seek, including a mandatory
name cursor. Its ordinary text operator classes also support the category ordering
used by category enumeration. It has not proved global literal-prefix access or
plan 54's namespace subscription design; those remain in the shared review.

## Local footprint and read evidence

PostgreSQL 18.6, C and English ICU databases, generic and custom prepared plans;
page limit 11, unchanged budget 64 examined rows / 64 buffers. Fixtures have
1,000 then 20,000 deterministic UUIDv7 TypeID stream names in each of two
categories, plus bare names, punctuation and Unicode. Both compared category
indexes are freshly built at each size, so this is a compact initial footprint,
not a measurement of steady-state bloat. Other stream indexes are unchanged.

| Fixture | Category-only index | Category/name index | Added bytes |
| --- | ---: | ---: | ---: |
| 2,007 stream rows | 32 KiB | 152 KiB | 120 KiB |
| 40,007 stream rows | 288 KiB | 2,672 KiB | 2,384 KiB |

Both collations gave these sizes. At 40,007 rows, the replacement is 9.28 times
the category-only index, and total stream-index bytes grow by 53.7%. These are
fixture sizes, not a write-latency percentage or a production capacity forecast.
Repeated category keys can share B-tree posting lists; unique stream names remove
that opportunity between different streams. Version churn can still repeat the
same composite key. See PostgreSQL's [B-tree deduplication documentation](https://www.postgresql.org/docs/18/btree.html).

All 96 cases returned the independent reference results. All 48 replacement
cases met the read budget, with at most 12 examined rows and 12 buffers. They
cover first, absent-category, late-cursor and Unicode-cursor stream pages, plus
first/after-cursor category enumeration. The control met the budget in 36 of 48
cases; worst cases examined 40,007 rows / 1,490 buffers. This supports further
evaluation of category browsing, not promotion of the complete browse API.
Optional literal-prefix filtering within a category was not tested in this scope.

Retained losslessly compressed evidence:

- `2026-10-10-setup-error.json.gz`: a LIMIT parameter type error before any
  EXPLAIN case; the owned cluster stopped. Corrected the six-parameter binding.
- `2026-10-10-initial.json.gz`: 96 cases in 9.67 seconds, including setup/cleanup.
- `2026-10-10-formatting.json.gz`: 96 cases in 11.57 seconds after documentation
  and indentation cleanup; query shapes unchanged.
- `2026-10-10-final.json.gz`: 96 cases in 10.10 seconds after whitespace cleanup,
  matching the committed script hash.
- `2026-10-10-prefix-regression.json.gz`: the pre-existing prefix gate remains
  rejected in 5.43 seconds; 152 cases and verified owned-server cleanup.

All retained runs verified owned-server shutdown. Each case is one EXPLAIN
execution, not a timed append trial. JSON retains exact SQL, results, plans,
layout sizes/definitions, migration hashes, script hashes and server logs.

```bash
python3 scripts/mp13-browse-sql-prototype.py --scope index-layout \
  --output /tmp/mp13-index-layout-reproduction.json
```

Exit 0 / `index_layout_research_complete` means research completed. Inspect
`candidate_read_cases_pass` separately; no status here accepts append cost.
The five-minute deadline, ten-second query timeout and refusal to overwrite
evidence remain in force.

## What the existing benchmark evidence establishes

Read sources from `mori://shinzui/keiro-runtime-kenshou` at revision
`7a451b5f5f4b51986e872879a3bfe10f5943af6b`. The following paths are relative
to that canonical project; artifact-level URIs are pending. Source hashes and
the inspected local run inventory are in `kenshou-inventory.json`.

| Project-relative source | Useful coverage | Gap for this index |
| --- | --- | --- |
| `kenshou-kiroku/src/Kenshou/Suite/Kiroku/Bench/Append.hs` | Append capacity, hot-stream contention, latency/WAL | Reuses streams; initial creation is largely in warmup |
| `kenshou-kiroku/src/Kenshou/Suite/Kiroku/Bench/Subscription.hs` | Category/all catch-up, append-to-handler latency, fan-out | Catch-up has one source stream; not large catalog browsing |
| `kenshou-kiroku/src/Kenshou/Suite/Kiroku/Bench/Read.hs` | Event-page reads over stream/all/category targets | Not stream catalog pagination; small stream inventory |
| `kenshou-kiroku/src/Kenshou/Suite/Kiroku/Bench/Hardening.hs` | Declares fresh/existing and live subscriber scenarios | Runner intentionally requires the dedicated matched MP12 payload |
| `kenshou-measure/src/Kenshou/Measure/Sampler/Postgres.hs` | Relation sizes, updates, statement execution/WAL | Relation CSV lacks HOT counts; caller must select watched relations |
| `docs/guides/measuring-and-comparing.md` | Matched, interleaved comparisons and verified artifacts | Does not turn local macOS results into authoritative cell evidence |

The scoped inventory covers 63 local `runs/*/run-result.json` files with Kiroku
benchmark scenarios: 40 passed, 10 inconclusive, 9 failed, 4 infrastructure
failures. All declare non-authoritative methodology and Kiroku store 0.8.0.1.
Forty-six have measurement grade `benchmark`, which does not override methodology
placement/durability. This is not an inventory of every remote run. These records
predate the current category-event index and cannot measure this candidate's cost.

The reusable dedicated payload is this repository's
[MP12 harness](../../../../bench/mp12-cell/README.md), particularly
`bench/mp12-cell/src/Workload.hs`. It already exercises fresh and existing streams,
native category/group subscribers and the acknowledgement-coupled adapter, with
WAL, full intended-arrival latencies, exact delivery and durable drain checks.
Its current historical control is for MP12 hardening; reuse the workload and
controller, not that control, for an index-only comparison.

Current subscriptions call `readCategoryForwardStmt` and its consumer-group form
in `kiroku-store/src/Kiroku/Store/SQL.hs`, using the separate partial
`stream_events(category, stream_version) INCLUDE(original_stream_id)` index from
migration 0012. They do not join `streams`. Its exact definitions are unchanged in
the local evidence. Replacement therefore does not change their access path;
increased cache/WAL/write contention is still a regression risk to measure.

Every append updates the application stream and `$all`. HOT avoids new index
entries only when indexed values are unchanged and the page has space; fillfactor
50 helps but is not a guarantee. New streams insert index entries, and non-HOT
version updates can maintain the larger index. See PostgreSQL's
[HOT documentation](https://www.postgresql.org/docs/18/storage-hot.html).
The payload currently watches `subscriptions` and `stream_events`, and reports
subscription HOT updates. Those are not measurements of stream-row HOT behavior.

## Smallest useful next comparison

Prepare a matched payload with the same current source, compiler, migrations,
pool, durability and fixture in both arms; vary only the recorded index layout.
Do not attribute differences from a historical released binary to this index.

1. Record a layout knob, exact applied DDL and resulting definitions after
   migrations and before fixtures/warmup. The comparator supports `knob:<name>`
   as a declared varying axis; this candidate knob is not implemented yet.
2. Add `streams` relation snapshots and HOT/update deltas, with clearly recorded
   statistics boundaries; retain index bytes, append-statement WAL, total WAL,
   throughput and p50/p95/p99. Reuse existing drain, delivery and artifact checks.
3. Use identical deterministic TypeID-length names in both arms and a realistic
   pre-existing category inventory. Existing MP12 names are shorter `probe-*`
   strings. Include both fresh-stream inserts and existing-stream version updates.
4. Start with fresh-stream append cost, then existing-stream appends under one
   category subscription and category browsing. Reuse the same original control
   for later combined plan 54/inspection costs. Add group/adapter coverage only
   if a changed path or adverse result needs it; do not launch the old full matrix.
5. Before any remote queue, establish comparison policy and report selected
   cases/pairs, all phase durations, calibration, setup/reset and recovery time,
   uncertainty target and stop conditions within one 60-minute wall-clock budget.
   Existing phases alone are 30/61/30 seconds per trial. Two cases with five
   pairs each take 40.3 minutes before calibration, build, setup, reset and
   verification; five additional calibration pairs bring phases alone to 60.5
   minutes. That combination does not fit. Choose a smaller useful experiment
   explicitly or leave acceptance inconclusive; do not silently relax a gate.

No remote submission, active execution or lease exists for this research. The
candidate's event-append cost remains unmeasured. General prefix correctness and
plan 54's global-event ordering still need design evidence before a migration
can be selected. ADR-15 already governs shared access and cumulative cost; this
research adopts no new durable architecture.
