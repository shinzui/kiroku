---
id: 27
slug: append-performance-experiment-ledger-and-methodology-readme
title: "Append performance experiment ledger and methodology README"
kind: exec-plan
created_at: 2026-05-18T22:10:29Z
intention: "intention_01krxrpv5heny9gs89seas59zm"
master_plan: "docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md"
---

# Append performance experiment ledger and methodology README

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a Haskell event store backed by PostgreSQL. Its "append" path — the SQL and Haskell code that writes a new event into a named stream and into the global `$all` stream — has been the subject of four optimization plans in a row (`docs/plans/21-evaluate-append-hot-path-performance-experiments.md`, `docs/plans/22-optimize-singleton-append-sql-path.md`, `docs/plans/23-restructure-append-into-a-two-round-trip-path.md`, and `docs/plans/24-localize-the-hasql-round-trip-overhead.md`). Each of those plans formed a hypothesis from reading code, built a candidate, ran the `tasty-bench` suite at `kiroku-store/bench/Main.hs`, and made a keep-or-revert decision from eyeball percent deltas. Several arrived at conclusions stronger than the harness could support, and the same shortlist of "remaining candidates" — statement-level mutation triggers, dropping `streams.category`, advisory locks, templated SQL — kept being re-proposed because no canonical record existed of what had already been tried. The same kind of "let me also try X" pattern caused a real loss of evidence: plan 22's Surprises & Discoveries records that `stream_events_notify` trigger disabling and `streams.category` generated-column removal were tried informally during plan 22's work and helped less than was hoped, but that finding was nearly missed when plan 24 tentatively recommended one of them again.

After this plan completes, two artefacts exist in the repository that prevent that cycle from continuing:

1. `docs/perf-experiment-log.md` — an **append-only experiment ledger**, checked into the working tree, backfilled with every append-performance experiment Kiroku has actually run (plans 21 through 24, including the informal `stream_events_notify` and `streams.category` trials from plan 22). "Append-only" here means a convention enforced by the file's own header text: new experiments go at the bottom as new rows, prior rows are never edited. The format is a Markdown table per experiment that records date, originating plan (linked by full repository-relative path), hypothesis (one sentence), variant (the actual SQL or code shape tested), bench numbers (the cells and µs / ps values that supported the decision), outcome (one of `kept`, `reverted`, `not-implemented`), and a one-line lesson. The "append-only" discipline is enforced by code review and the methodology README, not by tooling.

2. `docs/PERF-METHODOLOGY.md` — a **short methodology README** (one or two pages of prose) stating the discipline future append-perf plans must follow: profile to identify the actual hot spot before proposing an optimization, check the ledger to avoid repeating known-failed experiments, state an expected-impact hypothesis grounded in profile numbers before changing code, and re-run the profile after the change to confirm or refute the hypothesis. The README cross-references the Haskell-side profiling harness produced by EP-1 (`docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md`), the PostgreSQL-side profiling harness produced by EP-2 (`docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md`), and the existing bench-process docs in `docs/BENCH-REGRESSION.md`, `docs/BENCH-GATE3.md`, `docs/BENCH-HASKELL-APPEND.md`, and `docs/BENCH-SQL-BASELINE.md`. It does not restate their content; it points at them.

The user-visible behavior this plan enables: opening `docs/perf-experiment-log.md` shows a contributor what has already been tried, what the numbers were, and what the conclusion was, in less than one minute. Opening `docs/PERF-METHODOLOGY.md` tells a contributor how to scope the next append-perf plan so it does not collapse the way plans 21-24 did. A successful demonstration is that a new contributor, before proposing a fifth optimization plan, can answer "what have we tried, and why didn't it work?" by reading those two files instead of by re-reading four full ExecPlans.

This plan is documentation-only. No code under `kiroku-store/src/`, `kiroku-store/sql/`, `kiroku-store/bench/`, or `kiroku-store/test/` is modified. The intention is `intention_01krxrpv5heny9gs89seas59zm`, the same intention used by plans 22, 23, and 24 and by the parent MasterPlan at `docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md`. Implementation commits include the trailers `MasterPlan: docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md`, `ExecPlan: docs/plans/27-append-performance-experiment-ledger-and-methodology-readme.md`, and `Intention: intention_01krxrpv5heny9gs89seas59zm`.


## Progress

The following granular steps track the work. Each step must be checked only after its artefact exists in the working tree.

