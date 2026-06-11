---
id: 54
slug: add-prefix-matching-subscription-target-for-fan-in-subscriptions
title: "Add prefix-matching subscription target for fan-in subscriptions"
kind: exec-plan
created_at: 2026-06-03T14:43:06Z
intention: "intention_01kt6yyawwewj80gv5q9qt5m0f"
---

# Add prefix-matching subscription target for fan-in subscriptions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A "subscription" in this repository is a worker that walks the event log forward
and hands each stored event to a handler. Each subscription declares a "target"
that says *which* streams it cares about. Today there are exactly two targets
(defined in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` lines 140-145):

```haskell
data SubscriptionTarget
    = AllStreams                 -- every event in global order
    | Category !CategoryName     -- events whose stream's "category" matches
```

A stream's "category" is the part of its name before the first hyphen — the
column `streams.category` is generated as `split_part(stream_name, '-', 1)`
(migration `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`).
So a stream named `orders-1` has category `orders`, and a `Category "orders"`
subscription sees every `orders-*` stream.

This breaks down for namespaced stream families. The `keiro` framework names its
process-manager state streams `pm:<processName>-<correlationId>` — for example
`pm:fulfillment-abc123` and `pm:billing-def456`. Under the "before first hyphen"
rule those have *different* categories (`pm:fulfillment` and `pm:billing`), so
there is no single `Category` target that observes "every process manager".
An operator who wants one subscription over all `pm:` streams must register one
subscription per process-manager name and re-register whenever a new process
manager is added. The same problem will hit the future `wf:` workflow streams.

After this change there is a third target:

```haskell
    | CategoryPrefix !Text       -- events whose stream_name starts with a literal prefix
```

A `CategoryPrefix "pm:"` subscription observes every stream whose name begins with
`pm:`, regardless of what comes after the first hyphen. One subscription fans in
the whole `pm:` family; adding a new process manager needs no new subscription.

You will be able to see it working by running a new test that appends events to
several differently-named streams that share a prefix (e.g. `pm:fulfillment-1`
and `pm:billing-1`) plus an unrelated stream (`orders-1`), runs a
`CategoryPrefix "pm:"` subscription, and asserts the subscription delivered
exactly the `pm:`-prefixed events and none of the `orders-1` events — across both
the historical catch-up phase and live delivery.

This plan is scoped to the **kiroku-store** package (plus its migrations package).
The `shibuya-kiroku-adapter` passes a `SubscriptionTarget` straight through and
does not pattern-match its constructors, so a prefix target flows through it
unchanged; this plan verifies that and adds no adapter code.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0 (decisions, before coding): settle the two open design choices recorded
  in the Decision Log — (a) constructor name + semantics (`CategoryNamespace`
  matching `category` on `:`, recommended, vs `StreamNamePrefix` matching
  `stream_name`); (b) live-path strategy (accept-and-bound / `$all`-driven live
  query / per-prefix NOTIFY gate). The rest of the plan substitutes the chosen
  forms.
- [ ] M1: Add `-Werror=incomplete-patterns` to the cabal `common common` stanza
  (step 0), then add the constructor and the namespace SQL statements (non-group
  and consumer-group); the now-strict build forces the two pattern-match sites
  (`fetchBatch`, `nextInput`) to gain arms.
- [ ] M2: Add the `text_pattern_ops` index migration so namespace `LIKE` lookups
  are index-backed; **and** record the before/after append-benchmark delta proving
  the shared-`streams` index does not materially regress writers.
- [ ] M3 (optional parity): expose a public `readPrefix` read combinator and a
  `ReadPrefixForward` `Store`-effect constructor.
- [ ] M4: Add the prefix-subscription test (catch-up + live, with a negative
  case); green.
- [ ] M5: Update `kiroku-store/CHANGELOG.md` and document the v1 live-delivery
  tradeoff and the consumer-group story.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Validation pass (2026-06-03), before implementation — findings from reading the
working tree:

- The "warnings-as-errors safety net" the plan originally leaned on did not exist:
  `kiroku-store/kiroku-store.cabal` `common common` (lines 23–30) sets only
  `default-language: GHC2024` and four `default-extensions`; the `library` stanza
  has no `ghc-options`. No `-Wall`/`-Werror`/`-Wincomplete-patterns` anywhere, so
  missing match arms compiled silently and failed at runtime. **Resolved:** M1
  step 0 now adds `-Werror=incomplete-patterns` to `common common`, making the net
  real. Verified it is a clean switch: `cabal build kiroku-store
  --ghc-options="-Werror=incomplete-patterns"` built the library, the test suite,
  and all three benchmarks at **exit 0** with no newly-rejected patterns
  (transcript: only "Building …" lines, no warnings/errors). (See Decision Log.)

- Regression surface for non-users of the feature is a single item: the new
  `text_pattern_ops` index on the shared `streams` table. The code-path additions
  (constructor arm, new SQL, live-loop arm) are reached only by a namespace config,
  and `streams` has no `fillfactor` set (defaults to 100), so appends to existing
  streams are HOT updates that touch no indexes — the regression is confined to
  new-stream INSERTs and non-HOT updates and must be benchmarked in M2 (see the
  append-regression decision). Existing `streams` indexes before this change: PK
  `stream_id`, UNIQUE `stream_name`, `ix_streams_category`.

- Exactly two `case` sites match `SubscriptionTarget` constructors, confirming the
  plan's enumeration. Evidence (repo-wide `rg`):
  `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:229,245` (`nextInput` Live
  arm) and `…:556,559,562,565` (`fetchBatch`). Every other reference
  (shibuya-kiroku-adapter, kiroku-jitsurei, benches, tests, kiroku-metrics) only
  *constructs* a target or re-exports `SubscriptionTarget (..)`; none is an
  exhaustive `case`. `kiroku-metrics` filters via the `readCategory` read
  combinator and a `Maybe Text`, not via `SubscriptionTarget`, so it needs no
  change.

- The Shibuya adapter re-exports `SubscriptionTarget (..)`
  (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:121,139`), so the new
  constructor is automatically exposed downstream — but the field Haddock at
  lines 166 and 318 still says "'AllStreams' or @'Category' categoryName@" and
  should be updated to mention the new constructor. No adapter *code* change is
  needed (confirmed: only value construction + re-export).

- The NOTIFY payload carries the full `stream_name`
  (`notify_events()` in the bootstrap migration emits
  `stream_name || ',' || stream_id || ',' || stream_version`), and
  `Kiroku.Store.Notification.categoryFromPayload` already parses the stream name
  out of it. This makes a future per-prefix NOTIFY gate cheaper than the plan
  implied.

