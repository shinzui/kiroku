---
id: 88
slug: expose-a-rest-read-api-for-browsing-streams-categories-and-events
title: "Expose a REST read API for browsing streams, categories, and events"
kind: exec-plan
created_at: 2026-09-10T02:48:14Z
intention: "intention_01m24kefe1en2vvvek852kwcgv"
master_plan: "docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-10T02:48:14Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-30T22:56:43Z
      mode: "update"
      note: "Adopted as a child of MasterPlan 13: settled ServerProviders record, errorEnvelope/errorResponse ownership, resolved-name encoder, versions deferred to plan 96, release milestone moved"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:07Z
      mode: "update"
      note: "Correct current APIs, integration ownership and bounded observer work; runtime acceptance remains pending."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T18:08:46Z
      mode: "implement"
      note: "Begin EP-3 with the required sparse-prefix SQL promotion check"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:07Z
      verdict: "comments"
      note: "Source review corrections applied; SQL promotion and focused performance gates require implementation evidence."
---

# Expose a REST read API for browsing streams, categories, and events

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Since 2026-09-30 this plan is EP-3 of
[MasterPlan 13, Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md),
which coordinates the five open keiro-ui requests as one cohort. It now hard-depends on plan 87
(EP-2), which introduces the `ServerProviders` record (with `webSocketServer`,
`subscriptionStatus`, and `checkpointInventory`) and the four `...WithProviders` functions this
plan's Milestone 3 originally proposed; this plan adds the `browser` field and the browse route
arms to that record instead of creating it. The MasterPlan's Integration Points section is
authoritative wherever this plan's older text disagrees. The other changes made at adoption: the
structured error envelope is plan 90's `errorEnvelope`/`errorResponse` pair in
`Kiroku.Metrics.JSON` (this plan's `browseErrorResponse` is withdrawn); the resolved-name event
encoder is named `recordedEventToJSONResolved` and lives in `Kiroku.Metrics.WebSocket` beside
`recordedEventToJSON`, because plan 94 (EP-5) uses it for WebSocket frames too; no `.cabal`
version or dependency bound changes here, because plan 96 (EP-7) assigns the cohort's versions
(`kiroku-store` 0.11.0.0 and `kiroku-metrics` 0.3.0.0 are the forecast; the 0.9.0.0 and
0.1.1.0 numbers in this plan's older text are stale, since `kiroku-store` 0.9.0.1 shipped on
2026-09-25); and the Milestone 4 ADR is withdrawn as subsumed by
[ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md).
Commits carry this plan's Intention trailer and a `MasterPlan:` trailer naming the MasterPlan
file.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store written in Haskell. Its HTTP sister package,
`kiroku-metrics`, can today tell an operator *how the store is doing* (metrics, health probes,
live subscription phases) and can *tail* events over a WebSocket, but it cannot answer a single
browsing question: which streams exist, what categories they fall into, what events one stream
holds, what sits at a given position of the global `$all` log, or what one event id contains. A
browser UI (the keiro runtime UI initiative) needs exactly those answers as ordinary paginated
JSON. Improvement Request IR-8
(`docs/improvement-requests/expose-a-rest-read-api-for-browsing-streams-categories-and-events.md`,
canonical handle `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-8`) asks for them.

After this plan, an operator who has started the store-aware metrics server (the same
`withMetricsServerWithStore` call the user guide already documents) can run:

```bash
curl -s 'http://localhost:9091/streams?prefix=orders-&limit=50' | jq .
```

and receive a JSON page of stream summaries with a `next_cursor` to page further; can list
categories at `GET /categories`; can read one stream's events forward or backward at
`GET /streams/<name>/events`; can page the `$all` log from an exclusive global position at
`GET /events?from=4200&limit=100`, where every item carries its resolved original stream name;
and can fetch one event at `GET /events/<event_id>`, receiving a structured error envelope with
HTTP 404 and a stable machine-readable `code` when it does not exist. Below HTTP, the core library
`kiroku-store` gains three read primitives on its public `Store` effect (`listStreams`,
`listCategories`, `getEvent`) so that the endpoints wrap supported library APIs rather than
running ad-hoc SQL, and so that any consumer can implement them in a database-free mock.

Everything is read-only, nothing existing changes shape, and `kiroku-store` gains no web
dependency.


## Progress

- [x] (2026-10-10) M0: verify all ten fresh-stream trials and recompute raw metrics; five-pair append acceptance is inconclusive (throughput -0.677%, 95% interval -2.687% to +1.374%).
- [x] (2026-10-10) M0: prepare the same-payload index-layout comparison, TypeID catalog/fresh fixtures, active category browsing and stream HOT/WAL snapshots; compile the Linux payload and verify paired-input/deadline invariants.
- [x] (2026-10-10) M0: verify remote lifecycle proof and second category-only control, sealed hashes, stream counters and owned lease release.
- [x] (2026-10-10) M0: complete and retain 18 sealed trials inside the original deadline, release the lease and verify all four cell instances stopped. Fresh acceptance is inconclusive; six observer trials are exploratory, not benchmark-grade. Acceptance remains open.
- [x] (2026-10-10) M0: research Kenshou coverage and a disposable category/name index replacement; retain three completed 96-case runs, initial setup error, layout sizes and benchmark source/run inventory. No append-cost acceptance.
- [x] (2026-10-10) Reviewed the integrated design against current source; corrected API and performance hazards. This is planning work, not implementation evidence.
- [x] (2026-10-10) M0: execute the focused existing-index SQL prototype check on PostgreSQL 18.6; retain 80 initial and 152 expanded EXPLAIN cases, migration hashes and verified owned-server cleanup.
- [x] (2026-10-10) M0 follow-up: evaluate category-scoped stream paging and prefix filtering with existing indexes; retain 192 correct-result EXPLAIN cases and verified server cleanup.
- [x] (2026-10-10) M0 range follow-up: retain 224 initial and 400 refined TypeID/name-range cases, including generic-plan scaling and ICU correctness failures; verify both owned servers stopped.
- [ ] M0 remaining: resolve ordered paging within large categories and the general prefix design after the failed promotion gates. No production browse SQL or HTTP route may be promoted yet.
- [ ] Implement and execute the remaining focused correctness and performance acceptance added by this review.

- [ ] M1: add `listStreamsStmt`, `listCategoriesStmt`, and `getEventStmt` to `kiroku-store/src/Kiroku/Store/SQL.hs` with encoders and SQL text.
- [ ] M1: add `ListStreams`, `ListCategories`, and `GetEvent` constructors to the `Store` effect in `kiroku-store/src/Kiroku/Store/Effect.hs` and interpret them in `runStorePool` (with the read `decodeReadEvents` path applied to `GetEvent`).
- [ ] M1: add `listStreams`, `listCategories`, and `getEvent` wrappers with Haddock to `kiroku-store/src/Kiroku/Store/Read.hs`.
- [ ] M1: add `kiroku-store/test/Test/BrowseReads.hs` (database tests) and `kiroku-store/test/Test/BrowseReadsMock.hs` (mock-interpreter test); register both in `kiroku-store/test/Main.hs` and the cabal test stanza; run the store test suite.
- [ ] M1: add this plan's bullets under `## Unreleased` in `kiroku-store/CHANGELOG.md` (no `version:` or bound edits; plan 96 assigns 0.11.0.0); `cabal build all` is warning-free.
- [ ] M2: create `kiroku-metrics/src/Kiroku/Metrics/Browse.hs` with `StoreBrowser`, `BrowseLimits`, `ReadDirection`, the query-parameter parser, the page envelope, `streamInfoToJSON`, and `browseApp`; add `recordedEventToJSONResolved` to `Kiroku.Metrics.WebSocket` (owned here; plan 94 hard-depends on this plan).
- [ ] M2: add `kiroku-metrics/test/Test/BrowseSpec.hs` database-free tests over a mock `Store` interpreter covering every route, pagination, and every error code; register the module and add `effectful-core` to the library and test-suite `build-depends`.
- [ ] M3: add the `browser` field to plan 87's `ServerProviders` in `kiroku-metrics/src/Kiroku/Metrics/Server.hs` (`Nothing` in `defaultServerProviders`, `Just (storeBrowser store)` in `storeServerProviders` and `startMetricsServerWithStore`); route `/streams`, `/categories`, and `/events` to the browser in `httpAppWithProviders`.
- [ ] M3: extend `kiroku-metrics/test/Test/BrowseSpec.hs` with end-to-end tests against a real ephemeral PostgreSQL store, plus regression assertions that the legacy 404 body and the pre-existing endpoints are unchanged; run the metrics test suite.
- [ ] M4: document the endpoints in `docs/user/metrics.md` (one copyable transcript per endpoint, the error-code table, the cursor rules) and the new primitives in `docs/user/reading-events.md`; update `docs/user/README.md`.
- [ ] M4: extend `kiroku-metrics/example/Main.hs` with browse checks and update its documented transcript.
- [ ] M4: add this plan's bullets under `## Unreleased` in `kiroku-metrics/CHANGELOG.md` describing the new routes and exports (no `version:` edit; plan 96 assigns 0.3.0.0); update CAP-17 and its log; add IR-8's "Implementation Evidence" section.
- [ ] M4: ADR distillation pass (the browse-endpoint ADR first planned here is withdrawn as subsumed by ADR-9; record in Outcomes whether anything else is durable).
- [ ] Fill in Outcomes & Retrospective, mark EP-3 `Complete` in the MasterPlan registry, and record the closing provenance revision.


## Surprises & Discoveries

- 2026-10-10 observer-grade failure: all six observer runs sealed, but 1 Hz
  browsing produced 185–186 samples per run, below the 1,000-sample operation
  minimum. The whole-run grade is exploratory. The controller caught this only
  after the queue; an early progress-audit grade check now prevents recurrence.
  All raw summaries were recomputed and all original pairs retained, without
  reruns, relaxed policy or acceptance. Diagnostic browse p50 fell 92.31%;
  combined append throughput was +2.326% (95% interval -0.900% to +5.656%).
  Exact delivery, durable drain, counters and sealed hashes passed. The lease
  is released and all four cell instances are stopped. See the
  [matched result](../../bench/mp13-index/evidence/2026-10-10/README.md).
- 2026-10-10 fresh comparison: throughput point estimate is -0.677%, with a
  95% interval from -2.687% to +1.374%; all four append metrics are inconclusive.
  Global WAL/event rose 2.43% descriptively; stream HOT fractions stayed
  98.703% / 98.698%. Incrementally populated fixture stream-index bytes rose
  79.06%, beyond the earlier compact-layout 53.7% result. Footprint does not
  translate directly into write latency. Observer results are retained in the matched experiment report.
- 2026-10-10 remote checkpoint: UUIDv4 plan IDs were rejected before execution;
  corrected to UUIDv7 and retained the rejection. Missing `zstd` publication
  tooling was supplied by the established pinned shell. The corrected proof
  and second control verified. The proof's 41,830 inserts/updates included
  41,280 HOT updates. Actual journals took 151.7s/132.2s per control, so the
  original two five-pair queues no longer fit the remaining hour. Before
  second-case submission, retain five fresh pairs and choose three observer
  diagnostic pairs. Its unchanged five-pair acceptance remains inconclusive;
  no deadline or policy was reset.
- 2026-10-10 matched harness preparation: Kenshou's `cell pair` shortcut varies
  payload identities, not knobs. The dedicated controller submits explicit AB/BA
  specs through the same executable and compares only `mp13.index-layout`. The
  default MP12 workload leaves layout unchanged. Linux compilation passed; the
  exploratory Darwin package compiled but failed its GHC runtime-closure check,
  so this dedicated payload advertises Linux only. No write-cost result is inferred.
  See [the bounded protocol](../../bench/mp13-index/README.md).
- 2026-10-10 index research: replacing the category-only index with
  `(category, stream_name)` in disposable databases gave correct results within
  the existing budget in all 48 replacement cases across C/ICU and generic/custom
  plans, including category enumeration. At 40,007 streams its compact footprint
  was 2,672 KiB versus 288 KiB; total stream-index bytes rose 53.7%. Current
  subscriptions use a separate unchanged `stream_events` index. Writer/cache
  effects remain unmeasured, as do this candidate's optional prefix filters.
  Kenshou's local historical runs use store 0.8.0.1; reuse the dedicated matched
  workload, not that historical control. Stream HOT counters and realistic fresh
  TypeID fixtures are missing from the existing payload. See the
  [index/benchmark research](../../kiroku-store/bench/results/mp13-ep3-index-research/README.md).

- 2026-10-10 range follow-up: splitting bare-name and prefix-range branches can
  reduce ordinary TypeID category pages to eleven examined rows. Replacing the
  generated-category predicate with its equivalent name expression avoided a
  generic plan scanning 20,007 rows / 568 buffers in the neighbor fixture; the
  range candidate then examined 11 rows / 8 buffers. This is not portable
  acceptance: small-fixture planner choices still exceed the unchanged budget,
  and codepoint upper bounds omitted valid literal `%` and Unicode matches in
  ICU. All 200 refined C cases were correct; 32 of 200 ICU cases were incorrect.
  Both runs, exact SQL and comparisons are retained in the
  [range evidence](../../kiroku-store/bench/results/mp13-ep3-range/README.md).
  Write cost remains unmeasured. Appends update application and `$all` stream
  versions; an added index can affect new-stream inserts and non-HOT updates
  despite existing fillfactor 50. It cannot be described as free for event creation.

- 2026-10-10 category follow-up: category equality does use the existing category
  index. Applying category/cursor/prefix filters in a materialized CTE before
  ordering kept a 1,001-stream category at 1,001 examined rows / 27 buffers when
  unrelated streams grew from 1K to 20K. Growing that category to 20,001 streams
  raised work to 20,001 rows / 439 buffers for an eleven-row page. Direct LIMIT
  plans sometimes scanned unrelated inventory through the name index instead.
  All 192 cases returned correct results; C and English ICU, generic and custom
  modes agreed on these counts. Late cursors were cheap in some direct plans,
  while prefix filtering continued to scan the selected category. See the
  [category evidence](../../kiroku-store/bench/results/mp13-ep3-category/README.md).
  No index, migration or production API was added; no gate was relaxed.

- 2026-10-10 implementation: the prefix prototype fails Milestone 0. An absent
  prefix examines 1,003 / 20,003 rows at 1K / 20K noise inventory under generic
  plans in both C and English ICU collations (page limit 11). A mandatory cursor
  becomes an Index Cond but examines 502 / 19,502 rows; LIKE is no remedy for
  generic plans. ICU custom plans also scan inventory. Category nullable-cursor
  generic plans have the same scaling defect; first/mandatory-cursor variants
  reduce the after-last-category case to zero examined rows and 1 / 2 buffers.
  [Retained evidence](../../kiroku-store/bench/results/mp13-ep3-prefix/README.md)
  contains exact SQL, full plans, migration hashes and cleanup. No append
  regression or observer neutrality was measured. No production primitive has
  landed, and the gate has not passed.

- 2026-10-10 source review: The proposed Hasql interpreter swapped cursor and prefix; GetEvent treated DecodedBatch as a vector. LIMIT did not prove sparse-prefix query work bounded, and an exported unvalidated limit could overflow during over-fetch. No runtime acceptance is inferred from this finding.



## Decision Log

- Decision (2026-10-10 measured evidence): retain the replacement candidate,
  without production promotion. Fresh five-pair acceptance is inconclusive,
  and observer evidence is exploratory and below the minimum pair count.
  Faster diagnostic category browsing does not override those gates or settle
  general prefix/namespace access. Preserve every sample and the original
  grade rejection; fix early grade detection rather than rerun under a weaker
  policy. ADR-15 continues to govern the shared plan 54 design and cumulative
  original-control cost. No new durable architecture was selected.
- Decision (2026-10-10 matched comparison): keep both arms on the same current
  source and payload. Select fresh appends without observers, then existing
  appends with one category subscriber and one browse cycle per second, over
  20K streams per category. Declare 10/61/10-second phases, five interleaved
  pairs per case and the existing zero-slowdown policy before measurement. A
  small proof/calibration precedes expansion; its size does not prove statistical
  resolution. One persisted hour covers build, setup, recovery and verification.
  Stop rather than silently reduce coverage, weaken policy or replace failed runs.
- Decision (2026-10-10 research): retain the category/name replacement as a
  candidate, not a selected migration or complete browse access design. Reuse
  the existing matched append/subscriber harness with current-source arms that
  differ only by recorded layout. Measure stream HOT/update behavior and fresh
  inserts; benchmark placement/grade and historical hardening acceptance do not
  establish this index's write cost. Report whole-experiment scope and runtime
  before remote execution; no remote queue or lease was started. ADR-15 remains
  authoritative for plan 54 coordination and cumulative original-control cost.

- Decision (2026-10-10 range implementation): retain the improved name-range
  candidate as diagnostic evidence and reject production promotion. Neither
  ordinary TypeID success nor bytewise bounds prove the full name/collation
  contract. Resolve the physical access design with plan 54 under ADR-15 before
  proposing a migration, and measure its cumulative write cost rather than
  assuming stream indexes leave event appends unaffected. No index is selected
  or authorized; M1–M4 remain open.

- Decision (2026-10-10 user clarification): review prefix/category physical access
  together with [plan 54](54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md)
  under ADR-15 before proposing any index. Reuse suitable structures; justify separate ones
  against the combined read requirements and cumulative append cost against the same original
  control. Do not grant separate additive write-regression allowances to the two features.
  Rationale: both features can impose ongoing overhead on every writer. Coordination is
  required even though stream-name paging and global-event ordering have different needs.
  Plan 54 is not a new implementation prerequisite, and no index is authorized here.

- Decision (2026-10-10 user-directed follow-up): investigate category-scoped
  stream browsing first with the existing schema, because users normally browse
  streams inside a category. Keep arbitrary prefix search as a valid UI
  requirement; neither global search nor literal prefix semantics is dropped.
  Rationale: category is already a generated, indexed column, so an explicit
  category predicate should be evaluated before any index proposal. The measured
  category-first variant removes unrelated-inventory scaling in these fixtures,
  but still has category-sized sort/filter work; it is not approved for promotion.
  The API signature and route query parameters remain proposals pending this
  design decision. The user's no-new-index constraint applies to this experiment.

- Decision (2026-10-10 implementation): reject the nullable/prefix prototype and
  hold Milestones 1–4 pending a reviewed prefix redesign. Splitting cursor
  predicates is necessary for category queries, but insufficient for generic
  prefix queries. Do not force C collation, silently replace literal-prefix
  semantics, or add an index as an incidental implementation change.
  Rationale: measured work grows with inventory despite response LIMIT, violating
  this plan's explicit promotion gate and ADR-15. A prefix index would require
  a separate read/write design and append-cost review; retaining no migration
  leaves no demonstrated general solution. Use a local psql diagnostic over
  the actual migration SQL to reject the prototype before adding production
  statements or Hasql APIs; migrate any approved query shape into the existing
  PerformanceStructure tests when implementation resumes.

- Decision (2026-10-10): the reviewed Context and Plan of Work supersede incompatible September choices on dependencies, routes, decoding, method handling, bounds and performance. Implementation remains pending; durable constraints are in ADR-15.
  Rationale: the released APIs changed and the original sketches contained correctness and shared-resource hazards.

- Decision: Reuse `StreamInfo` as the row type of `listStreams` and compute each summary's
  category in the endpoint with the existing `Kiroku.Store.Types.categoryName`, rather than
  adding a `category` field to `StreamInfo`.
  Rationale: `categoryName` is documented as the exact Haskell mirror of the generated
  `streams.category` column, so the value is identical; adding a field would be a second
  breaking change to a widely constructed record, and IR-8 explicitly does not ask to change any
  existing `Kiroku.Store.Read` signature.
  Date: 2026-09-10

- Decision: Model the three new primitives as positional `Store` constructors —
  `ListStreams (Maybe Text) (Maybe StreamName) Int32`, `ListCategories (Maybe CategoryName) Int32`,
  `GetEvent EventId` — returning `Vector StreamInfo`, `Vector CategoryName`, and
  `Maybe RecordedEvent`.
  Rationale: This mirrors the existing read constructors (`ReadStreamForward name cursor limit`,
  `GetStream name -> Maybe StreamInfo`), keeps the effect closed and exhaustively matchable by
  mock interpreters, and expresses "not found" as `Maybe`, the same typed shape `getStream` uses.
  Date: 2026-09-10

- Decision: `GetEvent` returns the event as seen from the global `$all` log: `streamVersion`
  equals `globalPosition` (the `$all` junction row's `stream_version`), and
  `originalStreamId`/`originalVersion` come from that junction row.
  Rationale: An event id is not stream-scoped (an event can be linked into many streams), so the
  only canonical single row is its `$all` entry. This matches what `readAllForward` returns for
  the same event, so a client fetching by id sees the same object it saw in a `$all` page.
  Date: 2026-09-10

- Decision: The prefix filter uses PostgreSQL `starts_with(stream_name, $prefix)`, not `LIKE`,
  and the plan adds no new index.
  Rationale: `starts_with` is exact for every prefix (no `%`/`_` escaping) and independent of
  collation. The `streams` table has one row per stream, not per event, so a filtered ordered
  index walk is bounded by stream count. A `text_pattern_ops` index would let `LIKE` use the
  index under non-C collations but adds write amplification to every stream creation; IR-8 asks
  for no schema change and the browse path is not a hot path.
  Date: 2026-09-10

- Decision: `listCategories` uses a recursive-CTE "loose index scan" over `ix_streams_category`
  instead of `SELECT DISTINCT category`.
  Rationale: `DISTINCT` must read every index entry of every category on the page, which for a
  category with millions of streams is a million entries per request. The loose index scan
  visits one entry per category and stops at the page limit.
  Date: 2026-09-10

- Decision: Every list endpoint (`/streams`, `/categories`, `/streams/<name>/events`,
  `/categories/<name>/events`, `/events`) returns the same page envelope
  `{"items": [...], "next_cursor": ...}`, over-fetches one row beyond `limit` to decide whether
  `next_cursor` is present, and omits `next_cursor` on the last page.
  Rationale: The cross-project inspection conventions require exclusive `from` + `limit` in,
  `items` + `next_cursor` out, with `next_cursor` omitted as the end-of-data signal. Over-fetching
  by one makes that signal exact without a second round trip; a page whose size equals `limit`
  is otherwise indistinguishable from a full last page.
  Date: 2026-09-10

- Decision: Event items are the published `recordedEventToJSON` object plus one additional
  snake_case key, `original_stream_name`, resolved server-side through `lookupStreamNames`.
  Rationale: ADR-1 requires names to be resolved by batch lookup, and the keiro-ui conventions
  state that a new field added to the published camelCase event object is snake_case. Keeping the
  event object flat lets the browser reuse one decoder for WebSocket `event` frames and REST
  items; the extra key is optional in that decoder.
  Date: 2026-09-10
  Amended on 2026-09-30: the encoder is `recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value`
  in `Kiroku.Metrics.WebSocket`, beside `recordedEventToJSON`, and is shared with plan 94, which
  puts the same key on WebSocket `event` frames. This plan owns it; plan 94 hard-depends on this plan and reuses the completed encoder.

- Decision: Add `GET /streams/<name>` (one stream summary) and a `direction=backward` option on
  `GET /events`, which IR-8 does not list.
  Rationale: The `/streams/<name>/events` route must already call `getStream` to return a
  `stream_not_found` 404, so exposing the same result as a summary costs one route match; a UI
  stream page needs the metadata without a prefix search. `readAllBackward` already exists and
  a "latest events" view is the first thing a browser shows. Both are additive and read-only;
  IR-8 leaves exact routes to Kiroku.
  Date: 2026-09-10

- Decision: The server stays store-agnostic by receiving a `StoreBrowser` — a newtype around a
  runner `forall a. Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)` — and
  the routes are written as `Store`-effect programs; `storeBrowser :: KirokuStore -> StoreBrowser`
  is `runStoreIO`.
  Rationale: This is the same seam pattern `SubscriptionStatusProvider` and the WebSocket app use
  (the store enters through a caller-built closure). It lets the endpoint tests run a mock
  `Store` interpreter with no database, which is what IR-8 acceptance 6 asks of the primitives
  and what makes the HTTP layer independently testable.
  Date: 2026-09-10

- Decision: Introduce one `ServerProviders` record (`webSocketServer`, `subscriptionStatus`,
  `browser`) and one general starter, `startMetricsServerWithProviders`, and keep every
  existing starter and app function with its exact signature as a delegating wrapper.
  `startMetricsServerWithStore`/`withMetricsServerWithStore` gain browsing automatically;
  `/subscriptions` behavior on those starters is unchanged.
  Rationale: `startMetricsServerWith'` already has five positional arguments; a sixth would be a
  breaking change and would grow again with plan 87. A record grows additively. Wiring browsing
  into the store-aware starter is what IR-8 means by "served by the existing sister package";
  turning on `/subscriptions` there would change a pre-existing endpoint's response, which
  acceptance 7 forbids.
  Date: 2026-09-10
  Amended on 2026-09-30: MasterPlan 13 adopted this record design cohort-wide and assigned its
  introduction to plan 87 (EP-2), which lands before this plan and adds the `checkpointInventory`
  field; this plan only adds `browser`. The behaviour decided here (browsing on the store-backed
  starters, `/subscriptions` unchanged there, `storeServerProviders` wiring everything) stands.

- Decision: Browse limits (`defaultLimit = 100`, `maxLimit = 1000`) live in a `BrowseLimits`
  record carried by `StoreBrowser`, not in `MetricsServerConfig`; an out-of-range `limit` is
  rejected with HTTP 400 rather than clamped.
  Rationale: Adding fields to `MetricsServerConfig` breaks every caller that constructs the
  record positionally or completely, forcing a major bump for a read-only addition. Rejecting an
  invalid `limit` is explicit and surfaces client bugs; clamping silently returns a different
  page than asked for.
  Date: 2026-09-10

- Decision: Version bumps: `kiroku-store` 0.8.0.0 → 0.9.0.0 (the exported `Store` effect gains
  constructors, which breaks exhaustive custom interpreters, following the 0.7.0.0 precedent);
  `kiroku-metrics` 0.1.0.8 → 0.1.1.0 (new modules and exports, nothing removed or changed);
  `kiroku-cli`, `kiroku-otel`, `shibuya-kiroku-adapter` patch bumps for the `^>=0.9` bound.
  Publishing to Hackage is not part of this plan.
  Rationale: PVP; the repository's changelog precedent (0.7.0.0, 0.8.0.0 and the 2026-08-16
  patch cohort) is followed exactly. Releases in this repository require the user's explicit
  release-time confirmation (see `docs/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption.md`),
  so this plan stops at in-tree version metadata and changelogs.
  Date: 2026-09-10
  Superseded on 2026-09-30: the numbers are stale (`kiroku-store` 0.9.0.1 is released) and no
  `.cabal` version or bound is edited by this plan at all. This plan writes bullets under one
  `## Unreleased` heading per changelog; plan 96 (EP-7) assigns the versions, forecast as
  `kiroku-store` 0.11.0.0 and `kiroku-metrics` 0.3.0.0, and moves the bounds.

- Decision: Coordinate with the parallel plan
  `docs/plans/87-serve-durable-subscription-checkpoints-over-http.md` (IR-10), which was created
  minutes before this one and is still a skeleton: the error-envelope helper and the
  `ServerProviders` record introduced here are the shared home for any further new
  `kiroku-metrics` route, and whichever plan lands second reuses them instead of adding a second
  envelope or a second starter.
  Rationale: Two independently designed envelopes or starters for two new endpoint families in
  the same package would violate the conventions' "one dialect" goal and force a breaking
  consolidation later.
  Date: 2026-09-10
  Superseded on 2026-09-30 by MasterPlan 13's fixed ownership: plan 90 (EP-1) creates the
  envelope helpers `errorEnvelope :: Text -> Text -> Maybe Value -> Value` and
  `errorResponse :: Status -> Text -> Text -> Maybe Value -> Response` in `Kiroku.Metrics.JSON`,
  plan 87 (EP-2) creates the record, and this plan hard-depends on plan 87. This plan's
  `browseErrorResponse` is withdrawn; every error response in `Kiroku.Metrics.Browse` is built
  with `errorResponse`.

- Decision: The Milestone 4 ADR on browse endpoints wrapping `Store` primitives is withdrawn.
  Rationale: [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md),
  accepted on 2026-09-10 after this plan was written, already records that sister-package
  endpoints wrap supported `Store` APIs, add missing reads to the library first, and grow only
  additively under the conventions; a second record would duplicate it. MasterPlan 13 assigns
  the composition-boundary ADR (providers record, prefix-mountable application, self-hosting) to
  plan 95.
  Date: 2026-09-30


## Outcomes & Retrospective

2026-10-10 matched experiment completion: all 18 trials sealed; workload and
artifact checks completed, owned lease released and all four instances stopped
within the original hour. Fresh throughput estimate is -0.677% with an interval
from -2.687% to +1.374%; fresh append acceptance remains inconclusive. Observer
results are exploratory because the low-rate browse operation failed the sample
grade minimum, in addition to the three-pair acceptance limit. Retain every
sample, rejection and raw recomputation; an early grade guard prevents repeating
this queue mistake. M0 remains In Progress; no production migration or browse
route was promoted. ADR distillation found no new selected architecture. See
the [full report](../../bench/mp13-index/evidence/2026-10-10/README.md).
2026-10-10 matched harness checkpoint: benchmark-only preparation is complete
and Linux compilation passed. Paired-input and persistent-deadline checks passed;
remote proof and measured write cost remain pending. No production migration or
browse milestone is promoted. ADR-15 already governs this focused experiment.
2026-10-10 index research: completed the authorized source/benchmark research
and local footprint/read diagnosis. Three 96-case runs, the zero-case setup error
and the unchanged prefix regression result are retained, with all five owned
clusters stopped. The replacement bounded the tested category pages/enumeration
while increasing index footprint;
event-append and active-observer cost remain unmeasured. EP-3 remains In Progress
because general prefix access and complete promotion evidence are unresolved.
No production index, route or primitive was added. The research report records
the smallest useful matched comparison and its missing instrumentation; no
remote benchmark was launched. ADR distillation found no new durable decision.

2026-10-10 range follow-up: completed the authorized existing-index experiment
in 23.48 seconds initially and 39.24 seconds after a focused planner/prefix
refinement, including setup and verified cleanup. The retained 624 cases expose
both useful ordinary TypeID seeks and correctness/scaling failures. The gate is
still rejected; no production primitive, HTTP route or index was added. ADR-15
already governs this result, so no durable architectural change is adopted.

2026-10-10 category follow-up: completed the user's requested no-new-index
prototype in 15.97 seconds with correct results in 192 cases and a verified
stopped cluster. Category equality is useful for the primary UI workflow;
materialization contained work to the selected category in the tested fixtures.
The remaining scaling risk is inside a large category, plus the earlier global
prefix issue. EP-3 remains In Progress with all production milestones open.
Arbitrary prefix search remains required. ADR-15 already covers the bounded-work
obligation; this investigation selects no new architecture or index, so no ADR
revision is needed.

2026-10-10 implementation stopping point: Milestone 0 was executed and rejected
its stream-prefix prototype. The initial and expanded local runs took 3.62 and
4.97 seconds, including setup and cleanup; both owned clusters were verified
stopped. EP-3 is In Progress, not Complete. The core primitives, HTTP routes,
wire tests, example and documentation remain unimplemented; no release or
cumulative append-under-observer acceptance is claimed. Existing-index category
cursor splitting is viable, but does not resolve prefix filtering. ADR distillation
found this stop already covered by ADR-15; no new architectural decision was
made. Resume by reviewing an explicit prefix read/write design before M1.

2026-10-10 review: implementation and performance acceptance remain pending. Static review does not prove zero runtime regression. Earlier planning-time observations and dated decisions are historical where this revision explicitly replaces them.



## Context and Orientation

### Review baseline and acceptance boundaries (2026-10-10)

This plan is reviewed against `f1a0209`. Hackage preferred-version JSON and upstream tags
both identify `kiroku-store-0.10.0.0` and `kiroku-metrics-0.2.0.0` as already released.
The inspection forecast is now store 0.11.0.0 / metrics 0.3.0.0, not a reservation;
plan 96 must re-query releases and compute every dependent's version from its actual diff.
September source-version observations are historical, not current API authority.

[ADR-15](../adr/0015-inspection-observers-preserve-wire-contracts-and-bound-shared-work.md)
requires compatibility and bounded shared work. [ADR-12](../adr/0012-decode-failures-are-per-event-outcomes-with-independent-subscription-dispositions.md)
requires typed decode failures and the no-hook fast path. Re-read the named implementation
before coding: public reads use `decodeReadEvents`; publisher queues carry `DecodedBatch`,
not `Vector RecordedEvent`. Successful hooks return `Right`; a typed failure must never
turn into partial successful data. New HTTP store failures use sanitized messages:
`ConnectionError` gives 503 with the route's unavailable code, `EventDecodeFailed` gives
500 `event_decode_failed`, and other store errors give 500 `store_error`.
Never expose `show err`, connection strings or payloads; never catch asynchronous cancellation
as an expected store failure. Existing published error bodies remain unchanged.

All new read paths support GET and HEAD, returning identical status and headers with no HEAD
body. Other methods give 405 `method_not_allowed` and `Allow: GET, HEAD`. Implement this
in the WAI apps themselves, not only by relying on Warp. Query numbers are parsed from ASCII
digits into `Integer`, range-checked, and only then narrowed; reject signed/empty/overflowing
values and duplicate recognized parameters with 400 `invalid_query_parameter`.
Decode UTF-8 totally. Ignore unknown parameters as documented. Limits cap the page before
over-fetching one row, and integer narrowing must not wrap. Clients handling Int64 JSON fields
must use lossless integer parsing rather than silently rounding positions above 2^53.

No new append SQL, index, lock, checkpoint write, pool checkout, or per-event publisher work
is justified by a read-only label. New DB reads contend for shared resources. Use existing
correctness tests, structural invariants and a focused affected-path check per child.
Plan 96 owns the cumulative original-control comparison on PostgreSQL 18; the existing
pipeline-versus-sequential ratio and historical Shibuya catch-up results do not prove this
cohort neutral. Before any remote run, report cases, trial count, warmup, measurement and
setup/recovery time, uncertainty target and stopping conditions within a single 60-minute
ceiling. Preserve samples and lease cleanup; do not silently weaken a gate, repeat until
favorable, or expand to a full matrix. Reproducible append regressions block acceptance;
unmeasured or noisy evidence is explicitly pending or inconclusive.

### The repository and its packages

This repository is a Cabal multi-package project (`cabal.project` at the root lists the
packages; GHC 9.12.4). The two packages this plan touches are:

- `kiroku-store/` — the core event store library. Its modules live under
  `kiroku-store/src/Kiroku/Store/`. `Kiroku.Store` (`kiroku-store/src/Kiroku/Store.hs`) is an
  umbrella module that re-exports the public API, including `Kiroku.Store.Types`,
  `Kiroku.Store.Effect`, and `Kiroku.Store.Read`.
- `kiroku-metrics/` — the HTTP sister package. Its modules live under
  `kiroku-metrics/src/Kiroku/Metrics/`. `Kiroku.Metrics` (`kiroku-metrics/src/Kiroku/Metrics.hs`)
  re-exports every module in the package.

Three other packages depend on `kiroku-store` with the bound `^>=0.8` and must follow its
version bump: `kiroku-cli/kiroku-cli.cabal`, `kiroku-otel/kiroku-otel.cabal`, and
`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` (each in two stanzas). `kiroku-metrics`
also depends on `kiroku-cli ^>=0.2` for the shared subscription-status JSON codec.

Tests use hspec and a real ephemeral PostgreSQL. `kiroku-test-support/src/Kiroku/Test/Postgres.hs`
exports `withSharedMigratedPostgres :: IO a -> IO a` (each test suite's `main` wraps `hspec` in
it: it starts one PostgreSQL server for the whole run) and
`withMigratedTestDatabase :: (Text -> IO a) -> IO a` (gives a test a fresh migrated database and
its connection string). `kiroku-store/test/Test/Helpers.hs` adds `withTestStore` (a bracket that
opens a `KirokuStore` on such a database), `withTestStoreSettings` (same, letting the test
transform the connection settings first), and `makeEvent :: Text -> Value -> EventData`.

### The `Store` effect, interpreters, and mock interpreters

Kiroku's library API is expressed as an *effect* using the `effectful` library. An effect is a
data type whose constructors name operations; `Store` is declared as a GADT in
`kiroku-store/src/Kiroku/Store/Effect.hs`:

```haskell
data Store :: Effect where
    AppendToStream :: StreamName -> ExpectedVersion -> [EventData] -> Store m AppendResult
    ReadStreamForward :: StreamName -> StreamVersion -> Int32 -> Store m (Vector RecordedEvent)
    ReadAllForward :: GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
    GetStream :: StreamName -> Store m (Maybe StreamInfo)
    LookupStreamNames :: [StreamId] -> Store m (Map StreamId StreamName)
    ReadCategoryForward :: CategoryName -> GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
    -- ... more constructors ...
```

An *interpreter* gives the constructors meaning. The PostgreSQL interpreter is `runStorePool` in
the same file: a big `interpret_ $ \case ...` whose branches run a Hasql statement against the
store's connection pool. Reads go through the helper `usePool (store ^. #pool) session`, which
maps any pool or SQL error to `ConnectionError`. Read branches then pass the rows through
`decodeReadEvents (store ^. #storeSettings) evs` (`kiroku-store/src/Kiroku/Store/Effect.hs`),
which applies the optional per-store `decodeHook :: Maybe (RecordedEvent -> IO (Either DecodeFailure RecordedEvent))`
that consumers such as `kiroku-otel` install; every new read of `RecordedEvent`s must do the
same. `runStoreIO :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)`
is the convenience runner (`runEff . runErrorNoCallStack . runStorePool store`).

A *mock interpreter* is any other `interpret_` over the same constructors, for example
`kiroku-store/test/Test/VisibleGlobalHeadPositionMock.hs`, which returns a fixed position and
`error`s on any other constructor. Because `Store` is a closed GADT, adding a constructor is a
breaking change for every exhaustive interpreter; the repository compiles with
`-Werror=incomplete-patterns`, so any interpreter in this repository that forgets the new
constructors fails to build.

Public functions wrap constructors with `send`. `kiroku-store/src/Kiroku/Store/Read.hs` holds the
read wrappers: `readStreamForward`, `readStreamBackward`, `readAllForward`, `readAllBackward`,
`visibleGlobalHeadPosition`, `readCategory`, `getStream`, `lookupStreamId`,
`eventExistsInStream`, `lookupStreamName`, and `lookupStreamNames`. Every cursor argument is
*exclusive*: `readStreamForward name (StreamVersion 0) limit` returns events with
`streamVersion > 0`, and `readAllForward (GlobalPosition 0) limit` returns events with
`globalPosition > 0`. For the backward readers the interpreter maps a cursor of `0` to `maxBound`
so `0` means "from the newest".

SQL statements live in `kiroku-store/src/Kiroku/Store/SQL.hs`. Each is a Hasql `Statement`
built with `preparable sqlText encoder decoder`; encoders combine parameters with
`contrazip2`/`contrazip3` from `contravariant-extras`; the shared row decoders are
`recordedEventRow :: D.Row RecordedEvent` (11 columns) and `streamInfoRow :: D.Row StreamInfo`
(6 columns: `stream_id, stream_name, stream_version, created_at, deleted_at, truncate_before`).
Table names are unqualified because the connection's `search_path` puts the `kiroku` schema
first (ADR-3, below).

### The types you will use

From `kiroku-store/src/Kiroku/Store/Types.hs`: `StreamName` (newtype over `Text`), `StreamId`
(newtype over `Int64`, the database surrogate id of a stream), `EventId` (newtype over `UUID`),
`StreamVersion` and `GlobalPosition` (newtypes over `Int64`), `CategoryName` (newtype over
`Text`), `categoryName :: StreamName -> CategoryName` (the text before the first `-`, or the whole
name if it has no dash), `StreamInfo` (fields `id`, `name`, `version`, `createdAt`, `deletedAt`,
`truncateBefore`), and `RecordedEvent` (fields `eventId`, `eventType`, `streamVersion`,
`globalPosition`, `originalStreamId`, `originalVersion`, `payload`, `metadata`, `causationId`,
`correlationId`, `createdAt`). A *fan-in read* is any read that returns events from many streams
(`$all`, a category, causation queries, subscriptions); such events carry only the surrogate
`originalStreamId`, never the stream name (ADR-1).

From `kiroku-store/src/Kiroku/Store/Error.hs`: `StoreError`, whose constructors include
`ConnectionError Text` (what `usePool` raises), `StreamNotFound`, `ReservedStreamName` (the name
`$all`), and `StreamNameTooLong`; and `validateStreamName :: StreamName -> Either StoreError ()`,
which rejects `$all` and names over 512 UTF-8 bytes.

### The database schema that the new SQL reads

The user's application names streams `<category>-<typeid>`. UUIDv7-based TypeIDs
provide approximate ID-generation-time order under bytewise string ordering; that is
not global event order or necessarily stream insertion order. The store itself accepts
arbitrary stream names and does not enforce this convention. A common category prefix
already groups names under bytewise ordering regardless of whether the suffix is ordered.
TypeIDs therefore make name-order browsing useful, but do not by themselves turn category
filtering or `starts_with` into an index seek. Any existing-name-index range candidate must
prove membership, cursor behavior and bounded work under the database's actual collation
and generic/custom plans. Do not impose a new naming restriction or change collation.

The schema is owned by `kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql` and later
files (`0005-…`, `0006-…`, `0007-stream-truncate-before.sql`). The relevant facts:

- `streams` has `stream_id BIGSERIAL PRIMARY KEY`, `stream_name TEXT NOT NULL UNIQUE`
  (constraint `ix_streams_stream_name`, a B-tree usable for `ORDER BY stream_name` and
  `stream_name > $cursor`), `category TEXT GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED`
  with index `ix_streams_category`, `stream_version BIGINT NOT NULL DEFAULT 0`,
  `created_at TIMESTAMPTZ NOT NULL`, `deleted_at TIMESTAMPTZ` (set by soft delete), and
  `truncate_before BIGINT NOT NULL DEFAULT 0`.
- The row `stream_id = 0`, `stream_name = '$all'` is the seeded global log; it must be excluded
  from stream listings and from the category list (its category is the text `$all`).
- `events` holds one row per event (`event_id UUID PRIMARY KEY`, `event_type`, `data`,
  `metadata`, `causation_id`, `correlation_id`, `created_at`).
- `stream_events` is the junction: every event has one row for its source stream (where
  `stream_version` is its per-stream version) and one row for `$all` (`stream_id = 0`, where
  `stream_version` **is the global position**), plus one row per link target. Each junction row
  carries `original_stream_id` and `original_stream_version`. A hard delete removes every
  junction row and the `events` row, so an event either has its `$all` row or does not exist.
- Category values can be the empty string (a stream named `-x` has category `''`) and a name
  without a dash is its own category. The library and the endpoints report these as they are.

Per-stream reads (`readStreamForwardSQL`) do not join the `$all` row and therefore return
`globalPosition = 0` on every event; the SQL comment in `SQL.hs` records this. The
`/streams/<name>/events` endpoint inherits that quirk and the user guide must say so.

### The metrics server as it exists

`kiroku-metrics/src/Kiroku/Metrics/Server.hs` builds one WAI `Application` (a plain function
value `Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived` that any Haskell web
server can run). `combinedApp cfg m deps mProvider wsApp` hands WebSocket upgrades to `wsApp` and
everything else to `httpApp cfg m deps mProvider`, which pattern-matches on `pathInfo req` (the
URL path split on `/`, each segment percent-decoded — so a stream name written `orders%2F1`
arrives as the single segment `orders/1`). Existing routes: `["metrics","prometheus"]`,
`["metrics"]`, `["metrics", name]`, `["subscriptions"]`, `["subscriptions", name]`,
`["health"]`, `["health","live"]`, `["health","ready"]`, `["ws"]`, and a catch-all that responds
`404 {"error":"Not found"}`. That legacy string-valued error shape is published and frozen; the
new routes use the structured envelope instead, and the catch-all keeps its exact body.

Starters: `startMetricsServer cfg m deps` (rejecting WebSocket stub, no subscription provider),
`startMetricsServerWith cfg m deps wsApp`, `startMetricsServerWith' cfg m deps mProvider wsApp`
(the general one today), `startMetricsServerWithStore cfg m store deps` (allocates the
WebSocket state and installs `websocketApp cfg m store wsState`), `stopMetricsServer`,
`withMetricsServer`, `withMetricsServerWithStore`, and `withMetricsServerSubscriptions`. Every
one of these keeps its exact signature and behavior after this plan.

`kiroku-metrics/src/Kiroku/Metrics/Subscriptions.hs` is the pattern to copy: the server takes a
`type SubscriptionStatusProvider = IO [SubscriptionStatusRow]` closure, and
`storeSubscriptionStatus :: KirokuStore -> SubscriptionStatusProvider` builds it from a store.
`kiroku-metrics/src/Kiroku/Metrics/JSON.hs` exports
`jsonResponse :: Status -> LBS.ByteString -> Response` (sets `Content-Type: application/json`).
`kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` exports `recordedEventToJSON :: RecordedEvent -> Value`,
the published camelCase event object (`eventId`, `eventType`, `streamVersion`, `globalPosition`,
`originalStreamId`, `originalVersion`, `payload`, `metadata`, `causationId`, `correlationId`,
`createdAt`); the WebSocket already reads history with `runStoreIO store (readAllForward …)`.

Tests live in `kiroku-metrics/test/`: `Main.hs` registers `CollectorSpec`, `IntegrationSpec`,
`ServerSpec`, `WebSocketSpec`, `SubscriptionsSpec`. `Test/ServerSpec.hs` boots a real store,
starts the server on port 0, and asserts each endpoint with `http-client`;
`Test/SubscriptionsSpec.hs` also shows a database-free route test using
`Network.Wai.Handler.Warp.testWithApplication (pure app)`. The self-verifying example is
`kiroku-metrics/example/Main.hs` (cabal flag `example`, off by default; run with
`cabal run -fexample kiroku-metrics-example`). The user guide is `docs/user/metrics.md`, indexed
from `docs/user/README.md`; the library read guide is `docs/user/reading-events.md`.

### The wire conventions this plan follows

The keiro-ui initiative's shared conventions are in `mori://shinzui/keiro-ui`, file
`docs/architecture/inspection-api-conventions.md` (artifact-level URI pending; on this machine
`/Users/shinzui/Keikaku/bokuno/keiro-ui/docs/architecture/inspection-api-conventions.md`). The
rules restated here so the plan is self-contained: new surfaces are HTTP + JSON served by an
embeddable WAI `Application` in a sister package; all new fields are `snake_case`; published
shapes are frozen (the camelCase keys inside the event object stay, and a new key on that object
is snake_case); position-based reads use cursor pagination with an exclusive `from` and a
`limit` in, `items` and `next_cursor` out, `next_cursor` omitted on the last page, cursors
opaque to clients; new endpoints return errors as
`{"error":{"code":"<snake_case>","message":"<sentence>","details":{...}}}` with `details`
optional and codes per project; no authentication or CORS is designed here.

### ADRs consulted

Local (`docs/adr/`):

- [ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md) — `RecordedEvent`
  carries only `originalStreamId`; names are resolved on demand with `lookupStreamNames` (one
  round trip per batch of distinct ids) because putting the name on every read row measured
  ~13% on `$all` pages. Every fan-in endpoint here resolves names that way, server-side.
- [ADR-3](../adr/0003-dedicated-kiroku-schema.md) — all objects live in the `kiroku` schema and
  statements use unqualified names resolved through the connection `search_path`; the new SQL
  follows suit.
- [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) — structural checks and
  controlled workloads are the authoritative performance gates. The new statements are off every
  hot path (they are never used by append, subscription, or the existing readers) and no existing
  statement changes; the existing structural tests still run as part of the store suite.
- [ADR-6](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md) —
  published surfaces are frozen and grow only additively; this plan applies the same discipline
  to HTTP shapes, and its final milestone records that in a new ADR.

Cross-repository (exact canonical handles verified with `mori path`):

- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1` — every inspection endpoint lives in the
  project that owns the concept; store browsing belongs to Kiroku.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4` — inspection surfaces live in sister packages
  that depend on the core library, never the reverse; `kiroku-store` gains no web dependency.

Related requests, all out of scope here: `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1`
(bounded fan-in replay windows), IR-9 (dead-letter reads), IR-10 (durable checkpoints over
HTTP, planned in `docs/plans/87-serve-durable-subscription-checkpoints-over-http.md`), IR-11
(CORS), and `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-13` (an ADR on
wire-format stability; the ADR written in M4 covers the browse endpoints and may be extended by
IR-13's own plan). MasterPlan 5
(`docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md`) explicitly deferred
"a pull-based historical event query API over HTTP (paginated `GET /events`)"; this plan is that
follow-up.


## Plan of Work

### Milestone 0 — prove read work before promoting the SQL

The subsequent range experiment is retained in
[its evidence README](../../kiroku-store/bench/results/mp13-ep3-range/README.md).
Use `--scope range-streams` with the same diagnostic to reproduce its 400 refined
cases. Ordinary TypeID seeks improve, but generic-plan scaling and ICU membership
failures still reject promotion. The index write cost requested by the user has
not been measured; HOT eligibility is not proof of zero event-append overhead.

**Current state (2026-10-10): executed, promotion rejected.** Run the retained
[diagnostic](../../scripts/mp13-browse-sql-prototype.py) as described in the
[evidence README](../../kiroku-store/bench/results/mp13-ep3-prefix/README.md).
The user-directed category follow-up is retained in
[its evidence README](../../kiroku-store/bench/results/mp13-ep3-category/README.md).
Run the same diagnostic with `--scope category-streams` to reproduce it. It
proves category equality can use the existing index while category-sized work
remains. Category-first browsing is the investigation priority, and arbitrary
prefix search remains a valid requirement. No API shape or new index is selected.
Exit 2 is the expected rejection, not a passing performance gate. Do not begin
M1 with the SQL sketch below. Resolve the no-migration/prefix/collation conflict
through an explicit reviewed design first; leave the remaining milestones open.

Add focused cases to `kiroku-store/test/Test/PerformanceStructure.hs` using the existing
EXPLAIN machinery. Check first and later pages under both forced generic and custom plans.
Cover a selective prefix, an absent prefix, many streams per category and a late cursor.
Assert the cursor seek is an index condition and retain rows examined and buffers, not only
the presence of an Index Scan or the output LIMIT. The existing name index does not by itself
make `starts_with` bounded: sparse/absent matches may scan the remaining relation. This is
an unresolved promotion gate, not a promise that the prototype is fast.

First try existing-index statement variants without changing the published prefix semantics,
ordering or database collation. If sparse-prefix work still scales with total history, do not
ship the prototype or add an index silently: record the failing plan and revise this design
with an explicit read/write trade-off before continuing. A new index needs separate append
cost review under ADR-15. No benchmark result exists yet. A LIMIT or page-size test alone
cannot pass this milestone.

Add a regression fixture with both prefix and cursor present and different (`orders-`,
`orders-1`), plus neither and each singly, to catch swapped Hasql parameters. Test literal
`%` and `_`, Unicode/collation ordering, and the valid `$all-x` application stream.
Enumeration excludes stream id 0, not an otherwise valid category label.
The no-hook GetEvent path reuses `decodeReadEvents` and must not traverse/wrap a vector.

### Milestone 1 — the three `kiroku-store` read primitives

Scope: after this milestone a Haskell consumer can call `listStreams`, `listCategories`, and
`getEvent` through the public `Store` effect, the PostgreSQL interpreter serves them, a mock
interpreter can implement them without a database, and the store package and its dependants compile with their versions unchanged until plan 96. Nothing in `kiroku-metrics` changes yet.

**SQL** (`kiroku-store/src/Kiroku/Store/SQL.hs`). Add three statements to the export list, after
`lookupStreamNamesStmt`, and define them in the "Read Statements" section:

```haskell
-- | Page application streams in name order. Params: (exclusive name cursor, prefix, limit).
listStreamsStmt :: Statement (Maybe Text, Maybe Text, Int32) (Vector StreamInfo)
listStreamsStmt =
    preparable
        listStreamsSQL
        ( contrazip3
            (E.param (E.nullable E.text))
            (E.param (E.nullable E.text))
            (E.param (E.nonNullable E.int4))
        )
        (D.rowVector streamInfoRow)

listStreamsSQL :: Text
listStreamsSQL =
    """
    SELECT stream_id, stream_name, stream_version, created_at, deleted_at, truncate_before
    FROM streams
    WHERE stream_id <> 0
      AND ($1::text IS NULL OR stream_name > $1)
      AND ($2::text IS NULL OR starts_with(stream_name, $2))
    ORDER BY stream_name ASC
    LIMIT $3
    """

-- | Page distinct categories in name order with a loose index scan.
-- Params: (exclusive category cursor, limit).
listCategoriesStmt :: Statement (Maybe Text, Int32) (Vector Text)
listCategoriesStmt =
    preparable
        listCategoriesSQL
        (contrazip2 (E.param (E.nullable E.text)) (E.param (E.nonNullable E.int4)))
        (D.rowVector (D.column (D.nonNullable D.text)))

listCategoriesSQL :: Text
listCategoriesSQL =
    """
    WITH RECURSIVE next_category AS (
      SELECT (
        SELECT s.category FROM streams s
        WHERE s.stream_id <> 0 AND ($1::text IS NULL OR s.category > $1)
        ORDER BY s.category ASC LIMIT 1
      ) AS category
      UNION ALL
      SELECT (
        SELECT s.category FROM streams s
        WHERE s.stream_id <> 0 AND s.category > n.category
        ORDER BY s.category ASC LIMIT 1
      )
      FROM next_category n
      WHERE n.category IS NOT NULL
    )
    SELECT category FROM next_category WHERE category IS NOT NULL LIMIT $2
    """

-- | Fetch one event by id as it appears in the global $all log.
getEventStmt :: Statement UUID (Maybe RecordedEvent)
getEventStmt =
    preparable
        getEventSQL
        (E.param (E.nonNullable E.uuid))
        (D.rowMaybe recordedEventRow)

getEventSQL :: Text
getEventSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM events e
    JOIN stream_events se ON se.event_id = e.event_id AND se.stream_id = 0
    WHERE e.event_id = $1
    """
```

The SQL above is a correctness prototype, not a performance-approved implementation.
The parameter order is cursor, prefix, limit; the public API order remains prefix, cursor, limit.
Before promotion, split nullable cursor predicates into first-page and after-cursor statement
variants when necessary to keep the cursor in Index Cond under generic prepared plans. `starts_with` is a built-in PostgreSQL function
(since version 11); it does no wildcard interpretation. The recursive CTE emits one row per
distinct category, each found by a single ordered index probe past the previous one; PostgreSQL
evaluates a recursive CTE lazily, so the outer `LIMIT` stops the recursion after the page is
full. In `getEventSQL` the `stream_id = 0` join picks the event's `$all` row, whose
`stream_version` is the global position, matching the column layout of `readAllForwardSQL`.

**Effect** (`kiroku-store/src/Kiroku/Store/Effect.hs`). Add three constructors to `data Store`,
placed after `LookupStreamNames` with Haddock in the style of the neighbours:

```haskell
    {- | Page application streams in ascending name order. The first argument is
    an optional name prefix (exact, no wildcards); the second is an exclusive
    name cursor ('Nothing' = from the first name); the third caps the page. Never
    returns the reserved @$all@ row. Live and soft-deleted streams are both
    included; hard-deleted streams are gone. Surfaced as 'Kiroku.Store.Read.listStreams'.
    -}
    ListStreams :: Maybe Text -> Maybe StreamName -> Int32 -> Store m (Vector StreamInfo)
    {- | Page the distinct categories present in @streams.category@ in ascending
    order, from an exclusive cursor ('Nothing' = from the first). Excludes the reserved stream row (stream_id 0), not a legitimate category
    named @$all@ derived from an application stream such as @$all-x@. Surfaced as 'Kiroku.Store.Read.listCategories'.
    -}
    ListCategories :: Maybe CategoryName -> Int32 -> Store m (Vector CategoryName)
    {- | Fetch one event by id as it appears in the global @$all@ log:
    @streamVersion == globalPosition@ and the @original*@ fields name its source
    stream. 'Nothing' when no such event exists (never appended, or hard-deleted).
    Surfaced as 'Kiroku.Store.Read.getEvent'.
    -}
    GetEvent :: EventId -> Store m (Maybe RecordedEvent)
```

Interpret them in `runStorePool`, next to the `LookupStreamNames` branch:

```haskell
    ListStreams prefix after limit ->
        usePool (store ^. #pool) $
            Session.statement (fmap (\(StreamName n) -> n) after, prefix, limit) SQL.listStreamsStmt
    ListCategories after limit ->
        fmap (V.map CategoryName) $
            usePool (store ^. #pool) $
                Session.statement (fmap (\(CategoryName c) -> c) after, limit) SQL.listCategoriesStmt
    GetEvent (EventId eid) -> do
        found <- usePool (store ^. #pool) $ Session.statement eid SQL.getEventStmt
        decoded <- decodeReadEvents (store ^. #storeSettings) (maybe V.empty V.singleton found)
        pure (decoded V.!? 0)
```

`GetEvent` must use `decodeReadEvents` exactly as the other readers do, so a consumer that
installs a payload-decoding hook sees the decoded event by id too.

**Wrappers** (`kiroku-store/src/Kiroku/Store/Read.hs`). Export and define, with Haddock that
repeats the exclusive-cursor rule and the `$all` exclusion in plain words:

```haskell
listStreams ::
    (HasCallStack, Store :> es) =>
    Maybe Text ->        -- ^ optional exact name prefix
    Maybe StreamName ->  -- ^ exclusive name cursor; Nothing = from the first name
    Int32 ->             -- ^ page size
    Eff es (Vector StreamInfo)
listStreams prefix after limit = send (ListStreams prefix after limit)

listCategories ::
    (HasCallStack, Store :> es) =>
    Maybe CategoryName -> Int32 -> Eff es (Vector CategoryName)
listCategories after limit = send (ListCategories after limit)

getEvent :: (HasCallStack, Store :> es) => EventId -> Eff es (Maybe RecordedEvent)
getEvent eid = send (GetEvent eid)
```

Document in `listStreams`'s Haddock that to page you pass the last returned `name` back as the
cursor, that a prefix of `"orders-"` is exactly "streams in category `orders`" except for a
stream named exactly `orders`, and that the library does not validate `limit` (PostgreSQL rejects
a negative `LIMIT` and that surfaces as `ConnectionError`, like every other read).

**Tests.** Create `kiroku-store/test/Test/BrowseReads.hs` (`spec :: Spec`, `around withTestStore`)
with these cases, each building its own fixture with `appendToStream` and `makeEvent`:

- listing an empty store returns an empty vector and never includes `$all`;
- after creating `orders-1`, `orders-2`, `shipments-1`, and a dash-less `singleton`,
  `listStreams Nothing Nothing 10` returns exactly those four in ascending name order, each with
  the right `version`; `listStreams (Just "orders-") Nothing 10` returns the two orders streams;
  `listStreams Nothing Nothing 2` returns the first two and `listStreams Nothing (Just lastName) 2`
  returns the rest; a soft-deleted stream (`softDeleteStream`) still appears with `deletedAt`
  set; a stream with `setStreamTruncateBefore` shows the marker;
- `listCategories Nothing 10` returns `orders`, `shipments`, `singleton` once each in order even
  when a category has several streams; `listCategories (Just (CategoryName "orders")) 10` returns
  the categories after it; `listCategories Nothing 1` returns only the first;
- `getEvent` on an appended event returns `Just` with `globalPosition` equal to the append's
  `globalPosition`, `streamVersion` equal to that same position, `originalStreamId` equal to the
  stream's `lookupStreamId`, and `originalVersion 1`; a random `EventId` returns `Nothing`; an
  event linked into a second stream with `linkToStream` still returns its source position; after
  `hardDeleteStream` of the source stream the id returns `Nothing`;
- with `withTestStoreSettings` installing a `decodeHook` that rewrites `eventType` to
  `"decoded"` and returns `Right rewrittenEvent`, `getEvent` returns the rewritten type;
  a hook returning `Left failure` yields `EventDecodeFailed`, never `Nothing` or partial data.

Create `kiroku-store/test/Test/BrowseReadsMock.hs` modelled on
`Test/VisibleGlobalHeadPositionMock.hs`: an `interpret_` that answers `ListStreams`,
`ListCategories`, and `GetEvent` from in-memory fixtures and counts calls, proving each wrapper
dispatches to its constructor exactly once with the arguments given. Register both modules in
`kiroku-store/test/Main.hs` and in the `other-modules` list of the `kiroku-store-test` stanza in
`kiroku-store/kiroku-store.cabal`.

**Changelog only.** Do not edit `version:` in any `.cabal` file and do not touch any
dependency bound; plan 96 (EP-7 of MasterPlan 13) assigns the cohort's versions (forecast:
`kiroku-store` 0.11.0.0, because the closed `Store` GADT gains constructors) and moves every
dependant's bound in one release commit. Add a `## Unreleased` heading at the top of
`kiroku-store/CHANGELOG.md` if none exists (plans 89 and 94 write under the same heading; keep
exactly one) with a `### Breaking Changes` bullet (the `Store` effect gains `ListStreams`,
`ListCategories`, `GetEvent`; exhaustive custom and mock interpreters must handle them) and a
`### New Features` bullet naming the three wrappers. Because in-tree packages resolve against
their local versions, `cabal build all` stays satisfiable with every version untouched.

Acceptance for M1: `cabal build all` succeeds with no warnings, and
`cabal test kiroku-store-test --test-options='--match "browse reads"'` passes every case above.

### Milestone 2 — the browse WAI application in `kiroku-metrics`

Scope: a new module turns the primitives into the six-plus-one HTTP routes, fully testable with a
mock interpreter and no database. It is not yet mounted in the server.

Create `kiroku-metrics/src/Kiroku/Metrics/Browse.hs` exporting:

```haskell
module Kiroku.Metrics.Browse (
    StoreBrowser (..),
    storeBrowser,
    storeBrowserWith,
    BrowseLimits, BrowseLimitsError (..), mkBrowseLimits, defaultLimit, maxLimit,
    defaultBrowseLimits,
    ReadDirection (..),
    browseApp,
    streamInfoToJSON,
) where
```

The resolved-name event encoder does not live here. Add it to
`kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`, exported beside `recordedEventToJSON`, unless
plan 94 has already added it (`grep -n recordedEventToJSONResolved kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`):

```haskell
{- | 'recordedEventToJSON' plus exactly one snake_case key, @original_stream_name@:
the source stream's name from the supplied lookup, or @null@ when the id is not
in it. Shared by the REST browse items (plan 88) and the @event@ frames (plan 94)
so a client keeps one decoder. The camelCase keys are frozen (ADR-9).
-}
recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value
```

Error responses in this module are built with `errorResponse` from `Kiroku.Metrics.JSON`
(created by plan 90); do not add a browse-specific envelope helper.

with these definitions (GHC2024 already enables `RankNTypes`):

```haskell
-- | How the endpoints reach the store: a runner for Store-effect programs.
data StoreBrowser = StoreBrowser
    { runStoreRead :: forall a. Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)
    , limits :: !BrowseLimits
    }

data BrowseLimits = BrowseLimits
    { defaultLimit :: !Int  -- ^ used when the request has no @limit@ (100)
    , maxLimit :: !Int      -- ^ largest accepted @limit@ (1000)
    }

data BrowseLimitsError = InvalidBrowseLimits !Int !Int
    deriving stock (Eq, Show)

mkBrowseLimits :: Int -> Int -> Either BrowseLimitsError BrowseLimits
mkBrowseLimits def cap
    | 1 <= def && def <= cap && cap <= 1000 = Right (BrowseLimits def cap)
    | otherwise = Left (InvalidBrowseLimits def cap)

defaultBrowseLimits :: BrowseLimits
defaultBrowseLimits = BrowseLimits{defaultLimit = 100, maxLimit = 1000}

storeBrowser :: KirokuStore -> StoreBrowser
storeBrowser = storeBrowserWith defaultBrowseLimits

storeBrowserWith :: BrowseLimits -> KirokuStore -> StoreBrowser
storeBrowserWith lims store = StoreBrowser{runStoreRead = runStoreIO store, limits = lims}

data ReadDirection = ReadForward | ReadBackward
    deriving stock (Eq, Show)

browseApp :: StoreBrowser -> Application
```

`browseApp` dispatches on `requestMethod req` and `pathInfo req`:

| Method and path | Behavior |
| --- | --- |
| `GET /streams` | `listStreams prefix after (limit + 1)`; items are `streamInfoToJSON`; `next_cursor` is the last returned `name` (a JSON string). Query: `prefix`, `from`, `limit`. |
| `GET /streams/<name>` | `getStream`; 200 with one `streamInfoToJSON` object, or 404 `stream_not_found`. |
| `GET /streams/<name>/events` | `getStream` first (404 `stream_not_found` if `Nothing`); then `readStreamForward`/`readStreamBackward name (StreamVersion from) (limit + 1)`; `next_cursor` is the last item's `streamVersion` (a JSON number). Query: `from`, `limit`, `direction`. |
| `GET /categories` | `listCategories after (limit + 1)`; items are `{"name": …}`; `next_cursor` is the last name. Query: `from`, `limit`. |
| `GET /categories/<name>/events` | `readCategory (CategoryName name) (GlobalPosition from) (limit + 1)`; `next_cursor` is the last item's `globalPosition`. Query: `from`, `limit`. |
| `GET /events` | `readAllForward`/`readAllBackward (GlobalPosition from) (limit + 1)`; `next_cursor` is the last item's `globalPosition`. Query: `from`, `limit`, `direction`. |
| `GET /events/<event_id>` | `getEvent`; 200 with one event object, 404 `event_not_found`, or 400 `invalid_event_id` when the segment is not a UUID. |
| `HEAD` on each GET path | Same status and headers as GET, with no body. |
| any other method on these paths | 405 `method_not_allowed`, `Allow: GET, HEAD`. |
| any other path under these prefixes | 404 `not_found` (structured envelope). |

Query parsing rules, implemented once in a small pure function that returns
`Either (Status, code, message, details) parsed`: `limit` must parse as a decimal integer in
`[1, maxLimit]`, defaulting to `defaultLimit`; a numeric `from` must parse as a non-negative
`Int64`, defaulting to `0` (which the library reads as "from the start" forward and "from the
newest" backward); a textual `from` is taken verbatim; `direction` must be `forward` (default) or
`backward`; unknown query parameters are ignored. Any violation is 400 `invalid_query_parameter`
with `details` `{"parameter": "<name>", "value": "<raw>", "reason": "<what was expected>"}`.
Before touching the store, a stream name is checked with `validateStreamName`; a failure is 400
`invalid_stream_name` with `details` `{"stream_name": …}` (this is how `/streams/$all/events`
is refused; the global log is `/events`).

Every event-returning route runs one `Eff` program that reads the page, trims the over-fetched row before collecting distinct
`originalStreamId`s with `Data.Set`, calls `lookupStreamNames` at most once (zero times for an
empty page), and returns both; the handler emits items with
`recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value` (from
`Kiroku.Metrics.WebSocket`), which is `recordedEventToJSON` with one added key
`"original_stream_name"` (the resolved name or `null`). `streamInfoToJSON :: StreamInfo -> Value`
emits `{"stream_id", "name", "category", "version", "created_at", "deleted_at", "truncate_before"}`
with `category` computed by `categoryName`, `deleted_at` `null` when live, and `truncate_before`
`0` by default. Every error body is built with
`errorResponse :: Status -> Text -> Text -> Maybe Value -> Response` from `Kiroku.Metrics.JSON`.

Store failures: a `Left (ConnectionError msg)` from the runner becomes 503 `store_unavailable`
with a fixed sanitized message, never `msg`; `EventDecodeFailed` becomes 500
`event_decode_failed`, and any other `Left` becomes 500 `store_error` with a fixed message. Use plan 90's storeErrorResponse rather than duplicating this mapping.

Add `effectful-core (align with kiroku-store's verified supported range at implementation)` to the library `build-depends` in
`kiroku-metrics/kiroku-metrics.cabal` (for `Eff`, `IOE`, and `Error`), list
`Kiroku.Metrics.Browse` under `exposed-modules`, and re-export it from `Kiroku.Metrics`.

**Tests.** Create `kiroku-metrics/test/Test/BrowseSpec.hs` with a `describe "Kiroku.Metrics.Browse (mock store)"`
block. Build a fixture of, say, three streams (`orders-1` with positions 1–3, `orders-2` with
position 4, `shipments-1` with position 5) as a pure `[RecordedEvent]` plus `[StreamInfo]`, and a
mock interpreter `mockStore :: Fixture -> Eff (Store : es) a -> Eff es a` (`interpret_`) that
answers `ListStreams`, `ListCategories`, `GetEvent`, `GetStream`, `ReadStreamForward`,
`ReadStreamBackward`, `ReadAllForward`, `ReadAllBackward`, `ReadCategoryForward`, and
`LookupStreamNames` from the fixture, honouring exclusive cursors and limits, and `error`s on
anything else. The `StoreBrowser` under test is
`StoreBrowser{runStoreRead = runEff . runErrorNoCallStack . mockStore fixture, limits = defaultBrowseLimits}`,
served with `Warp.testWithApplication (pure (browseApp browser))` and queried with `http-client`.
Assert, decoding bodies with `aeson`:

- `/streams?limit=2` returns two items and `next_cursor` equal to the second name; echoing it as
  `from` returns the remaining stream with no `next_cursor` key; `/streams?prefix=orders-` returns
  two; `/streams/orders-1` returns the summary with `category` `orders`;
- `/streams?limit=0`, `limit=abc`, `limit=1001`, `from=-1` on `/events`, and
  `direction=sideways` are 400 `invalid_query_parameter` with the named `parameter`;
- `/streams/$all/events` is 400 `invalid_stream_name`; `/streams/nope` and `/streams/nope/events`
  are 404 `stream_not_found`;
- `/streams/orders-1/events?limit=2` returns versions 1 and 2 with `next_cursor` 2,
  `from=2&limit=2` returns version 3 with no cursor, and `direction=backward` returns 3, 2, 1;
- `/categories` returns `orders` then `shipments`; `/categories/orders/events` returns positions
  1–4 each with `original_stream_name` starting `orders-`;
- `/events?from=3&limit=100` returns positions 4 and 5 only; `/events?direction=backward&limit=2`
  returns 5, 4 with `next_cursor` 4;
- `/events/<id of position 5>` returns that event with `original_stream_name` `shipments-1`;
  `/events/not-a-uuid` is 400 `invalid_event_id`; a random UUID is 404 `event_not_found`;
- `POST /streams` is 405 `method_not_allowed`; `/streams/a/b/c` is 404 `not_found` in the
  structured envelope;
- a browser whose runner returns `Left (ConnectionError "boom")` yields 503 `store_unavailable`.

Add `Test.BrowseSpec` to `other-modules`, register it in `kiroku-metrics/test/Main.hs`, and add
`effectful-core` to the test-suite `build-depends`.

Acceptance for M2: `cabal test kiroku-metrics-test --test-options='--match "Browse"'` passes
without a database being touched by these cases (the shared PostgreSQL still starts because
`main` wraps the whole run).

### Milestone 3 — mounting the routes in the server

Scope: the store-aware server serves the new routes; every existing starter keeps its signature
and behavior; end-to-end tests prove the acceptance criteria over real HTTP against a real store.

Plan 87 (EP-2, a hard dependency of this plan) has already added to
`kiroku-metrics/src/Kiroku/Metrics/Server.hs` the record and the general functions:

```haskell
data ServerProviders = ServerProviders
    { webSocketServer :: !WS.ServerApp
    , subscriptionStatus :: !(Maybe SubscriptionStatusProvider)
    , checkpointInventory :: !(Maybe CheckpointInventoryProvider)
    }
defaultServerProviders :: ServerProviders
storeServerProviders :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> IO ServerProviders
startMetricsServerWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> IO MetricsServer
withMetricsServerWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> (MetricsServer -> IO a) -> IO a
combinedAppWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> Application
httpAppWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> Application
```

with every legacy starter delegating to them, `combinedAppWithProviders` wrapped in
`corsMiddleware cfg.cors` (plan 90's invariant), and `httpAppWithProviders` holding the router.
Confirm with `grep -n "ServerProviders\|WithProviders" kiroku-metrics/src/Kiroku/Metrics/Server.hs`
before starting; if the record is missing, stop and implement plan 87 first.

Add one field, `browser :: !(Maybe StoreBrowser)`, with a Haddock line ("Backs `/streams`,
`/categories`, and `/events`"). Set it to `Nothing` in `defaultServerProviders`, to
`Just (storeBrowser store)` in `storeServerProviders`, and to `Just (storeBrowser store)` in the
record `startMetricsServerWithStore` builds (subscription status stays `Nothing` there, exactly
as before, so `/subscriptions` on that starter keeps its published 404). Plan 89 adds
`deadLetters` the same way, and plan 95 later adds `webSocketChannels`; never add a second
record. In `httpAppWithProviders` add, before the `["ws"]` arm:

```haskell
        ("streams" : _) -> browseRoute
        ("categories" : _) -> browseRoute
        ("events" : _) -> browseRoute
```

with

```haskell
    browseRoute = case providers.browser of
        Just browser -> browseApp browser req respond
        Nothing ->
            respond $
                errorResponse
                    status404
                    "store_browsing_not_configured"
                    "This server was started without a store browser; use startMetricsServerWithStore or storeServerProviders."
                    Nothing
```

The catch-all arm and its `{"error":"Not found"}` body do not change.

**Tests.** Extend `kiroku-metrics/test/Test/BrowseSpec.hs` with a
`describe "Kiroku.Metrics.Browse (end to end)"` block using `withMigratedTestDatabase`,
`withStore`, `newKirokuMetrics store`, and `withMetricsServerWithStore (defaultConfig{port = 0})`
(sleep 200 ms after start, as the other specs do). Append three events to `orders-1`, two to
`orders-2`, one to `shipments-1`, capturing the first `AppendResult` and reading back one event's
id with `readStreamForward`. Assert over real HTTP:

- `/streams?prefix=orders-&limit=1` is 200 with one item and `next_cursor` `"orders-1"`; the
  follow-up `from=orders-1&limit=1` returns `orders-2` and no `next_cursor` (IR-8 acceptance 1);
- `/streams/orders-1/events?limit=100` returns three items in version order using the published
  keys (`eventId`, `eventType`, `streamVersion`, …) and `direction=backward` returns them
  reversed (acceptance 2);
- `/categories` returns exactly `orders` and `shipments` (acceptance 3);
- `/events?from=3&limit=100` returns the items with `globalPosition > 3`, and every item's
  `original_stream_name` equals the stream it was appended to (acceptance 4);
- `/events/<known id>` is 200 and `/events/<fresh UUID>` is 404 with `error.code`
  `event_not_found` (acceptance 5);
- `/nope` still returns exactly the body `{"error":"Not found"}`, `/metrics` and
  `/health/ready` are still 200, and a server started with plain `startMetricsServer` answers
  `/streams` with 404 `store_browsing_not_configured` (acceptance 7);
- a server started with `startMetricsServerWithProviders` and `storeServerProviders` answers
  `/subscriptions` with 200 `[]` and `/streams` with 200.

Acceptance for M3: `cabal test kiroku-metrics-test` passes in full (the pre-existing specs prove
nothing regressed), and a manual `curl` against a server started by the example or a GHCi
session shows the transcripts that Milestone 4 pastes into the guide.

### Milestone 4 — documentation, example, version metadata, and ADR

Scope: an operator can learn every route from `docs/user/metrics.md`, a library user can learn
the primitives from `docs/user/reading-events.md`, the example proves the routes, the package
carries the right version, and the durable decision is recorded as an ADR.

`docs/user/metrics.md`: add a "Browsing the store over HTTP" entry to the Contents list and a
section of that name after "Subscription status over HTTP". Open with how browsing is enabled
(`withMetricsServerWithStore` serves it; `storeServerProviders` with
`withMetricsServerWithProviders` serves it together with `/subscriptions`; `browser = Nothing`
disables it; `storeBrowserWith` changes the limits). Then, per endpoint, a `bash` block with the
`curl` and a `json` block with the actual response captured from the example or test run, for
`GET /streams`, `GET /streams/<name>`, `GET /streams/<name>/events` (forward and backward, and a
sentence that `globalPosition` is `0` in per-stream reads because the library's per-stream SQL does
not join the global log), `GET /categories`, `GET /categories/<name>/events`, `GET /events`, and
`GET /events/<event_id>` (200 and the 404 envelope). Follow with a "Pagination" paragraph
(exclusive `from`, `limit` default 100 and maximum 1000, `items`/`next_cursor`, omission on the
last page, cursors are opaque: echo them, never compute them), a "Stream summary fields" table, a
sentence that the event object is the published WebSocket shape plus `original_stream_name`, an
"Error envelope" subsection with a table of every code (`invalid_query_parameter`,
`invalid_stream_name`, `invalid_event_id`, `stream_not_found`, `event_not_found`,
`method_not_allowed`, `not_found`, `store_browsing_not_configured`, `store_unavailable`,
`store_error`) and its HTTP status, and a note that stream names containing `/` are written
percent-encoded (`orders%2F1`). Extend the deployment-assumption call-out at the top to name the
browse endpoints, and add a "See Also" link to `reading-events.md`. Update the summary line for
`metrics.md` in `docs/user/README.md` to mention browsing.

`docs/user/reading-events.md`: add "Listing Streams" and "Listing Categories" subsections after
"Stream Metadata" and a "Fetching One Event By Id" subsection before "Resolving Source Stream
Names", each with the signature, the exclusive-cursor paging idiom, and a short `haskell` example.

`kiroku-metrics/example/Main.hs`: after the HTTP checks, add checks that `GET /streams` lists
`orders-1`, `GET /events?from=0&limit=10` returns the appended events with resolved
`original_stream_name`, and `GET /events/<eventId of the first item>` is 200; renumber the step
transcript and mirror the new lines in the "Try it" block of `docs/user/metrics.md`.

`kiroku-metrics/CHANGELOG.md`: under the `## Unreleased` heading (plans 90 and 87 opened it),
add "New Features" bullets (the routes, `Kiroku.Metrics.Browse`, `recordedEventToJSONResolved`,
the `browser` field) and an "Other Changes" bullet (`effectful-core` is a new library
dependency; all pre-existing endpoints, frames, and starters unchanged). Do not edit `version:`
or any bound in `kiroku-metrics.cabal`; plan 96 dates the section as 0.3.0.0.

**Capability and request evidence.** Update `docs/capabilities/operational-http-endpoints.md`
(CAP-17): name the browse routes in `description` and the body, add `Kiroku.Metrics.Browse` to
`interface`, add an `evidence` entry for `kiroku-metrics/test/Test/BrowseSpec.hs`, and add a
dated `**Update**` entry to `docs/capabilities/log.md` without changing `generated.at`, `since`,
or `capabilityId`; run `just capabilities-validate`. Update IR-8's body
(`docs/improvement-requests/expose-a-rest-read-api-for-browsing-streams-categories-and-events.md`,
status stays `in_progress`): add an "Implementation Evidence" section naming the primitives,
the module, the routes, the response shapes, the test files, and the example; advance
`timestamp`; add a dated entry to `docs/improvement-requests/log.md`; run the strict validation
command from Concrete Steps.

**ADR.** The record this milestone once planned is withdrawn: ADR-9 already states that
sister-package endpoints wrap supported `Store` APIs through the library, adopt the conventions,
and freeze shipped shapes. Perform the distillation pass instead: reread the Decision Log and
Surprises & Discoveries, and if something not covered by ADR-9 is durable (for example the
loose-index-scan category enumeration as a query-shape commitment), allocate a record with
`okf id next docs/adr --profile docs/adr/profile.dhall ADR` and run `just adr-validate`;
otherwise record in Outcomes that no record was needed.

Acceptance for M4: the guide's transcripts match a live server, `cabal run -fexample kiroku-metrics-example`
prints its new steps and exits 0, `just capabilities-validate` and the strict
improvement-request validation pass, and `cabal build all` is warning-free.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`,
inside the project's development shell (the one that provides `cabal`, GHC 9.12.4, and
PostgreSQL for `ephemeral-pg`).

Build everything after each milestone:

```bash
cabal build all
```

Store tests (Milestone 1), focused and then full:

```bash
cabal test kiroku-store-test --test-options='--match "browse reads"'
cabal test kiroku-store-test
```

Expected tail of the focused run:

```text
browse reads
  lists application streams in name order and never $all [✔]
  filters by exact prefix [✔]
  pages with an exclusive name cursor [✔]
  ...
browse reads mock
  dispatches listStreams, listCategories, and getEvent once each [✔]

Finished in 3.21 seconds
N examples, 0 failures
```

Metrics tests (Milestones 2 and 3), focused and then full:

```bash
cabal test kiroku-metrics-test --test-options='--match "Browse"'
cabal test kiroku-metrics-test
```

Manual transcript capture for the guide (Milestone 4): run the example, which prints the port it
bound, or start a server from GHCi with `cabal repl kiroku-metrics` and the wiring shown in the
guide; then:

```bash
curl -s 'http://127.0.0.1:9091/streams?prefix=orders-&limit=50' | jq .
curl -s 'http://127.0.0.1:9091/streams/orders-1/events?limit=100' | jq .
curl -s 'http://127.0.0.1:9091/categories' | jq .
curl -s 'http://127.0.0.1:9091/categories/orders/events?limit=100' | jq .
curl -s 'http://127.0.0.1:9091/events?from=0&limit=100' | jq .
curl -s 'http://127.0.0.1:9091/events/<event_id>' | jq .
curl -s -i 'http://127.0.0.1:9091/events/00000000-0000-0000-0000-000000000000'
```

The last command should show `HTTP/1.1 404 Not Found` and the body

```json
{"error":{"code":"event_not_found","message":"No event with id 00000000-0000-0000-0000-000000000000 exists in this store.","details":{"event_id":"00000000-0000-0000-0000-000000000000"}}}
```

Example (Milestone 4):

```bash
cabal run -fexample kiroku-metrics-example
```

Bundle validation (Milestone 4):

```bash
just capabilities-validate
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
```

The strict run prints "missing profile-recommended field: reviews" lines for several requests;
they are benign, so judge success by the absence of any other error.

Commit after each milestone (and more often when a step is complete and the tree builds), using
Conventional Commits and the three trailers (every commit under this plan carries all three):

```text
feat(store): add listStreams, listCategories, and getEvent browse reads

Add three Store-effect read primitives for interactive browsing: a paged,
prefix-filterable stream listing over kiroku.streams, a loose-index-scan
category enumeration, and fetch-one-event-by-id as seen from $all. New SQL
is off every hot path; no existing statement changes.

MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md
ExecPlan: docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md
Intention: intention_01m24kefe1en2vvvek852kwcgv
```

Suggested commit sequence: `feat(store): …` (M1 primitives, tests, and changelog bullets),
`feat(metrics): add the browse WAI application` (M2), `feat(metrics): serve browse routes from
the store-aware server` (M3), `docs(metrics): document the browse endpoints` and
`docs(okf): record browse evidence in CAP-17 and IR-8` (M4). No `chore(release)` commit:
versions and bounds belong to plan 96.


## Validation and Acceptance

The reviewed API, lifecycle and performance obligations in Context and Plan of Work are
mandatory in addition to the route-specific cases below. Historical transcripts are examples,
not evidence that the new tests have run; update counts from actual output at implementation.

The plan is complete when every item below is observed, mapped to IR-8's acceptance list:

1. Against a store holding `orders-1`, `orders-2`, and `shipments-1`,
   `GET /streams?prefix=orders-&limit=1` returns HTTP 200 and a body of the form
   `{"items":[{"stream_id":1,"name":"orders-1","category":"orders","version":3,"created_at":"…","deleted_at":null,"truncate_before":0}],"next_cursor":"orders-1"}`;
   `GET /streams?prefix=orders-&limit=1&from=orders-1` returns `orders-2` with no `next_cursor`
   key at all.
2. `GET /streams/orders-1/events?limit=100` returns the stream's events in ascending
   `streamVersion` with the published camelCase keys plus `original_stream_name`;
   `…&direction=backward` returns them descending, starting at the head.
3. `GET /categories` returns `{"items":[{"name":"orders"},{"name":"shipments"}]}` (no `$all`, no
   `next_cursor` when everything fits).
4. `GET /events?from=4200&limit=100` returns only items with `globalPosition > 4200`, ascending,
   each with a non-null `original_stream_name` matching the stream it was appended to.
5. `GET /events/<existing id>` returns 200 with the event object; `GET /events/<unknown uuid>`
   returns 404 with `{"error":{"code":"event_not_found",…}}`; `GET /events/xyz` returns 400
   with code `invalid_event_id`.
6. `listStreams`, `listCategories`, and `getEvent` are exported from `Kiroku.Store.Read` (and
   thus `Kiroku.Store`), and both `Test.BrowseReadsMock` (store) and the mock block of
   `Test.BrowseSpec` (metrics) pass without any SQL being executed for those cases.
7. Every pre-existing `kiroku-metrics` test passes unchanged; `GET /nope` still returns exactly
   `{"error":"Not found"}`; a server started with `startMetricsServer` (no store) still serves
   `/metrics`, `/health/*`, and the legacy 404s, and answers `/streams` with the
   `store_browsing_not_configured` envelope; `websocketApp` and its frames are untouched.

Beyond the request: `cabal build all` produces no warnings (the repository builds with `-Wall`
and `-Werror=incomplete-patterns`, so any interpreter in the repository that misses the new
constructors fails to compile rather than silently crashing); `just capabilities-validate` and
the strict improvement-request validation pass; the example exits 0; and the MasterPlan
registry shows EP-3 complete.


## Idempotence and Recovery

Every change is additive source code, tests, documentation, and version metadata: no migration,
no data change, no destructive operation. Re-running any build or test command is safe. If a
milestone is interrupted, the tree still builds after each commit because each commit is scoped
to compile on its own (the store primitives before their metrics callers; the browse module
before it is mounted).

If `cabal build all` fails after M1 with an incomplete-patterns error in a package other than
`kiroku-store`, that package has an exhaustive `Store` interpreter; add arms for the three new
constructors there (a mock should `error`, a real interpreter should delegate) and note it in
Surprises & Discoveries. If plan 89 or plan 94 has already opened the `## Unreleased` heading in
a changelog, add bullets under it rather than a second heading. To roll back, revert the
milestone's commits in reverse order; nothing outside the repository observes the change until a
release, which this plan does not perform.

If `okf validate` fails for a bundle, fix the frontmatter it names (the pinned profile is
authoritative) and re-run; the `timestamp` that did not advance or the missing dated log entry
is the usual cause.


## Interfaces and Dependencies

At the end of Milestone 1, `kiroku-store` (its `.cabal` version unchanged in-tree; plan 96
releases it as 0.11.0.0) exports from `Kiroku.Store.Effect` the constructors `ListStreams :: Maybe Text -> Maybe StreamName -> Int32 -> Store m (Vector StreamInfo)`,
`ListCategories :: Maybe CategoryName -> Int32 -> Store m (Vector CategoryName)`, and
`GetEvent :: EventId -> Store m (Maybe RecordedEvent)`; from `Kiroku.Store.Read` the wrappers
`listStreams :: (HasCallStack, Store :> es) => Maybe Text -> Maybe StreamName -> Int32 -> Eff es (Vector StreamInfo)`,
`listCategories :: (HasCallStack, Store :> es) => Maybe CategoryName -> Int32 -> Eff es (Vector CategoryName)`,
and `getEvent :: (HasCallStack, Store :> es) => EventId -> Eff es (Maybe RecordedEvent)`; and from
`Kiroku.Store.SQL` the statements `listStreamsStmt`, `listCategoriesStmt`, and `getEventStmt`.
No new library dependency is added to `kiroku-store`; the SQL uses only `hasql`,
`contravariant-extras`, and built-in PostgreSQL functions (`starts_with`, recursive CTEs).

At the end of Milestone 2, `kiroku-metrics` exports `Kiroku.Metrics.Browse` with
`StoreBrowser(..)` (`runStoreRead`, `limits`), `storeBrowser :: KirokuStore -> StoreBrowser`,
`storeBrowserWith :: BrowseLimits -> KirokuStore -> StoreBrowser`, abstract `BrowseLimits`, `BrowseLimitsError(..)`, `mkBrowseLimits`, `defaultLimit`, `maxLimit`,
`defaultBrowseLimits`, `ReadDirection(..)`, `browseApp :: StoreBrowser -> Application`, and
`streamInfoToJSON :: StreamInfo -> Value`; and `Kiroku.Metrics.WebSocket` additionally exports
`recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value` (shared with
plan 94). Error bodies use `errorResponse` from `Kiroku.Metrics.JSON` (plan 90). New
dependency: `effectful-core (align with kiroku-store's verified supported range at implementation)` (library and test suite). Existing dependencies used:
`wai`, `http-types`, `aeson`, `uuid` (`Data.UUID.fromText` for the event-id segment), `text`,
`containers`, `vector`.

At the end of Milestone 3, plan 87's `ServerProviders` in `Kiroku.Metrics.Server` has one more
field, `browser :: !(Maybe StoreBrowser)`, set to `Nothing` in `defaultServerProviders` and to
`Just (storeBrowser store)` in `storeServerProviders` and in `startMetricsServerWithStore`;
every previously exported name keeps its exact type and observable behavior.

At the end of Milestone 4, `kiroku-metrics/CHANGELOG.md` and `kiroku-store/CHANGELOG.md` carry
this plan's bullets under `## Unreleased`; no `.cabal` version or bound has changed. Publishing
to Hackage and every version number belong to plan 96. CORS (IR-11, plan 90), authentication,
dead-letter reads (IR-9, plan 89), durable checkpoints over HTTP (IR-10, plan 87), the
standalone server and discovery route (plan 95), and bounded replay windows (IR-1) remain outside
this plan.


## Revision Notes

- 2026-09-30: Adopted as EP-3 of MasterPlan 13 (`master_plan` added to the frontmatter) with a
  hard dependency on plan 87, which now introduces the `ServerProviders` record and the
  `...WithProviders` functions this plan first proposed; Milestone 3 adds only the `browser`
  field and the route arms. The error envelope became plan 90's `errorResponse` (the
  browse-specific helper is withdrawn); the resolved-name encoder became
  `recordedEventToJSONResolved` in `Kiroku.Metrics.WebSocket`, shared with plan 94; the stale
  0.9.0.0 and 0.1.1.0 version bumps and every bound edit were withdrawn in favour of
  `## Unreleased` changelog bullets, with plan 96 assigning the versions; the Milestone 4 ADR was
  withdrawn as subsumed by ADR-9 and replaced by CAP-17 and IR-8 evidence steps. The primitives,
  the routes, their wire shapes, and the tests are unchanged.


## API and performance review revision (2026-10-10)

Reviewed against repository HEAD `f1a0209` and the released typed-decoding implementation. Corrected integration contracts and made focused performance evidence a completion gate. Existing authorship history is preserved; this revision records no implemented milestone or accepted performance result. The active requirements above supersede incompatible September design decisions, not published wire contracts.

## SQL promotion implementation revision (2026-10-10)

Executed M0 against the current fourteen migrations on PostgreSQL 18.6. Retained
the failed prefix plans and viable category cursor variants, added a bounded
reproduction script, and recorded the stop before production implementation.
The rejection changes no API, migration, index, version or published wire shape.

## Category-first prototype revision (2026-10-10)

Evaluated the user-requested category-first workflow using existing indexes.
Retained correct-result and EXPLAIN evidence for category and unrelated-inventory
scaling; kept arbitrary prefix search required and all production milestones open.
No new index, migration, collation, API signature or acceptance threshold was added.


## Shared access-cost clarification (2026-10-10)

Recorded the user's requirement to coordinate browsing and prefix-subscription physical
access and cumulative writer cost under ADR-15. No index or implementation milestone is
approved. Plan 88 also records the application's TypeID naming convention and its limits.


## Name-range prototype revision (2026-10-10)

Recorded the completed TypeID/name-range experiment, retained both runs and their
correctness/planner failures, and kept the production gate rejected. Clarified that
proposed stream-index write cost remains unmeasured and can affect event appends.


## Index and benchmark research revision (2026-10-10)

Recorded disposable replacement footprint/read evidence and verified cleanup,
Kenshou source/run coverage, matched-harness instrumentation gaps, and the
unchanged shared access/cumulative write-cost obligation. No migration or
performance acceptance is selected; production milestones remain open.


## Matched index harness revision (2026-10-10)

Prepared a current-source, same-payload index comparison with TypeID fixtures,
stream HOT/WAL observations and active category browsing. Recorded the selected
small protocol, unchanged comparison policy and persistent whole-experiment budget.
Linux compilation and controller input invariants passed; remote evidence is pending.


## Remote proof and coverage revision (2026-10-10)

Recorded verified lifecycle/counter/cleanup evidence, preserved setup failures,
and reduced only the second-case sample count before its submission because
measured reset overhead exceeded the initial estimate. Policy and deadline
remain unchanged; paired cost evidence is still running.


## Matched experiment completion revision (2026-10-10)

Recorded completed samples, fresh uncertainty/WAL cost, the observer grade failure,
explicit diagnostic recovery, early guard correction and verified cell cleanup.
The original policy and hour were preserved; no performance acceptance or
production migration is claimed. General prefix and shared namespace access remain open.