- [x] Decide the ledger row format (Markdown table vs. YAML-ish prose rows vs. CSV) and write the format-design decision into the Decision Log of this plan. — 2026-05-18, Markdown table per existing Decision Log entry.
- [x] Create `docs/perf-experiment-log.md` with an opening header that names the file's purpose, the append-only convention, and the row schema. No experiment rows yet. — 2026-05-18, file created with header + table populated in the same write.
- [x] Backfill ledger entries for the experiments in `docs/plans/21-evaluate-append-hot-path-performance-experiments.md`: AnyVersion update/insert split, explicit `event_count` parameter, one-event scalar `VALUES` statement. — 2026-05-18.
- [x] Backfill ledger entries for the experiments in `docs/plans/22-optimize-singleton-append-sql-path.md`: scalar singleton append CTE, plus the two informal trials documented in plan 22's Surprises & Discoveries — `stream_events_notify` trigger disabling and `streams.category` generated-column removal. — 2026-05-18.
- [x] Backfill ledger entries for the experiments in `docs/plans/23-restructure-append-into-a-two-round-trip-path.md`: two-round-trip implicit transactions, two-round-trip with explicit `BEGIN/COMMIT`. — 2026-05-18.
- [x] Backfill ledger entries for the experiments in `docs/plans/24-localize-the-hasql-round-trip-overhead.md`: `Hasql.Pool` overhead probe, bare `SELECT 1` round-trip probe, marginal second round-trip probe. — 2026-05-18.
- [x] Write `docs/PERF-METHODOLOGY.md` stating the four-step discipline (profile, ledger-check, expected-impact hypothesis, re-profile-after). Cross-reference EP-1 and EP-2 harness commands and the existing `docs/BENCH-*.md` docs. — 2026-05-18.
- [x] Cross-reference the new ledger from each of `docs/BENCH-REGRESSION.md`, `docs/BENCH-GATE3.md`, `docs/BENCH-HASKELL-APPEND.md`, and `docs/BENCH-SQL-BASELINE.md` by adding a one-line pointer at the top of each ("Append-performance experiment history: see `docs/perf-experiment-log.md`"). — 2026-05-18, used a Markdown blockquote pointing at both `perf-experiment-log.md` and `PERF-METHODOLOGY.md` per Concrete Steps.
- [x] Verify the acceptance criteria in Validation and Acceptance below: the ledger has at least eight rows, the methodology README exists, the cross-references exist, and nothing under `kiroku-store/src/` or `kiroku-store/sql/` was touched. — 2026-05-18, ledger has 11 rows (`grep -c '^|'` = 13 with header+separator); both new files exist; all four bench docs reference the ledger; this plan's commits touch nothing under `kiroku-store/`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Use a Markdown-table format for ledger rows rather than YAML-ish prose blocks or CSV.
  Rationale: A reader scanning ~20 rows wants a one-screen overview, which a fixed-column table gives. YAML-ish blocks would force vertical scrolling and make scanning slower. CSV would read poorly in a text editor and would not render in GitHub or the in-repo Markdown previewer. The columns chosen — Date, Plan, Hypothesis, Variant, Bench numbers, Outcome, Lesson — fit reasonably on a wide screen and degrade to wrapped cells on a narrow one. If the ledger ever grows beyond ~40 rows and the table becomes unwieldy, a follow-up plan can refactor into a per-experiment section format; the conversion is mechanical.
  Date: 2026-05-18

- Decision: Place the methodology README at `docs/PERF-METHODOLOGY.md` (a separate file) rather than embedding it as an opening section of `docs/perf-experiment-log.md`.
  Rationale: The methodology document and the ledger evolve at different rates. The methodology should be edited rarely (only when the discipline itself changes); the ledger is appended to every time a new experiment runs. Keeping them in one file would mix two edit cadences in one history. The cross-reference between them (one paragraph in each pointing at the other) is cheap.
  Date: 2026-05-18

- Decision: Backfill from plans 21-24 only, not from earlier perf-related plans such as `docs/plans/11-single-stream-runtransaction-combinator.md`.
  Rationale: Plans before 21 are not specifically append-performance experiments. Plan 11 introduced the `runTransactionAppending` combinator and includes perf considerations as a sub-concern, but the work it records is a feature plan, not a numbered append-perf experiment. Backfilling it would dilute the ledger's purpose. Earlier work that produced the existing baselines (`docs/BENCH-GATE3.md`, `docs/BENCH-HASKELL-APPEND.md`, `docs/BENCH-SQL-BASELINE.md`) is referenced by cross-link rather than copied into ledger rows.
  Date: 2026-05-18

- Decision: Record the two informal trials from plan 22's Surprises & Discoveries (`stream_events_notify` disabling and `streams.category` removal) as separate ledger rows, not as sub-bullets of the scalar-singleton row.
  Rationale: Each of those informal trials addressed a different hypothesis from the scalar-singleton SQL change. They were not part of plan 22's stated milestones; they were "I also tried X" findings logged in Surprises. If they are not promoted to first-class ledger rows, a future plan reading the ledger will not see them and will be tempted to re-propose them, which is exactly the cycle this plan is supposed to break.
  Date: 2026-05-18

- Decision: Do not backfill quantitative numbers we did not actually measure.
  Rationale: Plan 22's Surprises & Discoveries describes `stream_events_notify` disabling and `streams.category` removal qualitatively ("helped more than" / "did not move the needle") without specific `Mean (ps)` figures, because neither trial produced a CSV artefact. The ledger rows for those experiments use the textual qualifier from plan 22 verbatim and leave the bench-numbers column with a `(qualitative, no CSV)` marker. A reader can then decide if it is worth re-running with the new profiling harnesses to convert that qualitative finding into a numeric one.
  Date: 2026-05-18


## Outcomes & Retrospective

Both milestones landed on 2026-05-18. `docs/perf-experiment-log.md` exists with
11 experiment rows (6 from M1, 5 from M2): plan 21's three reverted experiments
(AnyVersion split, event_count parameter, one-event scalar VALUES), plan 22's
scalar singleton CTE plus the two informal trials (`stream_events_notify`
disabling and `streams.category` removal — first-class rows per the Decision
Log), plan 23's two two-round-trip benchmark-only proofs, and plan 24's three
hasql-overhead probes. Bench figures are quoted verbatim from each source
plan's Surprises & Discoveries; the two informal trials and the two
benchmark-only proofs are marked accordingly so future readers can see at a
glance which rows are quantitative and which are not.