- `readCategoryEncoder :: E.Params (Int64, Text, Int32)` and
  `readCategoryConsumerGroupEncoder :: E.Params (Int64, Text, Int32, Int32, Int32)`
  exist in `SQL.hs` (lines 743, 799) with the exact tuple shapes the plan reuses.
  The existing SQL uses GHC `MultilineStrings` (`"""…"""`), not the
  backslash-line-continuation string style shown in this plan's M1 snippets —
  match the `"""` style and mind that a literal backslash for `ESCAPE '\'` needs
  `'\\'` inside a multiline string. (`ESCAPE '\'` is redundant since `\` is
  PostgreSQL's default `LIKE` escape, but stating it explicitly is harmless.)

- The cited benchmark in `docs/plans/milestone-5-links-and-categories.md` is real
  and is about *exact-category* equality vs `LIKE 'cat-%'` (lines 46–47, 90), not
  about fixed-prefix scans — the plan's distinction holds.

- There is an existing EXPLAIN harness, `kiroku-store/bench/Explain.hs`
  (benchmark `kiroku-store-bench-explain`, ExecPlan 26), that the M2 evidence step
  could mirror instead of hand-running psql.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add a new `CategoryPrefix !Text` constructor to `SubscriptionTarget`
  rather than redefining `Category` to mean a prefix.
  Rationale: `Category` has precise, tested semantics (exact match on the
  generated `streams.category` column, backed by `ix_streams_category` and the
  per-category NOTIFY wake-generation optimization in
  `Kiroku.Store.Notification`). Changing it would break those guarantees and the
  consumer-group partition tests. A new constructor is additive, and a repo-wide
  search confirms exactly two sites pattern-match the target constructors
  (`Worker.hs` `fetchBatch` and `nextInput`); both must gain a new arm.
  Date: 2026-06-03.

- Decision (validation correction, 2026-06-03): Do **not** rely on the compiler
  to flag the two new match arms. An earlier draft of this plan asserted "the
  worker is built with incomplete-pattern warnings as errors, so a missed arm
  fails the build." That is false. `kiroku-store/kiroku-store.cabal` defines a
  `common common` stanza (lines 23–30) that sets only `default-language` and
  `default-extensions`; the `library` stanza carries **no** `ghc-options` at all
  (only the test/bench stanzas add `-threaded …`). There is no `-Wall`, no
  `-Werror`, and no `-Wincomplete-patterns`, and GHC's default warning set does
  not enable incomplete-pattern checking. A missing arm in `fetchBatch` or
  `nextInput` would therefore compile **silently** and fail at *runtime*.
  **Resolution (adopted, replaces the prior "rely on grep + M4 test only"
  stance):** add `-Werror=incomplete-patterns` to the cabal `common common` stanza
  as the first step of M1, restoring the safety net the plan originally assumed.
  `-Werror=incomplete-patterns` both *enables* the warning (it is off by default
  here) and promotes it to an error, so no separate `-Wincomplete-patterns` is
  needed. Verified safe before adopting: `cabal build kiroku-store
  --ghc-options="-Werror=incomplete-patterns"` compiled the library, the test
  suite, and all three benchmarks with exit 0 — there are **no** pre-existing
  incomplete `case`/function patterns the flag would newly reject, so this is a
  clean zero-fix switch today. It goes in `common common` (not library-only)
  because test and bench stanzas were proven clean too; library-only is the
  conservative fallback if a future test deliberately wants a partial match. With
  the flag in place, a forgotten `CategoryPrefix` arm now fails the M1 build —
  belt-and-braces with the M4 behavioural test.
  Date: 2026-06-03.

- Decision (validation correction, 2026-06-03): Standardize on the colon (`:`) as
  a namespace delimiter and define the new target as a **category namespace**
  match rather than a raw stream-name prefix. This resolves the naming/vision
  question the team raised and the misnomer in the original draft (the constructor
  was called `CategoryPrefix` but matched the whole `stream_name`, so
  `CategoryPrefix "order"` would have unanchored-matched `ordering-1` and
  `orderbook-1`).

  Recommended design: `CategoryNamespace !Text`, where `CategoryNamespace "pm"`
  matches every stream whose **category** (the generated `split_part(stream_name,
  '-', 1)` column) is exactly `pm` or begins with `pm:` — i.e. the SQL predicate is
  `s.category = $2 OR s.category LIKE $2 || ':%'` (with the literal escaped). For
  `keiro`'s `pm:<processName>-<corr>` streams the category is `pm:<processName>`,
  so `CategoryNamespace "pm"` fans in the whole family, and the scheme composes
  (`CategoryNamespace "pm:fulfillment"` narrows to that sub-namespace). Anchoring
  on `:` makes the match self-documenting, kills the `ordering`/`orderbook`
  foot-gun, and stays aligned with Message-DB category semantics (the part before
  the first `-`), which fits kiroku's vision better than an arbitrary substring.

  Why category, not stream_name: matching the `category` column lets the supporting
  `text_pattern_ops` index live on `category` instead of `stream_name`. `category`
  has far lower cardinality (many streams per category), so its btree is smaller
  and marginally cheaper to maintain on writes — directly relevant to the
  append-path regression decision below. Functionally either column works for the
  `pm:` case.

  Tradeoff to accept consciously: this bakes the `:` convention into the store. A
  user whose stream names use no `:` simply gets exact-category behaviour from
  `CategoryNamespace` and continues to use `Category` for single categories;
  nothing is lost, but the namespace feature only adds value for `:`-namespaced
  families. If the team prefers a fully general, convention-free tool instead, the
  fallback is `StreamNamePrefix !Text` matching `stream_name LIKE $2` (the original
  raw-prefix semantics, correctly named). The plan's SQL/index/test sections are
  written generically as "the namespace predicate"; pick `CategoryNamespace`
  (recommended) or `StreamNamePrefix` before M1 and substitute the concrete
  predicate (`category … LIKE 'pm:%'` vs `stream_name LIKE 'pm:%'`) and index
  column accordingly.
  Date: 2026-06-03.

- Decision: Match prefixes with `stream_name LIKE <prefix>%` against a
  `text_pattern_ops` btree index on `streams.stream_name`, with the prefix's LIKE
  metacharacters escaped, rather than `starts_with()` or a trigram index.
  Rationale: A plain `LIKE 'literal%'` with a fixed prefix is the canonical
  index-using prefix scan in PostgreSQL, but only when the index opclass is
  `text_pattern_ops` (the default-collation unique index on `stream_name` does not
  serve `LIKE` prefix scans under a non-C collation). `text_pattern_ops` is the
  standard, lowest-risk choice. Escaping `%`, `_`, and `\` in the supplied prefix
  keeps a caller-supplied namespace marker from being interpreted as a wildcard
  while preserving the fixed-prefix shape the planner needs. A historical
  benchmark recorded in `docs/plans/milestone-5-links-and-categories.md` rejected
  `LIKE` for the *exact-category* path because the generated column + equality
  index is faster there; that finding is about equality, not prefix scans, and
  does not apply to a genuine prefix target where `LIKE 'p%'` on a
  `text_pattern_ops` index is the right tool.
  Date: 2026-06-03.

- Decision: For a non-consumer-group prefix subscription, drive live delivery
  through the existing DB-driven live loop (`liveLoopDbDriven`, already used by
  consumer-group subscriptions) rather than the category-specialized NOTIFY loop
  (`liveLoopCategoryNotify`).
  Rationale: `liveLoopCategoryNotify` gates on a *per-category* wake counter in
  the Notifier (`categoryGenerations :: TVar (Map Text Word64)`), so an idle
  category does zero DB work. A prefix spans many categories and has no single
  counter; reusing the category loop would require new per-prefix Notifier state.
  `liveLoopDbDriven` wakes on the global publisher-position advance and re-queries
  with the prefix filter — correct. It also does **not** busy-spin: the loop gates
  on `check (p > waitFrom)` where `waitFrom` is the *last observed* publisher
  position (not the partition cursor), which is exactly the fix from
  `docs/plans/37-fix-category-subscription-live-loop-busy-spin.md`. Reusing it is
  sound on that axis.
  Date: 2026-06-03.

- Decision (validation correction, 2026-06-03): The live-path cost above is larger
  than "polls/wakes on unrelated appends" and must be stated accurately. On every
  global publisher advance, `liveLoopDbDriven` runs the *streams-driven* prefix
  query (`readPrefixForwardStmt`), whose plan enumerates **every** prefix-matching
  stream via the `text_pattern_ops` index and, for each, probes
  `ix_stream_events_all_by_origin` for `stream_version > cursor`. The outer
  `ORDER BY se.stream_version LIMIT $3` cannot short-circuit (it needs the
  globally smallest positions across all matching streams), so each wake costs
  O(number of prefix-matching streams) index probes **even when zero new events
  match**. For the motivating single `pm:` dispatcher over a modest number of
  streams this is fine. But `CategoryPrefix` exists specifically to fan in a
  *large* family, so in a high-throughput store the cost is (publisher tick rate)
  × (size of the prefix family) of empty work — the very thing the per-category
  NOTIFY gate was built to avoid. Three options, to be chosen before M1:
  (a) accept it for v1 but document the bound and advise the target be used for
  bounded families; (b) give the *live* loop a separate `$all`-driven query
  (`FROM stream_events se WHERE se.stream_id = 0 AND se.stream_version > $1 JOIN
  streams s ON s.stream_id = se.original_stream_id WHERE s.stream_name LIKE $2`,
  mirroring `readAllForwardSQL` plus a join), whose cost scales with *new global
  events since the cursor* rather than family size — strictly better at the live
  tail — while keeping the streams-driven query for sparse catch-up; or (c) a true
  per-prefix NOTIFY gate. Note for (c): the existing NOTIFY payload already carries
  the full `stream_name` (`Kiroku.Store.Notification.handleNotification` /
  `categoryFromPayload` parse it out today), so a prefix gate is closer than "new
  per-prefix Notifier state" implies — the listener would maintain prefix-keyed
  wake generations much like `categoryGenerations`. Option (b) is the recommended
  principled fix and fits kiroku's existing `readAllForward` pattern; it does,
  however, mean the live loop no longer shares `fetchBatch`'s single statement.
  Date: 2026-06-03.

- Decision: Support consumer-group + prefix subscriptions in this plan.
  Rationale: The consumer-group catch-up path is the same SQL with an added
  `hashtextextended(stream_id) % size = member` partition filter, and the
  consumer-group live path already uses `liveLoopDbDriven`. Supporting
  `(Just group, CategoryPrefix p)` is a near-free symmetric addition that keeps
  `fetchBatch`'s `(consumerGroup, target)` pattern total without an awkward
  partial/`error` arm. The earlier research note suggesting "non-group only" was
  about the NOTIFY-gate optimization, which we already sidestep by using the
  DB-driven live loop for all prefix subscriptions.
  Date: 2026-06-03.

- Decision (validation correction, 2026-06-03): Account for — and measure — the one
  way this feature can regress subscriptions and writers that never use it. The
  team asked whether non-prefix users pay a cost; the answer is "only one change is
  shared state, and it is on the write path, not the read path."

  What does **not** regress: the new constructor is purely additive to the
  `SubscriptionTarget` sum, so existing `AllStreams` / `Category` / consumer-group
  `case` arms in `fetchBatch` and `nextInput` execute exactly as before (matching a
  data constructor is O(1); extra arms do not slow the existing ones). The new SQL
  statements and live-loop arm are reached only by a namespace config. The
  `-Werror=incomplete-patterns` flag is compile-time only. The Notifier, publisher,
  FSM, `shouldDeliver`, and every existing read statement are untouched. So no
  existing subscription does any extra work at run time.

  What can regress: the new `text_pattern_ops` index lives on the shared `streams`
  table, so it adds write amplification to the append path for **all** writers,
  feature or not. `streams` currently carries three indexes (PK `stream_id`, UNIQUE
  `stream_name`, `ix_streams_category`); the append upsert (`stream_upsert` CTE)
  does an INSERT for a new stream and an UPDATE (version bump) for an existing one.
  (i) New-stream INSERTs gain one extra btree insert each — and process-manager
  workloads that spin up many short-lived `pm:` streams create streams fastest, so
  they feel this most (ironically the same workload the feature targets). (ii)
  Version-bump UPDATEs touch the new index only on **non-HOT** updates: the updated
  column (`stream_version`) is not indexed, so an update is HOT-eligible and updates
  **no** indexes *when the page has free space*. The `streams` table sets no
  `fillfactor` (defaults to 100, no reserved space), so once a page fills, later
  updates go non-HOT and must touch every index, including the new one. The common
  steady-state case (append to an existing stream, HOT update after pruning) is
  unaffected; the regression concentrates in new-stream creation and
  page-pressure/non-HOT updates.

  Required action, not assumption: measure it. The repo has an append benchmark
  (`kiroku-store/bench/Main.hs`, `tasty-bench`, including concurrent-writer and
  new-stream-creation cases) — run the relevant groups before and after adding the
  index and record the delta in Surprises & Discoveries (M2). The project's append
  path is benchmark-gated by precedent (see ExecPlans 21/22/23). Mitigations if the
  delta is material: put the index on the lower-cardinality `category` column (per
  the namespace decision above — smaller btree, cheaper maintenance) rather than
  `stream_name`; and/or consider `fillfactor` tuning on `streams` as a separate,
  out-of-scope change. Do **not** ship the index without the before/after numbers.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this fully before editing. It assumes no prior knowledge of the repository.

`kiroku-store` is a PostgreSQL event-store library rooted at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store`. Paths under
`kiroku-store/` are relative to that directory. Run `cabal` from the repository
root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. SQL migrations live
in a sibling package at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations/sql-migrations/`
and are embedded into the binary at build time, then applied in filename
(lexicographic) order.

The exact places that decide "which streams does a subscription see":

1. **The target type.** `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`
   lines 140-145 — `data SubscriptionTarget = AllStreams | Category !CategoryName`.
   `CategoryName` is `newtype CategoryName = CategoryName Text`
   (`kiroku-store/src/Kiroku/Store/Types.hs` lines 262-268).

2. **The catch-up fetch.** `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`,
   function `fetchBatch` (lines 539-567). It pattern-matches the pair
   `(consumerGroup config, target config)` over four cases and chooses the SQL
   statement to run:

   ```haskell
   case (consumerGroup config, target config) of
       (Nothing, AllStreams) ->
           Pool.use pool (Session.statement (pos, batchSize config) SQL.readAllForwardStmt)
       (Nothing, Category (CategoryName cat)) ->
           Pool.use pool (Session.statement (pos, cat, batchSize config) SQL.readCategoryForwardStmt)
       (Just (ConsumerGroup m n), AllStreams) ->
           Pool.use pool (Session.statement (pos, m, n, batchSize config) SQL.readAllForwardConsumerGroupStmt)
       (Just (ConsumerGroup m n), Category (CategoryName cat)) ->
           Pool.use pool (Session.statement (pos, cat, m, n, batchSize config) SQL.readCategoryForwardConsumerGroupStmt)
   ```

   A new target constructor forces two new arms here (`(Nothing, CategoryPrefix p)`
   and `(Just (ConsumerGroup m n), CategoryPrefix p)`).

3. **The live-delivery dispatch.** Same file, function `nextInput` (lines
   214-248). In the `Live` state it matches `(consumerGroup config, target config)`:

   ```haskell
   Live c -> case (consumerGroup config, target config) of
       (Nothing, AllStreams) -> ...                         -- read from the in-memory live queue
       (Nothing, Category (CategoryName cat)) ->
           liveExitToInput =<< liveLoopCategoryNotify pool config stateVar catGenVar cat emit posRef c stSettings
       (Just _, _) ->
           liveExitToInput =<< liveLoopDbDriven pool config stateVar pubPosVar emit posRef c stSettings
   ```

   The `(Just _, _)` arm already covers *every* consumer-group target including a
   new prefix one. You must add a non-group prefix arm
   `(Nothing, CategoryPrefix p) -> liveExitToInput =<< liveLoopDbDriven ...`,
   reusing the same DB-driven loop the group path uses (see Decision Log).

4. **The category SQL to mirror.** `kiroku-store/src/Kiroku/Store/SQL.hs`:
   - `readCategoryForwardStmt :: Statement (Int64, Text, Int32) (Vector RecordedEvent)`
     (lines ~736-772). Its body joins the global `$all` stream to `streams s` and
     filters `WHERE s.category = $2`, ordered by `stream_version`, `LIMIT $3`.
   - `readCategoryForwardConsumerGroupStmt :: Statement (Int64, Text, Int32, Int32, Int32) (Vector RecordedEvent)`
     (lines ~791-831). Same as above plus
     `AND (((hashtextextended(s.stream_id::text, 0) % $4) + $4) % $4) = $3`
     to keep one partition (member `$3` of `$4`).

   You will add prefix twins of both, differing only in the stream-selection
   predicate: `WHERE s.stream_name LIKE $2` (with the pattern carrying a trailing
   `%`, see below) instead of `WHERE s.category = $2`.

5. **Indexes.** Bootstrap migration lines ~87-115 create `ix_streams_category` on
   the generated `category` column (serves `=`), and the `streams` table has a
   unique index on `stream_name` from
   `CONSTRAINT ix_streams_stream_name UNIQUE (stream_name)`. That unique index is a
   default-collation btree, which does **not** serve `LIKE 'prefix%'` scans unless
   the database collation is `C`. You will add a `text_pattern_ops` index so the
   prefix scan is index-backed regardless of collation.

6. **What is NOT involved.** Target matching is done entirely in SQL stream
   selection; the per-event `shouldDeliver` filter
   (`Kiroku.Store.Subscription.Types` lines 131-133) composes only
   `eventTypeFilter` and `selector` and has no target branch — leave it alone. The
   subscription worker FSM (`Kiroku/Store/Subscription/Fsm.hs`) is target-agnostic.
   The `subscribe` entry point and `defaultSubscriptionConfig` take a whole
   `SubscriptionTarget` value and need no signature change. The
   `shibuya-kiroku-adapter` does not pattern-match `SubscriptionTarget`
   constructors (it passes the target through from `KirokuAdapterConfig`); confirm
   with a grep in M1 and add nothing there.

Terms in plain language:

- **Prefix** here means a literal leading substring of the full `stream_name`
  (e.g. `pm:`), not the hyphen-delimited "category". The prefix is matched
  against the entire stream name with `LIKE`.
- **`text_pattern_ops`** is a PostgreSQL btree operator class that compares text
  byte-by-byte, which is what makes `LIKE 'prefix%'` able to use the index even
  when the column's normal collation would not allow it.
- **Catch-up vs live**: a subscription first replays historical events up to the
  current end of the log (catch-up), then switches to delivering new events as
  they arrive (live). Both phases must honor the prefix.


## Plan of Work

Five milestones. M1 + M2 deliver a working prefix subscription; M3 is optional
parity for non-subscription reads; M4 proves it; M5 documents it.

### Milestone 1 — Add the constructor, the prefix SQL, and the two match arms

Scope: a namespace subscription works end to end against the existing
indexes (it will be correct but not yet index-optimized — M2 adds the index). At
the end, the package compiles and the existing test suite is green. **Naming/SQL
note — read before copying the snippets:** the code snippets in steps 1–4 below
still show the original draft's spelling (`CategoryPrefix` constructor, `stream_name
LIKE $2` predicate). Per the namespace decision in the Decision Log, the
**recommended** form is the constructor `CategoryNamespace` and the predicate
`(s.category = $2 OR s.category LIKE $2 || ':%')` against a `text_pattern_ops`
index on `category`; the convention-free fallback is `StreamNamePrefix` with
`stream_name LIKE $2`. Settle that decision first, then substitute the chosen name
and predicate consistently as you apply each snippet. Step 0 adds
`-Werror=incomplete-patterns`, so from this milestone on a forgotten match arm
fails the build — the compiler safety net the rest of the plan relies on.

Edits:

0. `kiroku-store/kiroku-store.cabal`, the `common common` stanza (lines 23–30):
   add a `ghc-options` line so incomplete patterns become build errors.

   ```cabal
   common common
     default-language:   GHC2024
     ghc-options:        -Werror=incomplete-patterns
     default-extensions:
       DeriveAnyClass
       DuplicateRecordFields
       OverloadedLabels
       OverloadedStrings
   ```

   Verified clean before this plan: `cabal build kiroku-store
   --ghc-options="-Werror=incomplete-patterns"` built the library, tests, and all
   benchmarks at exit 0, so this introduces no pre-existing-pattern fixes. Run
   `cabal build kiroku-store` once now to confirm a clean baseline before adding the
   constructor (so the *next* build's failure unambiguously points at the new arms).

1. `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` lines 140-145: add the
   constructor. (Naming/semantics per the Decision Log — `CategoryNamespace`
   recommended; `StreamNamePrefix` is the convention-free fallback.)

   ```haskell
   data SubscriptionTarget
       = AllStreams
       | Category !CategoryName
       | -- | Subscribe to every stream in a category /namespace/ — its category
         -- (the part before the first @-@) is exactly @ns@ or begins with @ns:@.
         -- E.g. @CategoryNamespace "pm"@ matches @pm:fulfillment-1@ and
         -- @pm:billing-2@ (categories @pm:fulfillment@ / @pm:billing@) but not
         -- @orders-1@. Standardizes on @:@ as the namespace delimiter, so unlike a
         -- raw stream-name prefix it will not match @ordering-1@ for @"order"@.
         CategoryNamespace !Text
       deriving stock (Eq, Show)
   ```

   Once `-Werror=incomplete-patterns` is in place (step 0), `cabal build
   kiroku-store` now **fails** here until both `Worker.hs` arms (steps 3–4) are
   added — pointing you straight at the two sites.

2. `kiroku-store/src/Kiroku/Store/SQL.hs`: add two statements next to the category
   ones. Add a small helper to turn a caller prefix into a safe `LIKE` pattern,
   and export the new statements the same way the category statements are
   exported.

   ```haskell
   -- Turn a literal prefix into a LIKE pattern that matches it at the start of
   -- the string, escaping LIKE metacharacters so a namespace marker like "pm:"
   -- (or one containing '%' or '_') is treated literally. Pair with "LIKE ... ESCAPE '\'".
   likePrefixPattern :: Text -> Text
   likePrefixPattern p = T.concatMap esc p <> "%"
     where
       esc c
           | c == '\\' = "\\\\"
           | c == '%'  = "\\%"
           | c == '_'  = "\\_"
           | otherwise = T.singleton c

   readPrefixForwardStmt :: Statement (Int64, Text, Int32) (Vector RecordedEvent)
   readPrefixForwardStmt =
       preparable readPrefixForwardSQL readCategoryEncoder (D.rowVector recordedEventRow)

   readPrefixForwardSQL :: Text
   readPrefixForwardSQL =
       -- identical to readCategoryForwardSQL but selecting by stream_name prefix
       "SELECT e.event_id, e.event_type, \
       \       se.stream_version, se.stream_version AS global_position, \
       \       se.original_stream_id, se.original_stream_version, \
       \       e.data, e.metadata, e.causation_id, e.correlation_id, e.created_at \
       \FROM streams s \
       \JOIN LATERAL ( \
       \  SELECT se.* FROM stream_events se \
       \  WHERE se.stream_id = 0 AND se.original_stream_id = s.stream_id \
       \    AND se.stream_version > $1 \
       \  ORDER BY se.stream_version ASC LIMIT $3 \
       \) se ON true \
       \JOIN events e ON e.event_id = se.event_id \
       \WHERE s.stream_name LIKE $2 ESCAPE '\\' \
       \ORDER BY se.stream_version ASC LIMIT $3"

   readPrefixForwardConsumerGroupStmt :: Statement (Int64, Text, Int32, Int32, Int32) (Vector RecordedEvent)
   readPrefixForwardConsumerGroupStmt =
       preparable readPrefixForwardConsumerGroupSQL readCategoryConsumerGroupEncoder (D.rowVector recordedEventRow)

   readPrefixForwardConsumerGroupSQL :: Text
   readPrefixForwardConsumerGroupSQL =
       -- readPrefixForwardSQL plus the partition predicate from
       -- readCategoryForwardConsumerGroupSQL
       "... WHERE s.stream_name LIKE $2 ESCAPE '\\' \
       \  AND (((hashtextextended(s.stream_id::text, 0) % $4) + $4) % $4) = $3 \
       \ORDER BY se.stream_version ASC LIMIT $5"
   ```

   Reuse the existing `readCategoryEncoder` (it encodes `(Int64, Text, Int32)`)
   and `readCategoryConsumerGroupEncoder` (it encodes `(Int64, Text, Int32, Int32, Int32)`)
   — the parameter tuples are identical to the category statements, only the SQL
   text's predicate differs. Confirm the exact constant/encoder names against
   `SQL.hs` lines ~736-831 and copy the surrounding `preparable`/`recordedEventRow`
   idiom verbatim. Ensure `import qualified Data.Text as T` is in scope for
   `likePrefixPattern`.

3. `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` `fetchBatch` (lines
   539-567): add the two prefix arms. The prefix value passed as `$2` must be the
   `likePrefixPattern p` form (so wrap at the call site, or store the pattern once):

   ```haskell
       (Nothing, CategoryPrefix p) -> do
           result <- Pool.use pool (Session.statement (pos, SQL.likePrefixPattern p, batchSize config) SQL.readPrefixForwardStmt)
           handle result
       (Just (ConsumerGroup m n), CategoryPrefix p) -> do
           result <- Pool.use pool (Session.statement (pos, SQL.likePrefixPattern p, m, n, batchSize config) SQL.readPrefixForwardConsumerGroupStmt)
           handle result
   ```

   (`handle` / `pos` / `batchSize config` are the same locals the existing arms
   use; match their exact spelling.)

4. `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` `nextInput` `Live` arm
   (lines 214-248): add the non-group prefix arm, routing to the DB-driven loop:

   ```haskell
       (Nothing, CategoryPrefix _) ->
           liveExitToInput =<< liveLoopDbDriven pool config stateVar pubPosVar emit posRef c stSettings
   ```

   The `(Just _, _)` arm already handles `(Just group, CategoryPrefix p)`; no new
   group arm is needed in `nextInput`.

5. Grep the adapter to confirm no exhaustive match needs updating:

   ```bash
   rg -n "AllStreams|Category" /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter/src
   ```

   Expect only pass-through uses (constructing/forwarding a target), not a `case`
   that would now be non-exhaustive. (Validation confirmed this: the only matches
   are value construction and the `SubscriptionTarget (..)` re-export.) While here,
   update the now-stale field Haddock at
   `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:166` and `:318`
   ("'AllStreams' or @'Category' categoryName@") to also name the new constructor,
   since the re-export exposes it downstream. Record the result in Surprises &
   Discoveries.

Acceptance for M1: `cabal build kiroku-store` compiles. Because step 0 added
`-Werror=incomplete-patterns`, the build is now a real safety net: between adding
the constructor (step 1) and adding the two `Worker.hs` arms (steps 3–4) the build
**fails** with an incomplete-pattern error naming `fetchBatch`/`nextInput`, and
goes green only once both arms are present. As a structural double-check,
`rg -n "CategoryNamespace" kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`
should show one arm in `nextInput` (the `(Nothing, CategoryNamespace _)` Live arm)
and two in `fetchBatch` (`(Nothing, …)` and `(Just (ConsumerGroup …), …)`).
`cabal test kiroku-store` is green (existing behavior unchanged; the new arms are
only reached by a namespace config, which nothing constructs yet).

### Milestone 2 — Add the prefix index migration

Scope: make the namespace `LIKE` scan index-backed so a namespace subscription
over a large store does not sequential-scan `streams`, **and** measure the
append-path cost the new index adds (it is on the shared `streams` table, so it
affects every writer — see the append-regression decision in the Decision Log). At
the end, `EXPLAIN` shows an index scan for the namespace predicate and the
before/after append benchmark delta is recorded.

Create `kiroku-store-migrations/sql-migrations/2026-06-03-00-00-00-kiroku-prefix-subscription.sql`
(the date prefix sorts after the existing migrations, so it applies last). Index
the column the chosen predicate filters on — `category` for the recommended
`CategoryNamespace` design (lower cardinality, smaller/cheaper btree), or
`stream_name` for the `StreamNamePrefix` fallback:

```sql
-- Support namespace-matching subscription targets.
-- A default-collation btree does not serve LIKE 'ns:%' scans; text_pattern_ops
-- compares byte-by-byte so the planner can use it. Index the predicate column:
--   CategoryNamespace -> category ; StreamNamePrefix -> stream_name
CREATE INDEX IF NOT EXISTS ix_streams_category_pattern
    ON streams (category text_pattern_ops);
```

Be aware of the embedded-migration build caveat: the migration set is embedded via
Template Haskell, and adding a *new* `.sql` file may not trigger a recompile of
the embedding module (cabal can report "Up to date" and skip it). After adding the
file, force a rebuild of the migrations package before trusting it:

```bash
cabal clean
cabal build kiroku-store-migrations
```

Acceptance for M2 has two parts — the read win and the write cost.

Read win. First confirm the index exists after migration (this is the robust
check — it does not depend on the planner's row-count heuristics):

```sql
SELECT indexname FROM pg_indexes
WHERE schemaname = 'kiroku' AND tablename = 'streams'
  AND indexname = 'ix_streams_category_pattern';
```

To *also* show the planner uses it, be aware that on a fresh ephemeral test
database with only a handful of `streams` rows the planner will correctly pick a
`Seq Scan` regardless of the index — a bare `EXPLAIN` will **not** show the index
and that is not a failure. Force a representative plan one of two ways: either
insert several thousand `pm:*` and unrelated streams first, or disable sequential
scans for the probe (substitute `stream_name` if you chose `StreamNamePrefix`):

```sql
SET enable_seqscan = off;
EXPLAIN SELECT 1 FROM streams s WHERE s.category LIKE 'pm:%' ESCAPE '\';
RESET enable_seqscan;
```

With either approach the plan shows `Index ... Scan using
ix_streams_category_pattern` rather than a `Seq Scan` over `streams`. The existing
EXPLAIN harness `kiroku-store/bench/Explain.hs` (benchmark
`kiroku-store-bench-explain`) is a ready model if you prefer a harnessed run.
Record the `EXPLAIN` line in Surprises & Discoveries as evidence.

Write cost (do not skip — this is the regression check for users who never touch
the feature). The new index is on the shared `streams` table, so it adds
write-amplification to the append path. Measure it with the existing append
benchmark (`kiroku-store/bench/Main.hs`, `tasty-bench`):

```bash
# Baseline BEFORE creating the index (or with the migration file temporarily
# removed), capturing the append + new-stream-creation groups:
cabal bench kiroku-store:kiroku-store-bench --benchmark-options='--csv before.csv'
# Then with the index present:
cabal bench kiroku-store:kiroku-store-bench --benchmark-options='--csv after.csv'
```

Compare the append and stream-creation groups before vs after and record the delta
in Surprises & Discoveries. Acceptance: the regression on the common
append-to-existing-stream path is within benchmark noise (expected — that path is a
HOT update that touches no indexes), and any increase on new-stream creation is
quantified and judged acceptable. If new-stream creation regresses materially,
revisit the index-column choice (`category` is already the cheaper option) before
shipping; per the Decision Log, the index must not ship without these numbers.

### Milestone 3 (optional parity) — Public `readPrefix` read combinator

Scope: mirror the existing `readCategory` non-subscription read so callers can do
a one-shot prefix read, not only a subscription. This is optional; the
subscription path in M1/M2 does not depend on it (the worker calls the SQL
statements directly through the pool, not through the `Store` effect).

If done, mirror the category surface:
- `kiroku-store/src/Kiroku/Store/Effect.hs`: add a constructor
  `ReadPrefixForward :: Text -> GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)`
  next to `ReadCategoryForward` (line 91) and an interpreter arm next to lines
  196-200 that runs `SQL.readPrefixForwardStmt` with `SQL.likePrefixPattern`.
- `kiroku-store/src/Kiroku/Store/Read.hs`: add `readPrefix :: (HasCallStack, Store :> es) => Text -> GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)`
  mirroring `readCategory` (lines 128-142), and export it from `Kiroku.Store`.
- Adding a `Store` constructor means every interpreter must cover it. Do not rely
  on the compiler to find them — as with the worker arms, the library has no
  `-Wincomplete-patterns`, so a missed interpreter arm compiles and fails at
  runtime. Grep for every `ReadCategoryForward` handler
  (`rg -n "ReadCategoryForward" --type haskell`, including any mock/test
  interpreters) and add the parallel `ReadPrefixForward` arm at each.

Acceptance for M3: `cabal build kiroku-store` green; a quick test reading a prefix
returns the same events the subscription would.

### Milestone 4 — Prove prefix fan-in with catch-up, live, and a negative case

Scope: a new test demonstrating that a `CategoryPrefix` subscription sees exactly
the prefixed streams. At the end the test is green.

Create `kiroku-store/test/Test/SubscriptionPrefix.hs`, modeled on the category and
consumer-group tests (`kiroku-store/test/Test/CategoryIdleNoSpin.hs` and
`kiroku-store/test/Test/ConsumerGroup.hs`) and using `kiroku-store/test/Test/Helpers.hs`
(`withTestStore`, the append helpers, and the live/catch-up wait utilities).
Register it in `kiroku-store/kiroku-store.cabal`'s test stanza and the spec
driver, exactly as the existing subscription tests are registered.

Catch-up case:
- Before subscribing, append events to `pm:fulfillment-1`, `pm:billing-1`, and the
  unrelated `orders-1`.
- Subscribe with `defaultSubscriptionConfig (SubscriptionName "pm-all") (CategoryPrefix "pm:") collectingHandler`,
  where `collectingHandler` records each delivered event's stream name into a
  `TVar [Text]` (or an `IORef`) and returns `Continue`.
- Wait until the checkpoint reaches the position of the last appended event (reuse
  the wait helper the other subscription tests use).
- Assert the collected stream names are exactly `["pm:fulfillment-1", "pm:billing-1"]`
  (order is global-position order), and that `orders-1` was never delivered. This
  proves the prefix matches across differing categories and excludes non-matching
  streams.

Live case:
- With the same subscription still running and caught up, append a new event to
  `pm:shipping-9` and to `orders-2`.
- Wait until the `pm:shipping-9` event is delivered (poll the collected list or
  the checkpoint). Assert `pm:shipping-9` appears and `orders-2` never does. This
  exercises the `liveLoopDbDriven` prefix path from M1.

Optional consumer-group case:
- Append several `pm:*` streams; run two members
  (`CategoryPrefix "pm:"` with `consumerGroup = Just (ConsumerGroup 0 2)` and
  `... 1 2`); assert the union of delivered events equals all `pm:*` events with no
  overlap (disjoint, complete) — mirroring `Test/ConsumerGroup.hs`'s partition
  assertions.

Acceptance for M4: `cabal test kiroku-store` runs the new module green; the
catch-up assertion (exactly the two `pm:` streams, not `orders-1`) and the live
assertion (`pm:shipping-9` yes, `orders-2` no) both pass.

### Milestone 5 — Changelog and documentation

Scope: make the target discoverable and record the v1 tradeoff.

Add an `### Unreleased` entry to `kiroku-store/CHANGELOG.md` under "New Features":
the new `SubscriptionTarget` constructor (named per the naming decision in the
Decision Log — `CategoryPrefix` or `StreamNamePrefix`), its semantics (matches
`stream_name` by literal prefix, escaped, via a `text_pattern_ops` index),
consumer-group support, and an accurate live-delivery note: non-group prefix
subscriptions use the DB-driven live loop (global wake + prefix re-query) rather
than the per-category NOTIFY gate, so on every global append the loop re-runs the
prefix query, which probes every prefix-matching stream — cost scales with the
size of the prefix family, not just "wakes on unrelated appends" (see the live
performance decision in the Decision Log). State the chosen v1 option (a/b/c) and
its bound. Mention the new migration
`2026-06-03-00-00-00-kiroku-prefix-subscription.sql`, and that the
`shibuya-kiroku-adapter` `subscriptionTarget` field Haddock now lists the new
constructor.

