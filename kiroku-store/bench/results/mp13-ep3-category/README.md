# EP-3 category-scoped stream browsing experiment

User-directed scope: evaluate streams within a chosen category using the existing
indexes first. Arbitrary prefix search remains a valid UI requirement; this
experiment does not remove it or redefine a category filter as a prefix filter.
No new index, migration, collation or production API was added.

The local PostgreSQL 18.6 run applied the current fourteen migration SQL files
to disposable C and English ICU databases. It took 15.97 seconds including
setup, migrations, 192 EXPLAIN cases, result checks and verified server cleanup.
It was a structural diagnostic, with one execution per case and no timing
precision target. No remote or append workload was run.

Three fixtures distinguish unrelated inventory from selected-category size:
1,001 `orders` streams plus 1,000 noise streams; the same selected category plus
20,000 noise streams; then 20,001 `orders` streams plus 20,000 noise streams.
Each category includes the dash-less stream named `orders`, to preserve the
distinction between category equality and the literal `orders-` prefix.

The direct query applies category equality and the exclusive name cursor, then
orders and limits. The materialized variant applies those filters inside a CTE
(a saved intermediate result) before ordering and limiting. Neither variant
forces an index or disables sequential scans. Both forced generic and custom
prepared plans were evaluated. Cases cover first pages, late/end cursors,
missing categories, broad `ord`, sparse `orders-00099`, absent prefixes and
combined prefix/cursor predicates. Result membership, ordering and exclusive
cursors matched the reference queries in all 192 cases.

| Case, forced generic plan | Direct rows / buffers | Materialized rows / buffers |
| --- | --- | --- |
| First orders page: 1,001 orders + 1K noise | 1,012 / 29 | 1,001 / 27 |
| First orders page: 1,001 orders + 20K noise | 20,012 / 557 | 1,001 / 27 |
| First orders page: 20,001 orders + 20K noise | 20,012 / 557 | 20,001 / 439 |
| Missing category: 20,001 orders + 20K noise | 40,002 / 1,051 | 0 / 5 |
| Last ten orders: 20,001 orders + 20K noise | 10 / 3 | 20,001 / 439 |
| Absent prefix in orders: 20,001 orders + 20K noise | 40,002 / 1,051 | 20,001 / 439 |

These counts agreed for both tested collations and planning modes. The raw JSON
retains every result, full plan, fixture SQL, query SQL, script and migration
hashes, current stream index definitions, buffers and cleanup result.

The user was correct that category equality can use `ix_streams_category`.
Materializing the selected category kept examined rows and buffers independent
of unrelated inventory in these fixtures. The direct LIMIT query sometimes
preferred the name index and filtered across unrelated streams instead.

The remaining problem is ordered pagination within the selected category.
`ix_streams_category` has no stream-name ordering; the category-first plan reads
the selected category before sorting. For eleven returned rows, work grew from
1,001 to 20,001 examined rows as category size grew. Prefix filtering still
scans the selected category. This does not pass the original bounded-work gate;
the unchanged diagnostic budgets are 64 examined rows and 64 execution buffers.
The inventory/category-size growth is evidence independently of those budgets.

The result is **category_streams_requires_design**, not production acceptance.
Category equality is useful for the primary UI workflow, but these query shapes
do not establish page-bounded work on existing indexes. Global arbitrary prefix
search also retains the earlier failed promotion result. EP-3 remains In Progress.

Reproduce with a new output path from the repository root:

```bash
python3 scripts/mp13-browse-sql-prototype.py --scope category-streams \
  --output /tmp/mp13-category-streams-reproduction.json
```

Expected exit is 2 with `category_streams_requires_design` and
`cluster_stopped: true`. The controller retains its five-minute total deadline,
ten-second query timeout, socket-only server and refusal to overwrite evidence.