`docs/PERF-METHODOLOGY.md` exists with the four-step discipline (profile first,
check the ledger, state an expected-impact hypothesis grounded in the profile,
re-profile after). It cross-references EP-1 (`docs/plans/25-…`) and EP-2
(`docs/plans/26-…`) for the harness commands, and the four existing
`docs/BENCH-*.md` docs for the regression workflow and historical baselines.
Each of `docs/BENCH-REGRESSION.md`, `docs/BENCH-GATE3.md`,
`docs/BENCH-HASKELL-APPEND.md`, and `docs/BENCH-SQL-BASELINE.md` now opens
with a one-blockquote pointer at the new ledger and methodology README.

Acceptance gate verification on 2026-05-18: `grep -c '^|'
docs/perf-experiment-log.md` reports 13 (1 header + 1 separator + 11
experiment rows; gate was ≥ 10). `grep -E '^\\s*[0-9]\\.\\s\\*\\*(Profile
first|Check the ledger|State an expected-impact hypothesis|Re-profile after)'
docs/PERF-METHODOLOGY.md` matches all four lines. `grep -l
'perf-experiment-log\\.md' docs/BENCH-*.md` lists all four bench docs. No
files under `kiroku-store/src/`, `kiroku-store/sql/`, `kiroku-store/bench/`,
or `kiroku-store/test/` were touched by this plan's commits (modifications
present in the working tree under `kiroku-store/bench/Main.hs` and
`kiroku-store/kiroku-store.cabal` predate this plan's session and are
unrelated work).

Gap noted: the methodology README cites the EP-1 and EP-2 harness commands
through their ExecPlan files (`docs/plans/25-…` and `docs/plans/26-…`)
rather than embedding the literal `cabal bench …` invocations. The MasterPlan
already flagged this as the expected shape during the soft-dependency
window — once EP-1 and EP-2 land, a small follow-up edit to
`docs/PERF-METHODOLOGY.md` can replace the "see the plan for the exact
command" wording with the actual command. That edit is captured by the
MasterPlan's integration discipline rather than as a new task on this plan.

Lessons. The format-design decision (Markdown table) held up well at 11 rows;
no horizontal scrolling required in a 100-column editor view. Marking
qualitative trials with `(qualitative, no CSV)` rather than fabricating
numbers preserved the ledger's calibration — a reader can immediately tell
which rows are convertible to numeric findings under EP-1/EP-2 and which are
already numeric. The decision to record plan 22's two informal trials as
first-class rows rather than sub-bullets of the scalar-singleton row was
validated when writing them: the lessons differ from the singleton row's
lesson and would have been lost as bullets.


## Context and Orientation

Kiroku is a Haskell event store. An **event** is an immutable application-domain fact (for example, "invoice-1234 payment received"). A **stream** is an ordered sequence of events keyed by a `stream_name` (text). The **`$all` stream** is a reserved global stream represented by the row with `stream_id = 0` in PostgreSQL's `streams` table; every appended event also writes a link row pointing at `$all` so subscribers can observe the global order. **Append** is the operation that writes one or more events into a named stream and into `$all` atomically. It is the operation this plan's ledger tracks.

The relevant code lives under `kiroku-store/`. The hot append path is implemented in `kiroku-store/src/Kiroku/Store/SQL.hs` (the SQL statements and Hasql encoders) and `kiroku-store/src/Kiroku/Store/Effect.hs` (the `runStorePool` interpreter that dispatches `AppendToStream` to one of those statements). The benchmark harness is `kiroku-store/bench/Main.hs`, run via `cabal bench kiroku-store:kiroku-store-bench` or the `just bench-regression` recipe. The on-disk regression baseline is `kiroku-store/bench/results/baseline.csv`. Existing documentation about the bench harness is in `docs/BENCH-REGRESSION.md` (the regression-gate workflow), `docs/BENCH-GATE3.md` (the M4 public-API gate, run 2026-03-23), `docs/BENCH-HASKELL-APPEND.md` (the M2 Haskell-append gate, run 2026-03-22), and `docs/BENCH-SQL-BASELINE.md` (the M1 pgbench SQL baseline, run 2026-03-20).

This plan is the third child plan in the MasterPlan at `docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md`. The two sibling plans are EP-1 `docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md`, which adds a profiled `tasty-bench` build that produces a `.prof` cost-centre breakdown of the append path, and EP-2 `docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md`, which adds a harness that runs the production append CTE under `EXPLAIN (ANALYZE, BUFFERS, TIMING)` and captures `auto_explain` output. This plan has soft dependencies on both: the methodology README is more useful with their harness commands available to cite, but the ledger backfill from plans 21-24 does not require either harness to exist first.

The four source plans this ledger backfills from, summarised so a novice reading only this plan understands what they contain:

- **`docs/plans/21-evaluate-append-hot-path-performance-experiments.md`** ("Evaluate Append Hot Path Performance Experiments", 2026-05-17 through 2026-05-18). Investigated whether Commanded-EventStore-inspired SQL-shape changes — passing event count as a parameter, splitting `AnyVersion` into update-then-fallback-to-insert, and using `VALUES` instead of array `unnest` for one-event appends — could close the gap between Kiroku's local benchmark gate and its baseline. Ran each experiment as a separate milestone, recorded measurements under `docs/bench/append-hot-path/`, and **reverted every source change** because none gave a stable improvement on `All.concurrent.32 writers x 10 appends`, which was the failing benchmark that motivated the plan.

- **`docs/plans/22-optimize-singleton-append-sql-path.md`** ("Optimize singleton append SQL path", 2026-05-18). Replaced the array/unnest CTE with a **scalar singleton CTE** for one-event appends, on the hypothesis that the dominant single-event path was paying unnecessary batch machinery. Implemented `SingletonAppendParams`, four singleton statements (one per `ExpectedVersion` constructor), and dispatch through `appendToStream`, `appendToStreamTx`, and `runTransactionAppending`. Tests passed. Benchmarks did not show the required ≥ 10 % single-event speedup, so the change was **reverted**. The plan then added a benchmark-only `raw-append-shape/AnyVersion/scalar singleton` cell to `kiroku-store/bench/Main.hs` to confirm at the raw-SQL level that scalar vs. array binding inside Kiroku's CTE shape was a wash. The plan's Surprises & Discoveries also documents two informal trials run during the same work: disabling the `stream_events_notify` AFTER-trigger on `streams`, and dropping the `streams.category` generated column. The text recorded is: "Disabling `stream_events_notify` helped more than removing the stored generated `streams.category` column. Notification remains a separate optimization candidate, but it does not explain the gap between raw scalar Kiroku SQL and raw production-shape Kiroku SQL." Neither informal trial produced a CSV artefact.

- **`docs/plans/23-restructure-append-into-a-two-round-trip-path.md`** ("Restructure append into a two-round-trip path", 2026-05-18). Hypothesised, from plan 22's structural comparison against the upstream Elixir EventStore at `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore`, that splitting append into two PostgreSQL round-trips — a small `SELECT stream_id, stream_version, deleted_at` followed by a simpler append CTE keyed on integer `stream_id` — would close most of the gap. Implemented this only as a benchmark-only proof in `kiroku-store/bench/Main.hs` (Milestone 1, the plan's own kill-switch gate). The two-roundtrip variant ran **9-28 % slower** than the production arrays/unnest CTE on both new-stream and hot-stream cells, with the `+ BEGIN/COMMIT` framing costing another full round-trip. The plan halted at Milestone 1 without touching live code under `kiroku-store/src/`. The raw-SQL bench cells `two-roundtrip (new stream)`, `two-roundtrip + BEGIN/COMMIT (new stream)`, `two-roundtrip (hot stream)`, `two-roundtrip + BEGIN/COMMIT (hot stream)` remain in `kiroku-store/bench/Main.hs` as durable evidence.

- **`docs/plans/24-localize-the-hasql-round-trip-overhead.md`** ("Localize the Hasql round-trip overhead", 2026-05-18). Asked a single narrower question after plan 23 failed: "is `hasql` / `hasql-pool` itself a fat target?" A transient `hasql-overhead` `tasty-bench` group measured `Pool.use` at **605 ns ± 53 ns**, a bare `SELECT 1` round-trip at **~13 µs**, and the marginal cost of a second `SELECT 1` on a hot pooled connection at **~14 µs**. Conclusion: Hasql is not the bottleneck; the second-round-trip wall-time penalty plan 23 observed is structural. The bench group was deleted after answering the question because most of its cells (parameterised SELECT, append-shape encoder SELECT, INSERT … RETURNING with two append-shape SELECTs) were attribution-by-subtraction exercises the harness could not cleanly support. The two clean findings live only in plan 24 itself.

Benchmark transcripts referenced by plan 21 live under `docs/bench/append-hot-path/`. The relevant files for the backfill are:

- `2026-05-18-head-32-writers-run1.txt` — pre-experiment baseline run.
- `2026-05-18-head-nostream-run1.txt` — pre-experiment NoStream slice.
- `2026-05-18-head-invoice-payment-run1.txt` — pre-experiment hot invoice-payment slice.
- `2026-05-18-event-count-32-writers-run1.txt`, `…-nostream-run1.txt`, `…-invoice-payment-run1.txt` — event-count experiment.
- `2026-05-18-anyversion-split-32-writers-run1.txt`, `…-anyversion-run1.txt`, `…-nostream-run1.txt`, `…-invoice-payment-run1.txt`, `…-full-bench-regression.txt` — AnyVersion split experiment.
- `2026-05-18-one-event-values-32-writers-run1.txt`, `…-anyversion-run1.txt` — one-event scalar VALUES experiment.

Plans 22 and 23 produced CSVs under `/tmp/` rather than checked-in artefacts; their key bench numbers are embedded in the plans' Surprises & Discoveries sections and are quoted verbatim into the ledger rows by this plan.

Definitions used by this plan:

- An **experiment** is one named hypothesis tested by code or schema changes (or a benchmark-only proof) and concluded with a keep / revert / not-implemented decision. A single plan can contain multiple experiments.
- A **bench cell** is one named row in `tasty-bench`'s output (for example, `All.append.single-event.AnyVersion (new stream)`); the term comes from `tasty-bench`'s `bgroup` / `bench` structure used in `kiroku-store/bench/Main.hs`.
- The **ledger** is the Markdown table at `docs/perf-experiment-log.md` after this plan completes.
- An **append-only file** in this project's vocabulary is one where, by convention announced in the file's own header text, new entries are appended at the bottom and existing entries are not edited. The convention is enforced by code review, not by any tooling.
- A **methodology README** is a one-or-two-page prose document stating a working discipline future plans must follow. The one this plan produces lives at `docs/PERF-METHODOLOGY.md`.


## Plan of Work

The work is split into two milestones. Each is independently verifiable: M1 produces a working ledger file with rows for plans 21 and 22, M2 finishes the backfill, adds the methodology README, and cross-references existing bench docs.

### Milestone 1 — Ledger format and backfill from plans 21 and 22

This milestone establishes the ledger's shape and proves the format scales by populating it with the first ~6-7 experiment rows. By the end of M1, `docs/perf-experiment-log.md` exists with: an opening header that names the file's purpose, the append-only convention, and the row schema; a Markdown table populated with rows for plan 21's three experiments (AnyVersion split, event-count, one-event scalar VALUES) and plan 22's three experiments (scalar singleton CTE, `stream_events_notify` informal trial, `streams.category` informal trial). The table columns are Date, Plan, Hypothesis, Variant, Bench Numbers, Outcome, and Lesson.

Edit only one file in M1: `docs/perf-experiment-log.md` (new). Do not yet touch `docs/PERF-METHODOLOGY.md` or any of the existing `docs/BENCH-*.md` files.

The format-design decision is recorded in this plan's Decision Log (already done above): Markdown table; new entries appended at the bottom; existing rows are not edited. The header of the ledger restates that convention so a contributor opening the file alone understands the rule.

Bench-numbers cells in M1 are filled with values quoted verbatim from the source plans:

- For plan 21 experiments, quote the values from plan 21's Surprises & Discoveries (`1.262s`, `1.069s`, `1.140s` for `32 writers x 10 appends`; `2.99 ms`, `2.07 ms`, `2.26 ms`, `2.03 ms` for `hot invoice-payment 10 AnyVersion appends`; `296 µs`, `288 µs`, `205 µs`, `200 µs` for single-event `NoStream` / `AnyVersion`; the µs / ms units are kept as written in those transcripts; full transcripts live under `docs/bench/append-hot-path/`).
- For plan 22's scalar singleton row, quote the focused-control comparison from plan 22's Surprises & Discoveries (`All.append.single-event.AnyVersion (new stream)` `166038525 ps` → `189620605 ps`, `+14.20%`; `All.append.single-event.NoStream (new stream)` `169827420 ps` → `173689501 ps`, `+2.27%`; `All.reliability-audit.hot invoice-payment 10 AnyVersion appends` `1691260156 ps` → `1636809375 ps`, `-3.22%`; and the raw-shape `Mean (ps)` numbers `261766113` / `256862695` / `280996533` / `240184185`).
- For plan 22's two informal-trial rows, the bench-numbers cell reads `(qualitative, no CSV — see plan 22 Surprises)` and the lesson cell quotes the relevant sentence from plan 22.

Acceptance for M1: `docs/perf-experiment-log.md` exists; it parses as Markdown without rendering errors; it contains at least six experiment rows; the file's opening text states the append-only convention; each row's "Plan" column links by full repository-relative path (for example, `docs/plans/21-evaluate-append-hot-path-performance-experiments.md`); each row's "Bench Numbers" cell quotes specific values, not vague descriptions.

Commands to run at the end of M1:

```sh
ls -la docs/perf-experiment-log.md
wc -l docs/perf-experiment-log.md
grep -c '^|' docs/perf-experiment-log.md
```

Expected output: the file exists with non-zero line count, and `grep -c '^|'` reports at least 8 lines (one header row, one separator row, six experiment rows).


### Milestone 2 — Remaining backfill, methodology README, and cross-references

This milestone completes the backfill and produces the methodology README. By the end of M2: the ledger has at least two more rows for plan 23 (the two-round-trip experiment, with both the `no BEGIN/COMMIT` and `+ BEGIN/COMMIT` variants quoted) and at least three more rows for plan 24 (`Pool.use` overhead, bare `SELECT 1` round-trip, marginal second round-trip on a hot pooled connection). `docs/PERF-METHODOLOGY.md` exists with the four-step discipline. Each of `docs/BENCH-REGRESSION.md`, `docs/BENCH-GATE3.md`, `docs/BENCH-HASKELL-APPEND.md`, and `docs/BENCH-SQL-BASELINE.md` has a one-line pointer near its top referencing the new ledger.

The new files written in M2 are `docs/PERF-METHODOLOGY.md` (new) and updates to four existing files. The four-step discipline the README states is:

1. **Profile first.** Before proposing an optimization plan, run EP-1's profiled `tasty-bench` target (`cabal bench kiroku-store:kiroku-store-bench-profiled` or the equivalent `-prof`-enabled command documented in EP-1's plan file) to identify which Haskell cost centres inside `appendToStream`, `buildAppendParams`, `prepareEvents`, `appendParamsEncoder`, or the Hasql encoders account for the bulk of wall time. Also run EP-2's `EXPLAIN (ANALYZE, BUFFERS, TIMING)` harness to identify which CTE node of the production append SQL accounts for the bulk of PostgreSQL time. Both harness commands are documented in `docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md` and `docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md`.
2. **Check the ledger.** Open `docs/perf-experiment-log.md` and read every row whose Variant or Hypothesis touches the cost centre or CTE node the profile pointed at. If the candidate optimization is already represented as a `reverted` or `not-implemented` row with a `qualitative` or numeric outcome, do not re-propose it; either justify in the new plan's Decision Log why this time will be different (for example, "EP-1's profile shows this is now N % of time vs. the qualitative `did not move the needle` finding in plan 22") or pick a different candidate.
3. **State an expected-impact hypothesis grounded in the profile.** The new plan's Purpose / Big Picture must contain a sentence of the form: "the profile shows X is N % of append time; this change should reduce X to roughly Y % of append time, saving Z µs per call." Without that sentence, the plan is not ready to be implemented.
4. **Re-profile after.** Once the experiment is implemented (or completed as a benchmark-only proof), re-run the same profile commands and compare. Update the ledger with a new row whose Outcome cell records whether the prediction held, and whose Lesson cell records the delta between expected and observed. A row whose Lesson cell reads "expected -20 %, observed -2 %" is a useful warning to future plans even if the change was kept.

The README also cross-references the existing process docs: `docs/BENCH-REGRESSION.md` for the regression-gate workflow and `--fail-if-slower` threshold; `docs/BENCH-GATE3.md`, `docs/BENCH-HASKELL-APPEND.md`, `docs/BENCH-SQL-BASELINE.md` for the historical baselines those gates were measured against. It does not restate their content; it tells the reader to consult them and explains how each fits.

The cross-references added to the existing bench docs are minimal — a single sentence each, near the top, of the form:

```markdown
> See `docs/perf-experiment-log.md` for the history of append-performance experiments and `docs/PERF-METHODOLOGY.md` for the discipline future optimization plans must follow.
```

Acceptance for M2: `docs/PERF-METHODOLOGY.md` exists and parses as Markdown; it states the four steps explicitly; it cross-references EP-1, EP-2, and the four existing bench docs by full repository-relative path. The ledger at `docs/perf-experiment-log.md` has at least 8 experiment rows total (covering plans 21-24). Each of `docs/BENCH-REGRESSION.md`, `docs/BENCH-GATE3.md`, `docs/BENCH-HASKELL-APPEND.md`, and `docs/BENCH-SQL-BASELINE.md` contains the pointer paragraph above. `git status` shows changes only under `docs/`; no files under `kiroku-store/src/`, `kiroku-store/sql/`, `kiroku-store/bench/`, or `kiroku-store/test/` are modified.

Commands to run at the end of M2:

```sh
ls -la docs/perf-experiment-log.md docs/PERF-METHODOLOGY.md
grep -c '^|' docs/perf-experiment-log.md
grep -l 'perf-experiment-log\.md' docs/BENCH-REGRESSION.md docs/BENCH-GATE3.md docs/BENCH-HASKELL-APPEND.md docs/BENCH-SQL-BASELINE.md
git status -s -- kiroku-store/
```

Expected output: both files exist; `grep -c '^|'` reports at least 10 table lines (one header row, one separator row, eight experiment rows, possibly more); the four bench docs all list the new ledger; `git status` reports no modifications under `kiroku-store/`.


## Concrete Steps

All commands in this section run from the repository root:

```sh
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

Confirm the project identity and that the documentation paths exist before editing:

```sh
mori show --full
ls -la docs/plans/21-evaluate-append-hot-path-performance-experiments.md \
       docs/plans/22-optimize-singleton-append-sql-path.md \
       docs/plans/23-restructure-append-into-a-two-round-trip-path.md \
       docs/plans/24-localize-the-hasql-round-trip-overhead.md \
       docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md \
       docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md \
       docs/BENCH-REGRESSION.md docs/BENCH-GATE3.md docs/BENCH-HASKELL-APPEND.md docs/BENCH-SQL-BASELINE.md
```

Expected: `mori show --full` reports `shinzui/kiroku` with packages `kiroku-store`, `shibuya-kiroku-adapter`, `kiroku-otel`. All listed plan and doc files exist.

### M1 — Create the ledger and backfill plans 21-22

Create `docs/perf-experiment-log.md` with the structure described below. The file's opening lines (before the table) should read approximately:

```markdown
# Append Performance Experiment Log

This file records every append-performance experiment Kiroku has run. It is
**append-only**: new experiments are added as new rows at the bottom, prior
rows are not edited. The discipline for proposing a new experiment lives in
`docs/PERF-METHODOLOGY.md`.

Each row records:

- **Date**: when the experiment was run (ISO date).
- **Plan**: full repository-relative path to the ExecPlan that introduced the experiment.
- **Hypothesis**: one sentence stating what was expected to improve and why.
- **Variant**: what was actually tested (SQL shape, dispatch path, schema change, benchmark-only probe).
- **Bench Numbers**: the bench cells and values that supported the keep-or-revert decision.
- **Outcome**: one of `kept`, `reverted`, `not-implemented`.
- **Lesson**: a one-line takeaway.
```

Then a Markdown table with one header row, one separator row, and one row per experiment. Use the values quoted from the source plans (see Plan of Work for the specific quotes). The six M1 rows are:

1. AnyVersion update/insert split (plan 21).
2. Explicit `event_count` parameter (plan 21).
3. One-event scalar `VALUES` statement (plan 21).
4. Scalar singleton CTE (plan 22).
5. `stream_events_notify` trigger disabling — informal (plan 22).
6. `streams.category` generated-column removal — informal (plan 22).

Verify M1 acceptance:

```sh
ls -la docs/perf-experiment-log.md
wc -l docs/perf-experiment-log.md
grep -c '^|' docs/perf-experiment-log.md
```

Expected output: the file exists, has tens of lines, and `grep -c '^|'` reports at least 8 (header + separator + 6 experiment rows).

### M2 — Backfill plans 23-24, write the methodology README, cross-reference bench docs

Append rows to `docs/perf-experiment-log.md` for:

7. Two-round-trip raw SQL (`no BEGIN/COMMIT`) (plan 23).
8. Two-round-trip raw SQL (`+ BEGIN/COMMIT`) (plan 23).
9. `Pool.use` overhead probe (plan 24).
10. Bare `SELECT 1` round-trip probe (plan 24).
11. Marginal second-round-trip-on-hot-pooled-connection probe (plan 24).

Each row uses the µs / ns figures quoted verbatim from the source plan's Surprises & Discoveries.

Create `docs/PERF-METHODOLOGY.md`. The file's structure should be:

```markdown
# Append Performance Methodology

This file states the discipline future Kiroku append-performance plans must
follow. It exists so that the next contributor proposing an optimization
plan does not repeat the cycle that plans 21-24 fell into (benchmark-driven
optimization without profiling, without an expected-impact model, and
without a checked-in experiment ledger).

## The four steps

1. **Profile first.** … [as described in Plan of Work above]
2. **Check the ledger.** …
3. **State an expected-impact hypothesis grounded in the profile.** …
4. **Re-profile after.** …

## Where the harnesses live

- Haskell-side profiling: `docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md`.
- PostgreSQL-side profiling: `docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md`.
- Regression-gate workflow: `docs/BENCH-REGRESSION.md`.
- Historical baselines: `docs/BENCH-GATE3.md`, `docs/BENCH-HASKELL-APPEND.md`, `docs/BENCH-SQL-BASELINE.md`.

## Where the ledger lives