Acceptance for M5: the CHANGELOG renders and names `CategoryPrefix`, the index,
and the migration exactly.


## Concrete Steps

All commands from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

Build after each edit:

```bash
cabal build kiroku-store
```

After adding the migration (M2), force the embedded-migration rebuild:

```bash
cabal clean && cabal build kiroku-store-migrations && cabal build kiroku-store
```

Run the test suite:

```bash
cabal test kiroku-store
```

Iterate on just the prefix spec (hspec match syntax shown; adjust to the suite's
driver):

```bash
cabal test kiroku-store --test-options='--match "prefix"'
```

Expected success looks like (exact wording depends on the driver; what matters is
zero failures):

```text
All N tests passed (… s)
```


## Validation and Acceptance

Behavioral acceptance, not compilation alone:

1. Build is clean:

```bash
cabal build kiroku-store
```

   With `-Werror=incomplete-patterns` added in M1 step 0, a clean build now does
   prove every `SubscriptionTarget` `case` is exhaustive — a missing arm in
   `fetchBatch`/`nextInput` fails the build with a named incomplete-pattern error.
   This is necessary but not sufficient: it proves the arms *exist*, not that they
   route correctly; the M4 behavioural test below proves the routing.

2. `Test/SubscriptionPrefix.hs` catch-up assertion: a `CategoryPrefix "pm:"`
   subscription over a store containing `pm:fulfillment-1`, `pm:billing-1`, and
   `orders-1` delivers exactly the two `pm:` events in global order and never the
   `orders-1` event.

