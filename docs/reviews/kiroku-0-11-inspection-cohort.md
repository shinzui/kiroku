---
type: Review
title: Kiroku 0.11.0.0 inspection cohort
description: The 0.10.0.0 to 0.11.0.0 cohort adds only index maintenance from migration 0015 to the append path, with a retained five-pair cell comparison bounding its throughput effect within a few percent and a paired gate proving metadata reads unchanged, its browse, dead-letter, stream-head and standalone surfaces are bounded and correct, but the kiroku-metrics changelog claims a WebSocket origin refusal that the default-off policy does not perform, the kiroku-store changelog omits a record-selector break, the release commit's docs still called the surface unreleased, and the performance ledger records none of the cohort's experiments.
generated:
  by: process:claude-code
  at: "2026-10-21T14:17:00Z"
reviewId: REV-3
subject: mori://shinzui/kiroku
subjectKind: project
reviewedSha: 7394055de458bef8f6ec2e68231f3ca7932bb9be
coverage: incremental
baseSha: 364ffa82136fcfc83d39ead1234abffaf500844b
previousReview: REV-2
reviewedAt: "2026-10-21T13:57:37Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5-1
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - security
  - performance
  - design
  - test-coverage
  - documentation
  - operability
produced:
  - mori://shinzui/kiroku/plans/101-refuse-origin-bearing-websocket-upgrades-under-the-disabled-cors-policy-and-harden-kiroku-inspect-startup
  - mori://shinzui/kiroku/plans/102-reconcile-the-0-10-and-0-11-release-surface-changelogs-operator-migration-guide-and-performance-ledger
context: >-
  Reviewed the eight commits between the 0.10.0.0 release commit and the
  release commit that published kiroku-store 0.11.0.0,
  kiroku-store-migrations 0.7.1.0, kiroku-metrics 0.3.0.0, kiroku-otel
  0.2.0.12, kiroku-cli 0.2.0.10 and shibuya-kiroku-adapter 0.6.0.1, together
  with the MP13 and plan 97 evidence those commits squash. This reviewer read
  the kiroku-store SQL, read, publisher and worker diffs, migration 0015, the
  changelogs, the MP13 rerun and the EP97 paired records directly, and ran the
  ADR-5 gates and every test suite at repository HEAD, whose kiroku-store and
  migrations source differs from the reviewed commit only by the 0.11.0.1
  error-path patch. The kiroku-metrics inspection surface (browse, dead
  letters, checkpoints, CORS, standalone, WebSocket convergence), the store
  dead-letter and browse statements and their tests were read by a delegated
  reviewer with no build access; its security and changelog findings were
  re-verified by this reviewer before being recorded. No remote cell was
  used. Performance claims rest on the retained cell comparisons and local
  same-process gates, never on absolute historical timings.
---

# Kiroku 0.11.0.0 inspection cohort

## Verdict

Changes requested, none of them for a consumer-visible defect. The new
surfaces are bounded where they claim to be: page sizes are validated before
SQL runs, the browse statements match the partial predicate of the new index
exactly and put their limit inside the seek, dead-letter pages are keyset
reads on an existing index, the stream head is anchored on the `streams` row
so a missing stream cannot return a head, and the standalone server holds no
subscription or write path. The append path gained exactly one index to
maintain. What needs correcting is the release surface: a changelog claim that
overstates the CORS default, an omitted source-compatibility break, docs that
called the surface unreleased at the release commit, and a performance ledger
that does not know these experiments happened.

## Required before the next tag

1. **Correct the kiroku-metrics 0.3.0.0 changelog and decide the upgrade
   default.** The entry says the CORS policy provides "WebSocket origin
   refusal before upgrade". With the default `corsDisabled`, and therefore
   with `kiroku-inspect` started without `--cors-origin`, `corsMiddleware` is
   the identity and no `Origin` is checked anywhere; browsers do not apply
   CORS to WebSockets, so any web page can open `/ws/events` and replay every
   event from position 0 on a listener that binds all interfaces. ADR-16
   states this ("disabled policy retains the previously open upgrades") and
   `CorsSpec.hs` pins it, so it is a decision, not an accident, and it is not
   new: `/ws/events` was equally open before this cohort. The changelog
   wording is still wrong and should be corrected in the repository and the
   next release notes. Refusing upgrades that carry an `Origin` header while
   the policy is disabled would close the browser case without affecting CLI
   or Haskell clients, which send none; that is the decision to record.