`docs/perf-experiment-log.md`. Append-only by convention.
```

Add a pointer paragraph at the top of each of `docs/BENCH-REGRESSION.md`, `docs/BENCH-GATE3.md`, `docs/BENCH-HASKELL-APPEND.md`, and `docs/BENCH-SQL-BASELINE.md`. The exact text is a single Markdown blockquote:

```markdown
> See `docs/perf-experiment-log.md` for the history of append-performance
> experiments and `docs/PERF-METHODOLOGY.md` for the discipline future
> optimization plans must follow.
```

Insert this blockquote immediately after each file's level-1 heading and before its existing opening paragraph. Do not change any other text in those files.

Verify M2 acceptance:

```sh
ls -la docs/perf-experiment-log.md docs/PERF-METHODOLOGY.md
grep -c '^|' docs/perf-experiment-log.md
grep -l 'perf-experiment-log\.md' docs/BENCH-REGRESSION.md docs/BENCH-GATE3.md docs/BENCH-HASKELL-APPEND.md docs/BENCH-SQL-BASELINE.md
git status -s -- kiroku-store/
```

Expected output: both new files exist; `grep -c '^|'` reports at least 11 lines (header + separator + 11+ experiment rows); the `grep -l` lists all four bench docs; `git status -s -- kiroku-store/` returns nothing under `kiroku-store/`.


## Validation and Acceptance

The plan is complete when all of the following hold:

1. **Ledger exists with the required rows.** `docs/perf-experiment-log.md` exists; it contains at least eight experiment rows (more than eight is fine; the minimum corresponds to plan 21's three experiments, plan 22's three experiments, plan 23's one or two experiments, and plan 24's two or three probes). Verify with:

```sh
grep -c '^|' docs/perf-experiment-log.md
```

Expected: a number ≥ 10 (one header row + one separator row + eight or more experiment rows).

2. **Methodology README exists with the four-step discipline.** `docs/PERF-METHODOLOGY.md` exists. It states the four steps (profile first, check the ledger, expected-impact hypothesis, re-profile after) in explicit numbered form. Verify by reading the file and confirming each step is present:

```sh
grep -E '^\s*[0-9]\.\s\*\*(Profile first|Check the ledger|State an expected-impact hypothesis|Re-profile after)' docs/PERF-METHODOLOGY.md
```

Expected: four matching lines.

3. **Cross-references in existing bench docs.** Each of `docs/BENCH-REGRESSION.md`, `docs/BENCH-GATE3.md`, `docs/BENCH-HASKELL-APPEND.md`, and `docs/BENCH-SQL-BASELINE.md` references `docs/perf-experiment-log.md`. Verify with:

```sh
grep -l 'perf-experiment-log\.md' docs/BENCH-REGRESSION.md docs/BENCH-GATE3.md docs/BENCH-HASKELL-APPEND.md docs/BENCH-SQL-BASELINE.md
```

Expected: all four paths listed.

4. **No code changes.** Nothing under `kiroku-store/src/`, `kiroku-store/sql/`, `kiroku-store/bench/`, or `kiroku-store/test/` is modified. Verify with:

```sh
git status -s -- kiroku-store/
```

Expected: empty output.

5. **Each ledger row is grounded.** For every experiment row, the "Bench Numbers" cell either quotes specific `Mean (ps)`, µs, or ms figures from the source plan or marks the row `(qualitative, no CSV — see plan N Surprises)` per the Decision Log entry above. Verify by reading the file and confirming no "Bench Numbers" cell is empty or vague.

6. **The "Plan" column links by full repository-relative path.** Verify by reading the file and confirming each plan-link cell contains a path of the form `docs/plans/NN-…md`.

Beyond compilation, the change is demonstrably effective because: a contributor opening `docs/perf-experiment-log.md` and `docs/PERF-METHODOLOGY.md` for the first time can answer "what append-performance experiments have we run, and what discipline should the next experiment follow?" without reading any other file in the repository. That is the user-visible outcome.


## Idempotence and Recovery

This plan is documentation-only. Every step is safe to repeat: re-running a Markdown edit that produces the same content is a no-op as far as the working tree is concerned, and `git status` plus `git diff` make any accidental drift obvious. There are no destructive operations.

The ledger is **append-only by convention**, not by tooling. New experiments are added as new rows at the bottom. Existing rows are not edited even when later evidence changes how we interpret them — instead, a new row is appended whose "Lesson" cell points at the prior row by date and notes the reinterpretation. This rule applies after this plan completes; *during* this plan's backfill, rows are still being authored for the first time and can be edited until M2 acceptance is verified. Once M2 is committed, the backfill is closed and the file enters its append-only steady state.

If the backfill is interrupted between M1 and M2 (for example, only M1 is committed), the M2 work can be resumed with no special recovery: the ledger already has six rows from M1, and M2 simply appends more rows and adds the methodology README and cross-references. There is no risk of partial state corrupting the file.

If a row's bench-numbers cell is later discovered to misquote the source plan (for example, units transposed or a percentage sign dropped), the correction is itself appended as a new row with a "Lesson" cell pointing at the original row's date and explaining the correction. The original row is not edited. This rule keeps the ledger's history readable and prevents silent rewrites.


## Interfaces and Dependencies

This plan introduces no new dependencies and exposes no new code interfaces. It is purely documentation work.

The files produced or modified are:

- `docs/perf-experiment-log.md` — new file. Markdown table format. At least eight experiment rows after this plan completes.
- `docs/PERF-METHODOLOGY.md` — new file. Prose, one to two pages. States the four-step discipline.
- `docs/BENCH-REGRESSION.md` — modified. Adds a blockquote pointer paragraph near the top, no other changes.
- `docs/BENCH-GATE3.md` — modified. Adds the same blockquote pointer paragraph.
- `docs/BENCH-HASKELL-APPEND.md` — modified. Adds the same blockquote pointer paragraph.
- `docs/BENCH-SQL-BASELINE.md` — modified. Adds the same blockquote pointer paragraph.

The files this plan reads from but does not modify:

- `docs/plans/21-evaluate-append-hot-path-performance-experiments.md` and its bench transcripts under `docs/bench/append-hot-path/`.
- `docs/plans/22-optimize-singleton-append-sql-path.md`.
- `docs/plans/23-restructure-append-into-a-two-round-trip-path.md`.
- `docs/plans/24-localize-the-hasql-round-trip-overhead.md`.
- `docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md` (referenced by path from the methodology README; its content is not required to exist at the time this plan is implemented).
- `docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md` (same as EP-1; referenced by path only).
- `docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md` (the parent MasterPlan).

No Haskell modules, SQL files, or build configuration are touched. The cabal file `kiroku-store/kiroku-store.cabal`, the schema at `kiroku-store/sql/schema.sql`, and the bench harness at `kiroku-store/bench/Main.hs` are all left as-is.

Soft-dependency note: the methodology README cites EP-1 and EP-2 harness commands by ExecPlan path. If those plans have not been implemented yet at the time this plan is written, the README's citations point at the ExecPlan files (which exist as skeletons or filled-out plans, per `docs/masterplans/3-…md`) rather than at the harnesses themselves. Once EP-1 and EP-2 land, a follow-up edit to the README can replace the "see the plan for the exact command" wording with the actual command. That follow-up edit is not part of this plan; it is captured by the MasterPlan's integration discipline.


## Revision Notes

- 2026-05-18: Plan created from the repository skeleton with intention `intention_01krxrpv5heny9gs89seas59zm`, under MasterPlan `docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md`. Scope: documentation-only. Produces `docs/perf-experiment-log.md` (append-only experiment ledger backfilled from plans 21-24, including the two informal trials documented in plan 22's Surprises & Discoveries — `stream_events_notify` disabling and `streams.category` removal — as separate first-class ledger rows) and `docs/PERF-METHODOLOGY.md` (the four-step discipline future append-perf plans must follow). Soft dependencies on EP-1 (`docs/plans/25-…md`) and EP-2 (`docs/plans/26-…md`); the README can be drafted with plan-path citations before either harness lands and revised once they do.