3. The same subscription's live assertion: after catch-up, a new `pm:shipping-9`
   event is delivered and a new `orders-2` event is not.

4. M2 evidence: `ix_streams_stream_name_pattern` exists after migration
   (`pg_indexes` check), and with a representative row count or `SET enable_seqscan
   = off`, `EXPLAIN` of `... WHERE stream_name LIKE 'pm:%' ESCAPE '\'` shows an
   index scan on it rather than a sequential scan. (A bare `EXPLAIN` on a tiny
   test DB legitimately shows a `Seq Scan`; that is not a failure — see M2.)

5. Regression: the category and consumer-group suites
   (`Test/CategoryIdleNoSpin.hs`, `Test/ConsumerGroup.hs`) remain green, proving
   the existing targets are unaffected.

Interpretation: if `orders-1` is delivered, the prefix predicate is wrong (likely
an unescaped or missing trailing `%`, or matching `category` instead of
`stream_name`). If the live `pm:shipping-9` event never arrives, the `nextInput`
prefix arm is not routing to `liveLoopDbDriven`. If `EXPLAIN` shows a sequential
scan, the `text_pattern_ops` index is missing or the pattern is not a fixed-prefix
`LIKE`.


## Idempotence and Recovery

- The new constructor and SQL statements are additive; rebuilding re-applies the
  same source with no side effects.
