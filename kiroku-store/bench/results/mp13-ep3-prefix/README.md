# EP-3 SQL promotion evidence

The stream-prefix correctness prototype is **rejected**, not shipped. Both runs
used local PostgreSQL 18.6 and the repository's fourteen migration SQL files,
unchanged, on owned disposable databases. Their migration hashes, exact prepared
queries, full EXPLAIN JSON, buffers, rows examined and server cleanup are retained.
There was no remote run, append workload, runtime latency gate or release acceptance.

The first run contains 80 prefix cases. The expanded run contains 152 cases and
adds late cursors and category enumeration to answer the remaining specific
cursor question. Both use 1,000 and 20,000 noise streams, two orders streams and
the reserved `$all` row; two collations (C and English ICU); and forced generic
and custom prepared plans. Queries request eleven rows, matching a ten-item page
with one over-fetch. The preregistered diagnostic budgets were 64 examined rows
and 64 execution buffers; inventory-proportional growth rejects the prototype
independently of these thresholds. Plans retain planning buffers separately.

| Query / case | Plan and collation | Examined rows, 1K / 20K | Execution buffers, 1K / 20K |
| --- | --- | --- | --- |
| Nullable stream cursor; absent prefix, first page | Generic, C and ICU | 1,003 / 20,003 | 26 / 496 |
| Mandatory stream cursor `noise-000500`; absent prefix | Generic, C and ICU | 502 / 19,502 | 15 / 485 |
| Nullable stream cursor; absent prefix, first page | Custom, ICU | 1,003 / 20,003 | 24 / 420 |
| Nullable category cursor after `orders` | Generic, ICU | 1,003 / 20,003 | 22 / 436 |
| Mandatory category cursor after `orders` | Generic, ICU | 0 / 0 | 1 / 2 |

The mandatory stream cursor is an `Index Cond`, but `starts_with` remains a
filter. Splitting first/later pages and trying `LIKE` do not bound absent-prefix
generic plans. Custom plans are cheap on C for these prefixes but still scan on
ICU; forcing custom planning cannot provide the required deployment-independent
fix. No new index, schema collation change or prefix-semantic change was made.

Category enumeration has a viable existing-index variant: separate first-page
and mandatory-cursor queries preserve the loose scan. This diagnoses category
query shape only; no library API or production statement has been added.

Reproduce from the repository root, using a **new** output path:

```bash
python3 scripts/mp13-browse-sql-prototype.py \
  --output /tmp/mp13-ep3-prefix-reproduction.json
```

The script requires PostgreSQL 18 binaries on PATH, has a five-minute overall
deadline and ten-second statement timeout, refuses to overwrite evidence, uses
Unix sockets with TCP disabled and stops its owned server on every exit. Expected
exit code is **2** with `status: rejected_prefix_prototype` and
`cluster_stopped: true`. The retained runs took 3.62 and 4.97 seconds including
setup, migrations, measurement and cleanup. This is structural evidence, so
there is no statistical uncertainty target or repeated timing trial.

EP-3 remains In Progress at Milestone 0. Before Milestone 1, revise and review the
prefix design explicitly against its no-migration constraint, unchanged literal
prefix semantics and database-collation ordering. An additional prefix index
would require a separate read/write design and append-cost review under ADR-15;
it is not authorized implicitly by this failed prototype.

PostgreSQL's [B-tree documentation](https://www.postgresql.org/docs/18/indexes-types.html)
and [operator-class documentation](https://www.postgresql.org/docs/18/indexes-opclass.html)
explain the locale-dependent pattern-index restriction. The measured plans,+rather than that documentation alone, determine this rejection.