2. **Add the record-selector break to the kiroku-store changelog.**
   `SubscriptionDeadLetter` and `SubscriptionDeadLetterQuery` export
   `eventId`, `globalPosition`, `after` and `limit` under
   `DuplicateRecordFields` through `Kiroku.Store`, so a consumer that used
   those selectors bare on `RecordedEvent` or
   `HistoryRetentionInventoryQuery` now gets an ambiguous-occurrence error.
   The repository already had to add `hiding (eventId, globalPosition)` in
   `Worker.hs`. kiroku-metrics flagged its own analogous ambiguity; kiroku-store
   did not.
3. **Record the cohort's experiments in `docs/perf-experiment-log.md`.** The
   ledger's last rows are dated 2026-09-25. The MP13 five-pair comparison,
   its WAL-per-append diagnostic and the EP97 paired metadata gate are exactly
   what the methodology's step 2 expects a future contributor to find there,
   and the next person asked about the browse index's write cost will
   otherwise repeat the experiment.
4. **Extend `docs/user/schema-migrations.md` to 0015.** It still describes
   `0008` through `0012` as the native migrations and has a maintenance-window
   section only for 0012. Migration 0015's transactional `CREATE INDEX` takes a
   `SHARE` lock on `kiroku.streams`, and every append updates that table, so
   appends wait for the whole build; the changelog, migration comment and
   upgrade edge say so, the operator guide does not.

## Hot-path performance

| Path | What changed | Evidence | Assessment |
| --- | --- | --- | --- |
| Append (`streams` upsert) | Migration 0015 adds `ix_streams_browse_name ON streams (stream_name COLLATE "C") WHERE stream_id <> 0`; it is maintained on every new-stream insert and on any non-HOT update of `stream_version`. `streams` has fillfactor 50 since migration 0005, so most version bumps stay HOT | `0015.sql`; `0005-index-hygiene-and-streams-fillfactor.sql`; `StreamHeadIsolation.hs` pins the append, read and link SQL byte for byte | One index entry per new stream; nothing per event |
| Append SQL and link SQL | None | `git diff` of `SQL.hs`: additive statements only | Unchanged |
| Publisher delivery | One `modifyTVar'` on the `DropOldest` overflow branch only; one extra `TVar` per subscriber registration | `EventPublisher.hs` `deliverBatchSTM` | Zero on the non-overflow path |
| Worker | Import change only | `git diff` | Unchanged |
| Metadata read (`getStream`) | Unchanged; `getStreamWithHead` is a separate opt-in statement | EP97 paired gate below | Unchanged |
| Inspection tail (process hosting `/ws/events`) | Per batch: three STM reads instead of one, a set of stream ids and at most one `lookupStreamNames` round trip on a cache miss; per event one JSON key insert | `WebSocket.hs`; perf commit 30307c1 bounds miss detection to the current batch | Only when a tail is attached; not on the store path |

Retained evidence, all on dedicated PostgreSQL 18 cells:

| Experiment | Result |
| --- | --- |
| MP13 rerun, candidate 109d58f against released control 364ffa8, five interleaved pairs per case, 30 s measured appends per trial, 660,159 measured appends | Inspection disabled: throughput -1.544% (95% -4.090% to +1.069%), p50 +1.5%, p95 +1.8%. Inspection active: throughput -0.370% (-3.371% to +2.724%), p50 +0.9%, p95 flat. Every metric verdict under the zero-slowdown, 6%-width policy: inconclusive. WAL per measured append +2.85% (disabled) and +3.37% (active) |
| EP97 paired metadata gate at 05a11ba, two trials, 40 rounds of 1,000 calls, block-bootstrap 99% intervals | Production against frozen `getStream`: 1.005 (0.991 to 1.019) and 1.004 (0.994 to 1.014) at 100 events, 1.003 and 0.995 at 100,000; identical-code controls within 0.95 to 1.05; 20% extra-work control detected at 1.20. PASS under the 1.10 limit |
| MP13 unchanged workload gate on the cell | 16 cases passed; pipeline 0.69 and 0.70 against 0.90 |

The user accepted the MP13 result practically on 2026-10-11 after reading the
intervals. This review reads the evidence the same way the record does: the
cohort's append cost is bounded to a few percent on that cell, consistent
with the WAL growth of one extra index entry per new stream, and no
zero-regression claim is made. It is enough to say that nothing here explains
a double-digit slowdown in a consumer. Keiro's command guard, red at its
0.19.0.1 tag before adopting this cohort, is an absolute comparison against an
August baseline and cannot be attributed to Kiroku from Kiroku's side; the
same-process evidence above is the bound Kiroku can offer.