- `CREATE INDEX IF NOT EXISTS` is idempotent; applying the migration twice is
  safe, and codd/the migration runner records it as applied so it runs once per
  database. The index creation takes a lock proportional to the `streams` table
  size; on a large production table prefer `CREATE INDEX CONCURRENTLY` run
  out-of-band, but for the embedded migration path the plain form is acceptable
  and matches the existing bootstrap migration style.
- If the embedded migration is not picked up (cabal "Up to date" after adding the
  new `.sql`), recover with `cabal clean` then rebuild `kiroku-store-migrations`
  — no data is affected because the migration had not yet applied.
- Tests run against fresh ephemeral databases via `withTestStore`, so re-runs need
  no manual cleanup.


## Interfaces and Dependencies

No new library dependencies; all of this uses `hasql` statements and the existing
migration tooling.

Signatures/identifiers that must exist at the end of each milestone (full paths):

- End of M1:
  - `Kiroku.Store.Subscription.Types.SubscriptionTarget` gains
    `CategoryPrefix !Text` (exported, `Eq`/`Show` derived).
  - `Kiroku.Store.SQL.readPrefixForwardStmt :: Statement (Int64, Text, Int32) (Vector RecordedEvent)`
  - `Kiroku.Store.SQL.readPrefixForwardConsumerGroupStmt :: Statement (Int64, Text, Int32, Int32, Int32) (Vector RecordedEvent)`
  - `Kiroku.Store.SQL.likePrefixPattern :: Text -> Text`
  - `Kiroku.Store.Subscription.Worker.fetchBatch` and `nextInput` handle the new
    constructor (no incomplete-pattern warning).

