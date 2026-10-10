# EP-3 existing-name-index range experiment

User-directed scope: test range-based stream paging without adding an index. This
is local PostgreSQL 18.6 structural and correctness evidence, not an append-cost
measurement or production acceptance. No schema, collation or API was changed.

Two completed runs are retained as losslessly compressed JSON:

- `2026-10-10-initial.json.gz`: 224 cases, 23.48 seconds including setup and cleanup.
- `2026-10-10-refined.json.gz`: 400 cases, 39.24 seconds including setup and cleanup.

Both owned clusters were verified stopped. Each case has one EXPLAIN execution;
there is no timing precision claim. JSON includes exact fixture/query SQL, full
plans, returned and reference names, index definitions, database locale metadata,
migration/script hashes and server logs. The refined run matches the diagnostic source at commit
`6089675` (before the later index-layout research scope). The initial run retains the earlier statement shapes before
adding the computed category predicate and combined category/prefix cases.

The fixtures use `<category>-order_<uuidv7-base32>` names with deterministic,
increasing UUIDv7 timestamps. The generator verifies UUID version and variant;
these are specimens, not a production ID generator. Four stages cover 1K target
streams plus 1K noise; 1K target plus 20K noise; 20K target plus 20K noise; then
20K additional punctuation-neighbor names. Bare `orders`, empty suffixes, literal
`%`/`_`, Unicode, quotes and the valid `$all-x` stream preserve the store's broader
name contract. Both C and English ICU databases use generic and custom plans.

The range uses an inclusive prefix lower bound and a codepoint successor upper
bound, with the literal predicate retained. This upper bound is a candidate, not
a collation-independent guarantee. Category queries merge a bare-name point
lookup with a limited prefix-range branch. The refinement compares generated
`category = $1` against the equivalent `split_part(stream_name,'-',1) = $1` name
predicate, to distinguish category-index planning from name-index seeks.

| Neighbor fixture, generic plan | Rows examined / buffers | Result |
| --- | --- | --- |
| C or ICU category column, first page | 20,007 / 568 | Correct, over budget |
| C or ICU computed name predicate, first page | 11 / 8 | Correct |
| C or ICU category column, late cursor | 20,006 / 564 | Correct, over budget |
| C or ICU computed name predicate, late cursor | 11 / 6 | Correct |
| C or ICU computed name predicate, end cursor | 0 / 3 | Correct |
| C category plus literal `%` prefix, name predicate | 2 / 8 | Correct |
| ICU category plus literal `%` prefix, name predicate | 1 / 7 | Incorrect: matching name omitted |
| C global Unicode prefix | 1 / 4 | Correct |
| ICU global Unicode prefix | 0 / 3 | Incorrect: matching name omitted |

The refined run returned correct results in all 200 C cases and 168 of 200 ICU
cases. It met the unchanged 64-row/64-buffer diagnostic budget in 186 C and 155
ICU cases. Small-fixture plans also sometimes chose bitmap/sequence scans and
sorting: even C correctness is not a complete bounded-work promotion result.
Name ranges improve ordinary TypeID pages in these fixtures, but codepoint
bounds omit valid ICU matches. Fast incorrect results cannot pass.

The result is **range_streams_requires_design**. EP-3 remains In Progress and
production SQL is held. Do not restrict names to TypeIDs, force C collation or
relax the gate to ship this candidate. Any index proposal must be coordinated
with [plan 54](../../../../docs/plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md)
and reviewed for cumulative append cost. That write cost is still unmeasured:
appends update both the application stream and `$all`, new streams insert index
entries, and non-HOT version updates maintain indexes. Migration 0005 already
sets stream fillfactor 50; HOT eligibility does not prove all appends are HOT.

Reproduce from the repository root with a new output path:

```bash
python3 scripts/mp13-browse-sql-prototype.py --scope range-streams \
  --output /tmp/mp13-range-streams-reproduction.json
gzip -dc kiroku-store/bench/results/mp13-ep3-range/2026-10-10-refined.json.gz \
  > /tmp/mp13-range-streams-retained.json
```

Expected exit is 2, status `range_streams_requires_design`, and
`cluster_stopped: true`. The diagnostic retains a five-minute total deadline,
ten-second query timeout, socket-only server and refusal to overwrite evidence.
