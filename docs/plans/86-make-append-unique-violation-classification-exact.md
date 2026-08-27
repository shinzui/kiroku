---
id: 86
slug: make-append-unique-violation-classification-exact
title: "Make append unique-violation classification exact"
kind: exec-plan
created_at: 2026-08-27T21:14:52Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
---

# Make append unique-violation classification exact

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku classifies PostgreSQL `23505` failures by constraint name. The append mapper tests
`events_pkey` before `stream_events_pkey`, so the latter matches the former as a substring and is
classified accidentally. It also lets the invariant constraint
`ux_stream_events_stream_version` fall through to `WrongExpectedVersion` even though that
violation does not represent a caller precondition mismatch.

After this plan, exact constraint classification distinguishes a duplicate caller event id from
an already-linked pair and from internal stream-version corruption. Pure mapping tests pin every
constraint, and a database regression proves retrying the same event id against the same stream is
reported deterministically without disguising an invariant failure as an expected-version race.


## Progress

- [ ] M1: add table-driven mapping tests for `events_pkey`, `stream_events_pkey`, `ux_stream_events_stream_version`, stream-name, and unknown unique constraints.
- [ ] M2: make append constraint matching exact and order-independent, retaining event-id extraction where valid.
- [ ] M2: map the stream-version invariant constraint to `UnexpectedServerError "23505"` and add a real append duplicate regression.
- [ ] Update error Haddocks/changelog, run focused and full store tests, and perform ADR distillation.


## Surprises & Discoveries

- Transfer audit (2026-08-27): link-specific and transaction-generic mappers already test
  `stream_events_pkey` explicitly, but `mapUniqueViolation` still starts with the substring
  `events_pkey`. The primary append path therefore depends on branch text rather than an exact
  constraint token.
- Transfer audit (2026-08-27): released Kiroku 0.8 already maps `40001` and `40P01` to
  `TransientTransactionFailure`. This plan does not reopen transaction retry taxonomy.


## Decision Log

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

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`kiroku-store/src/Kiroku/Store/Error.hs` defines `StoreError` and maps Hasql
`UsageError` values through `mapUsageError`, `mapServerError`, and `mapUniqueViolation`. The
unique mapper currently recognizes `events_pkey` and `ix_streams_stream_name` by `Text.isInfixOf`;
everything else becomes `WrongExpectedVersion` with a placeholder actual version.

The bootstrap and later performance migrations define three relevant event constraints.
`events_pkey` is the primary key on caller-supplied `event_id`.
`stream_events_pkey` is the link-table key `(event_id, stream_id)`.
`ux_stream_events_stream_version` is the unique index on `(stream_id, stream_version)`.
The names are a durable interface to the mapper and must remain pinned by tests if migrations
change.

Existing append/error tests are in `kiroku-store/test/Main.hs`; link-specific coverage is in the
same suite. Add a narrowly named `Test.UniqueViolationMapping` module if that makes the table
clearer, and register it in the test main/cabal stanza. No Kiroku ADR governs this local taxonomy
detail, and the change does not alter ADR-7's hard-delete lock order.


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
  --test-options='--match "unique violation mapping|duplicate event"'
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