- End of M2:
  - Migration `kiroku-store-migrations/sql-migrations/2026-06-03-00-00-00-kiroku-prefix-subscription.sql`
    creating `ix_streams_stream_name_pattern ON streams (stream_name text_pattern_ops)`.

- End of M3 (optional):
  - `Kiroku.Store.Effect.Store` gains `ReadPrefixForward :: Text -> GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)`
    with interpreter coverage everywhere `ReadCategoryForward` is handled.
  - `Kiroku.Store.Read.readPrefix :: (HasCallStack, Store :> es) => Text -> GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)`,
    re-exported from `Kiroku.Store`.

- End of M4:
  - `kiroku-store/test/Test/SubscriptionPrefix.hs` exists, is registered in
    `kiroku-store/kiroku-store.cabal`, and passes.

`subscribe`, `defaultSubscriptionConfig`, `runWorker`, the FSM, the Notifier, and
the Shibuya adapter need no signature changes.


## Revision Notes

### 2026-06-03 — Validation pass against the working tree

This plan was reviewed against the actual `kiroku-store` source by a reviewer
familiar with the architecture. The work is well-scoped and the mechanical core
(new constructor, two SQL twins, two `Worker.hs` arms, `text_pattern_ops` index,
behavioural test) is sound and accurately located. Four corrections were folded
in; the why for each is in the Decision Log / Surprises & Discoveries:

1. **Removed a false safety net.** The plan claimed the worker is built with
   incomplete-pattern warnings as errors. It is not — `kiroku-store.cabal` enables
   no `-Wall`/`-Werror`/`-Wincomplete-patterns`, so a missed match arm compiles
   silently and fails at runtime. Acceptance criteria in M1 and Validation that
   relied on this were rewritten to lean on the M4 behavioural test plus an
   explicit grep, and optional hardening (`-Werror=incomplete-patterns` on the
   library) was suggested. The plan's two-site enumeration was independently
   verified correct, so the mechanical risk is low for a careful implementer.

2. **Flagged a naming/vision mismatch.** `CategoryPrefix` matches `stream_name`,
   not the `category` column; the team should decide between renaming it
   (`StreamNamePrefix`) or matching `category LIKE` instead. Added as a Decision
   Log item to settle before M1.

3. **Corrected the live-path performance framing.** Reusing `liveLoopDbDriven` for
   non-group prefix subscriptions costs O(prefix-family size) index probes on
   *every* global append, not merely "wakes on unrelated appends." Fine for a
   single bounded `pm:` dispatcher; potentially significant for large families in
   busy stores. Documented three options (accept-and-bound / `$all`-driven live
   query / per-prefix NOTIFY gate, the last cheaper than implied since the NOTIFY
   payload already carries `stream_name`) and recommended the `$all`-driven query.
   Affirmed the reuse is free of the ExecPlan-37 busy-spin defect.

