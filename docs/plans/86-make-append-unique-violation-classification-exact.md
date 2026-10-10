---
id: 86
slug: make-append-unique-violation-classification-exact
title: "Make append unique-violation classification exact"
kind: exec-plan
created_at: 2026-08-27T21:14:52Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
provenance:
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      verdict: "approved"
      note: "Perf review: error-path only, mapUsageError runs only on Left; no hot-path impact, no gate needed beyond EP-6"
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-09T16:21:16Z
      mode: "update"
      note: "Audit source at e6ea664; distinguish completed baseline from remaining work, refresh request coverage and performance evidence requirements"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T01:28:35Z
      mode: "implement"
      note: "Implement exact constraint classification and focused append regression coverage."
---

# Make append unique-violation classification exact

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku classifies PostgreSQL `23505` failures by constraint name. Before this
implementation, substring matching classified `stream_events_pkey` as `events_pkey`
and lost the composite event ID. The invariant constraint
`ux_stream_events_stream_version` also became `WrongExpectedVersion`, disguising an
internal invariant failure as a caller precondition mismatch.

After this plan, exact constraint classification distinguishes a duplicate caller event id from
an already-linked pair and from internal stream-version corruption. Pure mapping tests pin every
constraint, and a database regression proves retrying the same event id against the same stream is
reported deterministically without disguising an invariant failure as an expected-version race.


## Progress

- [x] (2026-10-10) M1: add table-driven mapping tests for `events_pkey`, `stream_events_pkey`, `ux_stream_events_stream_version`, stream-name, and unknown unique constraints.
- [x] (2026-10-10) M2: make append constraint matching exact and order-independent, retaining event-id extraction where valid.
- [x] (2026-10-10) M2: map the stream-version invariant constraint to `UnexpectedServerError "23505"` and add a real append duplicate regression.
- [x] (2026-10-10) Update error Haddocks/changelog, run focused and full store tests, and perform ADR distillation. All 423 store examples, 20 structural cases and 16 controlled workloads pass; strict ADR validation and formatting pass.


## Surprises & Discoveries

- (2026-10-10) The corrected focused runs pass 49 mapping cases and both
  duplicate-append cases. Same-stream retry is checked with AnyVersion,
  StreamExists and ExactVersion 1; each rollback preserves one event, one
  original link, one global link and stream version 1.

- (2026-10-10) Hspec treats the plan's combined pipe filter literally and
  selected zero examples. Focused groups now run separately; the zero-example
  transcript is retained as `focused.log` and is not validation evidence.

- (2026-10-10) The pre-change mapping table runs 43 examples with 26 failures,
  including the composite UUID, invariant SQLSTATE, lookalike constraints and
  message precedence. The transaction mapper shares the substring bug; all
  unique-constraint mappers now share one extractor. The retained transcript is
  `kiroku-store/bench/results/ep5-unique-violation/mapping-before.log`.

- Refresh audit (2026-10-09): source, tests, and changelogs confirm the remaining acceptance
  work is unimplemented; the dated Context audit distinguishes existing baseline from this plan.
- Transfer audit (2026-08-27): link-specific and transaction-generic mappers already test
  `stream_events_pkey` explicitly, but `mapUniqueViolation` still starts with the substring
  `events_pkey`. The primary append path therefore depends on branch text rather than an exact
  constraint token.
- Transfer audit (2026-08-27): released Kiroku 0.8 already maps `40001` and `40P01` to
  `TransientTransactionFailure`. This plan does not reopen transaction retry taxonomy.


## Decision Log

- Decision (2026-10-10): share exact extraction with the opaque transaction,
  link and multi-stream attribution mappers while preserving their distinct
  constructors and unknown-error fallbacks. The transaction mapper has the
  identical composite-key collision; one parser prevents future drift.
- Decision (2026-10-10): verify stream-version invariant classification with
  synthetic Hasql errors, not a real corrupted-store fixture. Normal append
  serialization prevents the violation; manufacturing it would require inconsistent
  rows or an artificial trigger and would test the fixture rather than append.
  Same-stream retries are tested through three real append expectations.

- Decision: Apply ADR-11's write-performance constraint to this child's implementation and release
  evidence, including indirect CPU/GC/pool/checkpoint effects where applicable.
  Rationale: The user explicitly prioritizes performance, especially writes. A confirmed regression
  requires correction; unchanged append SQL alone is insufficient evidence.
  Date: 2026-10-09