At repository HEAD the structural tier passes: the browse query-plan checks
(EXPLAIN on 40,000 streams, generic and custom plans, at most `limit` rows and
64 buffers), the stream-head isolation and plan checks, and the 16-case
workload gate. The `append-category-column` cell's control arm is invalid, as
REV-1 records; it does not measure this cohort.

## Security

Examined: CORS origin normalization (scheme, host and port compared on the
normalized origin; `Origin: null` rejected; duplicate `Origin` headers get no
grant; `Vary` merged on every response including HEAD and preflight;
preflight grants only GET and HEAD), error envelopes (`storeErrorResponse`
discards all server text; WebSocket errors are fixed strings with codes;
`invalid_query_parameter` echoes only the client's value), cursor forgery
(cursors are plain names and positions that only move the keyset inside what
the client can already page), request bodies (no route reads one), and the
WebSocket upgrade path (finding 1 above). No authentication exists on any
route and none is claimed; store-backed hosts gain the browse, dead-letter
and checkpoint routes automatically on upgrade with no opt-out short of
building their own `ServerProviders`, which the changelog lists as a feature
rather than a default change.

## Correctness

- **Browse.** `mkBrowsePageSize` is the only constructor and caps at 1,000
  plus one over-fetch; `streamRangeSQL` puts `LIMIT` inside the seek and the
  upper bound outside, so a prefix with no matches touches at most `limit`
  index entries and a short page proves exhaustion; the `WHERE stream_id <> 0
  AND stream_name COLLATE "C"` shape matches the partial index predicate
  exactly; a category containing `-` or a disjoint prefix and cursor yields no
  SQL at all; `listCategories` is a loose index scan on `ix_streams_category`
  whose outer `LIMIT` stops the recursion.
- **Dead letters.** Limits are validated at the type level; member-scoped
  pages are index-ordered keyset scans with no sort, which is what the plan
  test asserts; the all-member statements carry a bounded top-N sort over
  members times fetch, which the test bounds rather than denies.
- **Stream head.** Anchored on the `streams` row; the head is the newest
  `$all` row for the origin, served by `ix_stream_events_all_by_origin` in
  both literal and prepared plans; links do not move it because they insert
  rows with a non-zero `stream_id`; `$all` has no originated rows; logical
  truncation leaves it; hard delete removes the `$all` rows before the stream
  row.
- **Standalone.** Options and environment are range-checked; `runInspect`
  holds the store's `LISTEN` connection and publisher and no subscription or
  write; a `/ws/events` client makes the inspect process run the publisher's
  `readAllForward` per notification, which the guide should say.

## Operability notes

- Migration 0015 cannot use `CONCURRENTLY` inside the migration transaction;
  the build duration follows stream count, not event count. The changelog's
  "write pause on large stores" is accurate.
- `kiroku-inspect --port 0` binds loopback only (`openFreePort`), while fixed
  ports bind all interfaces and the guide says there is no bind option.
- Every startup failure of `kiroku-inspect` is collapsed into one redacted
  line and exit 1; port in use, bad credentials and missing schema are
  indistinguishable although their class could be reported safely.
- Both signal handlers are `Catch` and repeat signals are no-ops, so a hung
  shutdown ends only with SIGKILL; no concrete hang was traced.
- At the reviewed commit `docs/user/metrics.md` and the inspection guide
  still said the surface was unreleased; HEAD has fixed this.

## Test coverage

`BrowseQueryPlans.hs`, `BrowseReads.hs` (byte order, literal `%` and `_`,
scalar and surrogate edges, soft and hard delete), `DeadLetterQueryPlans.hs`,
`StreamHead.hs`, `StreamHeadIsolation.hs`, `CorsSpec.hs`, `StandaloneSpec.hs`
and `WebSocketConvergenceSpec.hs` cover the shipped behaviour; the delivery
oracle and 116 metrics examples were retained with the MP13 record. At HEAD
every suite passes (487 store, 117 metrics, 45 adapter, 24 otel, 22 CLI, 17
migration examples). Missing: a test that would fail if the disabled CORS
policy started refusing or admitting `Origin`-bearing upgrades by accident in
either direction is present only for the open direction.

## Evidence and limits

- Local, at HEAD e2cdc892: `just perf-structure`, `just bench-baseline-check`,
  `just perf-workload-gate`, `cabal test all`.
- Retained: `bench/mp13-release/validation-2026-10-11-rerun/README.md`,
  `docs/bench/stream-head/2026-10-11-ep97-paired/README.md` and
  `release-decision.json`, `bench/mp13-release/publication-2026-10-11/`.
- Not done: no separate build at the 0.11.0.0 tag; the `websockets` package
  internals and pg-migrate's transaction wrapping were not read from source;
  no remote cell.