4. **Fixed the M2 EXPLAIN acceptance.** A bare `EXPLAIN` on a fresh ephemeral test
   DB legitimately shows a `Seq Scan` (tiny table); rewrote acceptance to check
   the index exists via `pg_indexes` and to force the index plan with row volume
   or `SET enable_seqscan = off`. Noted the existing `bench/Explain.hs` harness.

Minor: adapter Haddock (`Shibuya/Adapter/Kiroku.hs:166,318`) should be updated to
name the new constructor (no code change); match the existing `"""` MultilineString
SQL style rather than backslash-continuation strings.

### 2026-06-03 — Second pass: three team decisions folded in

Following review feedback, three points were resolved and propagated:

1. **Adopt `-Werror=incomplete-patterns`.** Promoted from "optional hardening" to
   M1 step 0, added to the cabal `common common` stanza. Verified a clean switch:
   `cabal build kiroku-store --ghc-options="-Werror=incomplete-patterns"` built the
   library, test suite, and all three benchmarks at exit 0 — no pre-existing
   incomplete patterns to fix first. This restores the real safety net the original
   draft wrongly assumed; M1 acceptance and Validation §1 were rewritten to rely on
   it again (build now fails on a forgotten arm), with the M4 test still proving
   routing. Progress, Surprises, and the Decision Log updated accordingly.

2. **Answered "any regression for non-users?"** Yes — exactly one shared-state
   change: the new `text_pattern_ops` index on `streams`, which adds append-path
   write amplification (new-stream INSERTs always; non-HOT version updates under
   the default `fillfactor` 100). The code-path additions do not affect existing
   subscriptions. Added a Decision Log entry and a Surprises note, and made M2
   acceptance require a before/after append-benchmark delta (`kiroku-store/bench`)
   — the index must not ship without numbers.

3. **Standardize on the colon (`:`).** Recommended redefining the feature as a
   category *namespace* match (`CategoryNamespace "pm"` → `category = 'pm' OR
   category LIKE 'pm:%'`) rather than a raw stream-name prefix. This fixes the
   `CategoryPrefix`-matches-`stream_name` misnomer, removes the
   `order`→`ordering`/`orderbook` foot-gun, aligns with Message-DB category
   semantics, and lets the supporting index sit on the lower-cardinality `category`
   column (cheaper writes — ties into point 2). `StreamNamePrefix` remains the
   convention-free fallback. The decision, the M0 gate, the constructor/SQL/index
   snippets, and the migration (now `ix_streams_category_pattern ON streams
   (category text_pattern_ops)`) were updated to carry both options with the
   namespace form recommended. Final name/semantics is the team's call at M0.