- Decision: Extract one normalized constraint name from PostgreSQL's quoted message first, using
  detail only as a compatibility fallback, and compare names for equality.
  Rationale: Equality removes the `events_pkey`/`stream_events_pkey` substring collision and makes
  branch ordering irrelevant. A fallback preserves behavior for synthetic or older error shapes
  that placed the name in detail.
  Date: 2026-08-27

- Decision: Treat `stream_events_pkey` during append as `DuplicateEvent` and
  `ux_stream_events_stream_version` as `UnexpectedServerError "23505"`.
  Rationale: An append of the same caller-supplied event to its original stream is idempotency
  duplication. A duplicate `(stream_id, stream_version)` should be prevented by append
  serialization and signals an invariant or SQL defect, not a caller's expected-version mismatch.
  Date: 2026-08-27

- Decision: Leave genuinely unknown unique constraints on the existing conservative
  `WrongExpectedVersion` fallback for this plan.
  Rationale: Changing the public fallback for constraints Kiroku does not own would broaden
  compatibility impact. Known internal corruption is handled explicitly.
  Date: 2026-08-27


## Outcomes & Retrospective

Implementation (2026-10-10): exact constraint extraction and the stream-version
invariant branch are implemented, with one extractor shared by every existing
unique-constraint mapper. All 49 mapping cases and both duplicate-append cases
pass. The initial 43-case pre-change table had 26 failures. The full store suite
passes 423 examples; `just perf-check` passes 20 structural checks and all 16
controlled workloads (117.74 seconds). Formatting and strict ADR validation
pass. This child is Complete. ADR-14 records the durable constraint-name and
error-taxonomy contract. Retained transcripts and SHA-256 identities are in
`kiroku-store/bench/results/ep5-unique-violation/`. These existing gates do not
prove cumulative cohort performance neutrality; EP6 retains that comparison.
No schema, public type, success-path query or retry behavior changes.


## Context and Orientation

Current implementation (2026-10-10, `5805117`): the shared exact-name extractor
and all four append branches are implemented and accepted by the focused/full
suites and existing ADR-5 gates. The following source audit is historical.

Historical source audit (2026-10-09, `e6ea664`): implementation was Not Started.
`kiroku-store/src/Kiroku/Store/Error.hs:mapUniqueViolation` still tests `events_pkey` using
`Text.isInfixOf`, then stream-name uniqueness, then `WrongExpectedVersion`. It has no exact
`stream_events_pkey` branch and no `ux_stream_events_stream_version` invariant branch. The
existing duplicate-event and transient-transaction coverage does not replace the planned
constraint-collision table. No dedicated current BUG/IR record covers these two remaining
mapping defects. IR-7 concerns append lock ordering and is outside this plan. This remains an
independent error-path fix with no new success-path database or handler work.

`kiroku-store/src/Kiroku/Store/Error.hs` defines `StoreError` and maps Hasql
`UsageError` values through `mapUsageError`, `mapServerError`, and `mapUniqueViolation`. The
unique mapper now extracts a single exact name and distinguishes all four owned constraints.
Unknown constraints retain `WrongExpectedVersion` with a placeholder actual version.

The bootstrap and later performance migrations define three relevant event constraints.
`events_pkey` is the primary key on caller-supplied `event_id`.
`stream_events_pkey` is the link-table key `(event_id, stream_id)`.
`ux_stream_events_stream_version` is the unique index on `(stream_id, stream_version)`.
The names are a durable interface to the mapper and must remain pinned by tests if migrations
change.

Existing append/error tests are in `kiroku-store/test/Main.hs`; link-specific coverage is in the
same suite. Add a narrowly named `Test.UniqueViolationMapping` module if that makes the table
clearer, and register it in the test main/cabal stanza. [ADR-14](../adr/0014-unique-constraint-names-define-error-classification.md)
records exact constraint identity and the caller-duplication/internal-invariant boundary;
the change does not alter ADR-7's hard-delete lock order.


## Plan of Work

### Milestone 1 — pin every owned constraint

Add table-driven pure tests that construct representative Hasql server errors with each known
constraint in the message and, separately, in detail. Assert:

- `events_pkey` becomes `DuplicateEvent` with the parsed event id;
- `stream_events_pkey` on the append mapper becomes `DuplicateEvent` with the first composite id;
- `ix_streams_stream_name` becomes `StreamAlreadyExists`;
- `ux_stream_events_stream_version` becomes `UnexpectedServerError "23505"`;
- an unknown unique constraint retains the documented `WrongExpectedVersion` fallback.

Include the collision case whose message contains only `stream_events_pkey` and would previously
enter the `events_pkey` branch. Where private helpers are not exported, exercise them through
`mapUsageError` rather than widening the production API for tests.

### Milestone 2 — classify exactly and prove the append surface

In `Error.hs`, factor a small internal constraint extractor for PostgreSQL's
`unique constraint "<name>"` message. Compare known names with equality. When only detail contains
a recognizable name, use delimiter-aware matching rather than raw substring matching. Reuse the
existing event-id parsers appropriate to scalar and composite keys.

Add the explicit `stream_events_pkey` and `ux_stream_events_stream_version` branches, then update
the module's SQLSTATE table and stability warning. Add an integration test that appends one event,
retries the identical event id against the same stream, and asserts `DuplicateEvent (Just id)`
with no extra event or link row.

If a safe integration fixture can induce the stream-version invariant violation without disabling
constraints or corrupting shared state, assert `UnexpectedServerError` there too. Otherwise the
synthetic server-error test is the required proof and the reason must be recorded in Surprises &
Discoveries.


## Concrete Steps

Run from the Kiroku repository root:

```bash
cabal build kiroku-store:kiroku-store-test
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "unique violation mapping"'
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "duplicate event ID"'
```

The transcript must include examples equivalent to:

```text
unique violation mapping
  does not match stream_events_pkey as events_pkey [OK]
  reports stream version uniqueness as an unexpected server error [OK]
duplicate event
  returns the caller event id and leaves one stored event [OK]
```

Then run:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
```


## Validation and Acceptance

[ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md) forbids added successful-append work for this error-only change.
Verify that constraint extraction remains exclusively on the failed-statement path: no success-path
string parsing, queries, instrumentation, or retry changes. Run the existing append performance
gates. The integrated release in plan 85 also compares mixed write workloads against the original
pre-cohort control; exact error classification cannot be used to waive that gate.

Every owned constraint name must map by equality, regardless of branch order. A
`stream_events_pkey` message must never be parsed through the scalar `events_pkey` branch. A
repeated caller event id must return `DuplicateEvent` carrying that id and leave database counts
unchanged. The stream-version invariant must preserve SQLSTATE and message in
`UnexpectedServerError` and must never become `WrongExpectedVersion`.

The existing stream-name, transaction, link, transient-transaction, and expected-version mapping
tests must remain green. Haddocks and changelog must describe exactly the same table as tests.


## Idempotence and Recovery

Pure tests and isolated database tests are repeatable. The production change is an error-mapping
decision made after PostgreSQL has already rolled back the failed statement; it performs no
recovery write. Reverting the mapper restores old classification without a schema rollback. Do
not rename database constraints in this plan.


## Interfaces and Dependencies

No public type or function is added. `Kiroku.Store.Error.StoreError` retains its existing
constructors and `mapUsageError` retains its signature. The internal mapper recognizes these exact
names:

```text
events_pkey
stream_events_pkey
ix_streams_stream_name
ux_stream_events_stream_version
```

Use the existing Hasql error types and `text` dependency. No external package or migration is
required.

Revision note (2026-10-09): Audited current source, tests, migrations, and related records at
`e6ea664`; retained unfinished milestones, documented existing baseline and actual request
coverage, and refreshed integration/performance context. This is a documentation update, not
implementation or new runtime-test evidence.

Revision note (2026-10-09, write-performance requirement): Applied ADR-11 and blocking write-path
acceptance, with per-child ownership and evidence requirements. The user explicitly prioritizes
write performance. Implementation and benchmark gates remain open.

Revision note (2026-10-10, implementation): completed exact extraction and focused
regressions; corrected the literal Hspec pipe filter, shared extraction across the
existing mappers and distilled the durable boundary into ADR-14. Full acceptance
checks remain in progress.

Revision note (2026-10-10, acceptance): complete EP5 after 423 passing store
examples, 20 structural checks, 16 controlled workload cases and strict ADR
validation. Preserve the failed pre-change and zero-example filter transcripts;
reserve cumulative original-control acceptance and release for EP6.
