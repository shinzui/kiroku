---
id: 98
slug: preserve-structured-script-session-errors
title: "Preserve structured script session errors"
kind: exec-plan
intention: intention_01m5badt87ew6r2zqx6n8hqvch
created_at: 2026-10-20T00:11:11Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-20T00:11:11Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-20T00:14:27Z
      mode: "other"
      note: "Complete initial plan from source inspection, link IR-19, and associate the user-requested Mina intention."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-20T00:19:29Z
      mode: "implement"
      note: "Implement structured script errors, public PostgreSQL regressions, and HTTP compatibility."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-20T01:20:11Z
      mode: "implement"
      note: "Publish the approved store and metrics patch releases and verify the clean consumer."
---


# Preserve structured script session errors


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current during implementation.


## Purpose / Big Picture


Implement [IR-19](../improvement-requests/preserve-structured-script-session-errors.md)
so applications can classify PostgreSQL failures from script-backed store
transactions without parsing diagnostic prose. A missing table must surface as
`UnexpectedServerError "42P01" message`; serialization conflicts and deadlocks
must surface as `TransientTransactionFailure` with their original SQLSTATE.
SQLSTATE is PostgreSQL's five-character machine-readable error code.
Connection failures and pool acquisition timeouts must retain distinct types.

Rei exposed the problem in a disposable fixture: a missing application table was
rendered as `ConnectionError`, leading its HTTP policy to return a retryable 503
instead of a permanent 500. Repairing that fixture did not repair Kiroku's
classification. The consuming work is
`mori://shinzui/rei/plans/256-expose-operational-status-and-controlled-periodic-check-apis`,
under `mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract`.
This plan owns the Kiroku correction and supported-release evidence; downstream
adoption remains with that consumer. Functional implementation is complete;
publication remains a separate acceptance gate.


## Progress


- [x] (2026-10-20 00:24Z) Implement structured script and connection mapping at both store boundaries; all 13 focused cases pass.
- [x] (2026-10-20 00:27Z) Pass full PostgreSQL store suite (487 examples) and metrics suite (117 examples), zero failures; store suite includes performance structure checks.
- [x] (2026-10-20 00:27Z) Update error/transaction Haddock, both changelogs and ADR-20; audit production consumers and validate both OKF bundles.
- [x] (2026-10-20 00:28Z) Verify release baselines, prepare the two-package metadata proposal, build candidate sdists in an isolated copy, and pass candidate package checks.
- [x] (2026-10-20 01:20Z) Receive user approval ("let's release") for store 0.11.0.1 and metrics 0.3.0.1 and apply the reviewed metadata/changelogs.
- [x] (2026-10-20 01:30Z) Validate the actual release versions: full build, 487 store and 117 metrics examples, flake checks, package checks and Haddock archives pass; all 144 archived source files match the checkout and the source hashes match the approved candidates.
- [ ] Publish the approved packages and documentation, verify tags and source archives, and pass the clean published-consumer proof before closing IR-19.


## Surprises & Discoveries


The resolved build uses Hasql 1.10.3.7, hasql-pool 1.4.2.3 and
hasql-transaction 1.2.3.1. Mori-located tagged sources confirm the error
constructors and pool settings. `Tx.sql` takes UTF-8 bytes, while statement
construction takes text; the fixture encodes scripts explicitly.

Against the original mapping, the focused PostgreSQL group reported
`13 examples, 11 failures`: both transaction missing-table cases and the public
read flattened `42P01` to `ConnectionError`; script transients flattened too,
while the paired prepared cases passed. After the mapper correction it reported
`13 examples, 0 failures`. PostgreSQL DO blocks preserve both code and fixture
message; rollback assertions also prove no event or application row persists.

An initial overlapping bootstrap and regression build collided while renaming
an object file. This is a build orchestration failure, not a regression result;
subsequent Cabal commands run sequentially.


## Decision Log


- Decision: Reuse the existing `StoreError` constructors and mapping rules,
  extending script extraction rather than inventing a second error protocol.
  Rationale: callers already classify prepared-statement failures by these types.
  Date: 2026-10-20.
- Decision: Cover both transaction mapping and the shared `usePool` helper, and
  include the small local HTTP compatibility correction required by typed errors.
  Rationale: fixing only `mapSessionError` leaves both the transaction extractor
  and ordinary store reads capable of flattening errors; the existing metrics
  mapper recognizes only `ConnectionError` as unavailable.
  Date: 2026-10-20.
- Decision: Use focused real-PostgreSQL tests on one supported major and existing
  structural checks. Do not schedule remote benchmarks or a version matrix.
  Rationale: the change classifies failure results and adds no successful-path
  SQL, connection acquisitions, schema changes, or retry loop.
  Date: 2026-10-20.
- Decision: Propose patch releases `kiroku-store` 0.11.0.1 and
  `kiroku-metrics` 0.3.0.1 after verifying Hackage preferred versions and upstream
  tags. No API signatures, constructor set or HTTP envelope changes; this fixes
  classification to the existing typed error contract. Existing internal
  `^>=0.11.0.0` bounds already admit the store patch, so no dependent package
  needs a bound-only release. The unapplied proposal is
  `/tmp/ep98-release-metadata.patch`; changelog text is in each changed package's
  Unreleased section. The [release skill](../../agents/skills/release/SKILL.md) says:
  "Always ask the user to confirm the per-package version bumps and changelogs
  before committing." Obtain that confirmation after validation and before
  applying release metadata or creating release commits/tags.
  Date: 2026-10-20.


## Outcomes & Retrospective


The focused public-operation regressions pass with structured SQLSTATE and
message preservation, connection refusal remains typed, and rollback is verified.
Functional acceptance passes: the full store suite reports 487 examples with
zero failures and the full metrics suite reports 117 examples with zero failures.
The store run includes the existing performance structure group, so no separate
repeat or timing benchmark is required. Documentation and
[ADR-20](../adr/0020-store-boundaries-preserve-structured-server-errors.md) are
written and both OKF bundles pass strict validation. The production Haskell
source audit found only the shared metrics response mapper relying on the
`ConnectionError` classification; it now handles the typed unavailable cases.
Notification errors use Hasql's different connection error type; two benchmark
comparison helpers retain their own rendering outside production paths.
Both changed packages pass `cabal check` with no errors or warnings. `nix fmt`,
`nix flake check` (treefmt and pre-commit) and `git diff --check` pass.
The release-wide `nix develop .#postgresql18 --command cabal build all` also
passes, including dependent libraries, executables, tests and benchmark
components (compilation only; no timing experiment).

The actual full-suite command and concise results were:

```bash
nix develop .#postgresql18 --command cabal test kiroku-store:kiroku-store-test kiroku-metrics:kiroku-metrics-test --test-show-details=direct
```

```text
kiroku-store:   487 examples, 0 failures; PASS
kiroku-metrics: 117 examples, 0 failures; PASS
```

The functional implementation is committed as `f7b48b1`. Publication and the
clean published-consumer gate remain outstanding.


## Context and Orientation


`kiroku-store/src/Kiroku/Store/Error.hs` defines `StoreError` and the conversion
from Hasql's errors. Hasql is the PostgreSQL driver; its pool returns
`UsageError`, which distinguishes connection establishment, acquisition timeout,
and session execution failures. A session is work performed on a database
connection. Prepared statements report a `StatementSessionError` wrapping a
`ServerStatementError`; SQL scripts report `ScriptSessionError sql serverError`.
Both contain PostgreSQL's structured `ServerError`.

`mapSessionError` initially recognized only the statement branch and rendered
other session errors with `show`; `extractServerError` also recognized only
statements. Both now recognize structured scripts, and connection-session
failures map to `ConnectionLost`. That extractor feeds `mapGenericUsageError`,
`mapTransactionUsageError`, link and multi-stream handling, and
`isTransientSerializationError`. The latter recognizes exactly `40001` and
`40P01`, not every class-40 code. Generic mapping preserves unknown server codes
as `UnexpectedServerError`; stream-specific mapping additionally translates
known append conflicts. An opaque transaction has no stream identity, so it
must not fabricate one when translating foreign-key or uniqueness failures.

`kiroku-store/src/Kiroku/Store/Effect.hs` has two relevant execution paths.
`runTxOnPool` uses `mapTransactionUsageError`, whereas `usePool` initially rendered
all pool failures as `ConnectionError` and now uses `mapGenericUsageError`. The latter serves public reads and other
operations such as `getStream` and checkpoint inventory. There is no separate
public arbitrary-session runner to introduce: raw SQL is already available as
`Hasql.Transaction.sql` inside the public `runTransaction` and
`runTransactionNoRetry` functions in
`kiroku-store/src/Kiroku/Store/Transaction.hs`. `Tx.sql` executes a script;
`Tx.statement` executes a typed statement. Use the no-retry entry point for
persistent injected transient failures, because the retrying entry point may
repeat those failures indefinitely.

Tests live in `kiroku-store/test/`, registered in `kiroku-store/test/Main.hs`
and `kiroku-store/kiroku-store.cabal`. `Test/Transaction.hs` already covers opaque
foreign-key classification, duplicate events, and transaction rollback.
`Test/Helpers.hs` provides `withTestStore` and `withTestStoreSettings`, backed by
`kiroku-test-support/src/Kiroku/Test/Postgres.hs` and disposable migrated
databases. Existing transient mapping tests are in `Main.hs`; existing
constraint attribution tests are in `Test/UniqueViolationMapping.hs`.

`kiroku-metrics/src/Kiroku/Metrics/JSON.hs` initially mapped only `ConnectionError`
to a sanitized 503 response. The compatibility correction now handles `ConnectionLost`, `PoolAcquisitionTimeout`, and
`TransientTransactionFailure` as unavailable there. Permanent
`UnexpectedServerError` values use the existing sanitized 500 envelope. Extend
`kiroku-metrics/test/Test/CorsSpec.hs` and the relevant browse, checkpoint, and
dead-letter response cases. These value-level response tests supplement, rather
than replace, the real-store regressions.

Relevant architectural decisions are
[ADR-3](../adr/0003-dedicated-kiroku-schema.md),
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md), and
[ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md).
ADR-3 makes the configured store schema authoritative and keeps application
objects separate; qualify application fixture tables explicitly. ADR-5 favors
structural invariants where timing adds no useful evidence. ADR-9 keeps HTTP in
sister packages and freezes published response shapes; preserve envelope keys,
route-specific unavailable codes, and sanitized messages. No ADR specifically
covering script error extraction was found. Distill the final error-boundary
rule into an appropriate ADR during implementation, following
`.agents/skills/exec-plan/ADR.md` and the profiled `docs/adr/` contract.

Dependency source was located with Mori at `mori://hasql/hasql`. Its repository
handles are `mori://hasql/hasql/repos/hasql`,
`mori://hasql/hasql/repos/hasql-transaction`, and
`mori://hasql/hasql/repos/hasql-pool`. The Hasql 1.10.3.7 local tag confirms
`ScriptSessionError Text ServerError` and `ConnectionSessionError Text` in
`src/library/Hasql/Engine/Errors.hs` (artifact-level URI pending; path relative
to the Hasql repository handle). This is API-shape evidence, not a claim that
this is the newest upstream release. The store currently bounds Hasql to
`>=1.10 && <1.11`; the corpus working tree can contain newer API work, so inspect
the resolved version's source/tag before implementation. No dependency upgrade
is required by this design.


## Plan of Work


### Milestone 1: Preserve structured errors at both store boundaries


Add `kiroku-store/test/Test/ScriptSessionErrors.hs` and register it in the test
runner and Cabal module list. Start with a real missing-relation script through
`runStoreIO store (runTransaction (Tx.sql ...))` and through
`runTransactionNoRetry`. Use an explicitly qualified nonexistent application
table; require `Left (UnexpectedServerError "42P01" _)`. Record these cases
failing against the original mapping before fixing it. A third real-store case
must reach `usePool` through public `getStream`: use a bracketed test pool whose
search path deliberately excludes the store schema, attached to a fixture
handle for that call, so the unchanged read SQL encounters a missing relation
without damaging migrated objects or the healthy fixture's background workers.
Require the same typed `42P01` result.

In `Error.hs`, extend `extractServerError` for `ScriptSessionError _ serverError`
and extend `mapSessionError` to use the existing server mapper for that branch.
Keep stream-specific and generic mappings distinct. Map
`ConnectionSessionError detail` to `ConnectionLost detail` in both generic and
stream-aware session handling; connection establishment and acquisition timeout
keep their existing mappings. Preserve the legacy fallback for unsupported
non-server error constructors rather than pretending they carry a SQLSTATE.
In `Effect.hs`, replace the `usePool` rendered fallback with
`mapGenericUsageError`, adding the import. Do not add SQL or retry behavior.

Use focused constructor-level cases to cover the shared extraction branches,
transient predicate, connection/session distinction, pool timeout, and existing
append/link attribution. These cases check routing rules; public integration
cases prove the actual driver wrapping and store behavior. Run the focused
script group and the existing transaction and error groups. Milestone acceptance
is typed `42P01` from all three real public paths, with existing prepared
transaction and append conflict tests still passing.

### Milestone 2: Prove transient, connection, rollback, and consumer behavior


Extend the same integration group with script failures carrying `40001` and
`40P01`, generated by PostgreSQL `DO` blocks with `RAISE EXCEPTION USING
ERRCODE`. Exercise `runTransactionNoRetry`, not a retrying call around an
always-failing body. These are real PostgreSQL server-error propagation tests,
not a claim to have reproduced a contested-lock schedule. Add paired
`Tx.statement` cases to prove equivalent prepared-statement classification.
Use a known fixture message only when testing message preservation; classify
solely by constructors and SQLSTATE, never by rendered substring matching.

Before a failing script, write to an application fixture table and verify from
another transaction that the write rolled back. Also exercise
`runTransactionAppendingNoRetry` with an append followed by the missing-relation
script, verifying that no event or application row committed. Reuse existing
prepared duplicate-event and foreign-key tests to protect contextual mappings.
A real missing-table case satisfies IR-19's missing-relation-or-permission
requirement; an additional role/permission matrix is unnecessary.

Prove genuine connection establishment failure through public operations using
a separately bracketed Hasql pool aimed at a nonexistent Unix socket directory,
a bounded acquisition timeout, and a healthy fixture handle with only its pool
replaced for the failing call. Exercise both a no-retry transaction and a read;
require `ConnectionLost`, not `UnexpectedServerError` or the textual catch-all.
Read the resolved pool settings API through Mori when constructing this fixture.
Bracket pool lifetime independently of the healthy store; apply an outer timeout
so inability to acquire fails the test rather than hanging. Supplement this with
pure `ConnectionSessionError` and acquisition-timeout mapping cases. Do not stop
the shared PostgreSQL instance to simulate failure.

Update `storeErrorResponse` and its existing response tests as described above.
Preserve sanitized 503 for transport, acquisition, and transient transaction
failures, and sanitized 500 for permanent server failures. No response exposes
SQL, parameters, server messages, or connection strings. Run the full store and
metrics suites on the default PostgreSQL 18 development shell and the existing
store performance-structure group. Milestone acceptance is all these tests
passing, with no added successful-path queries or acquisitions and no new HTTP
endpoint or error-envelope fields.

### Milestone 3: Document, release, and close the request with evidence


Update the error and transaction Haddock comments and
`kiroku-store/CHANGELOG.md` to explain which operations now return more specific
existing constructors. Document the corresponding compatibility correction in
`kiroku-metrics/CHANGELOG.md`. Audit local `StoreError` matches for reliance on
the old catch-all and record the bounded audit result. Distill the durable
structured-error boundary decision into `docs/adr/`, preserving the distinction
between library classification and application retry decisions.

Prepare releases for the changed public packages using
`.agents/skills/release/SKILL.md`, including its versioning, validation, and
publication workflow. Verify current Hackage releases and upstream tags before
choosing versions or changed bounds; do not assume the IR's dated 0.11.0.0
baseline remains latest. Assess the observable constructor change under the
repository's PVP rules, and record the chosen bump and rationale. Release only
the packages required by the final changes and dependency constraints. Update
consumer bounds only against an actually supported release.

After publication, verify the package pages and matching tags and run a small
clean consumer against the published packages that reproduces the script
missing-relation classification without a local store override. Record exact
versions, revisions, test commands, and concise results here. Then change IR-19
to `completed`, link the release evidence, and append its bundle log entry.
Until publication is verified, distinguish locally implemented from released;
do not claim IR completion. Milestone acceptance is a verified supported
release plus the clean-consumer proof, not merely an sdist or a local test pass.


## Concrete Steps


Run commands from the repository root. Do not traverse `/nix/store`. Start by
checking the checkout and resolving dependencies through Mori:

```bash
git status --short
mori registry search hasql
mori registry show hasql/hasql --full
mori registry docs hasql/hasql
mori path mori://hasql/hasql/repos/hasql
mori path mori://hasql/hasql/repos/hasql-transaction
mori path mori://hasql/hasql/repos/hasql-pool
```

Read the returned repositories at the resolved versions before relying on their
APIs. If dependency bounds or pins must change, verify both the authoritative
package registry and upstream release tags first and record the reason here.

Use the describe label `structured script session errors` for the new group.
After registering it, run it against the old implementation to capture the
expected failure, then rerun after the mapper changes:

```bash
nix develop .#postgresql18 --command cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "structured script session errors"'
nix develop .#postgresql18 --command cabal test kiroku-store:kiroku-store-test --test-show-details=direct
nix develop .#postgresql18 --command cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct
nix develop .#postgresql18 --command cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "performance structure"'
```

The focused first run must fail because the expected structured value is a
`ConnectionError` instead. Final runs must report zero failures and a passing
test suite. A toolchain/bootstrap failure is not a regression result; retain it
separately and rerun after repairing the environment. Record actual test counts
and versions rather than inventing expected counts.

After meaningful IR or ADR edits, advance their timestamps and add the matching
log entry. Validate the bundles and the diff:

```bash
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
```

Record one implementation provenance revision with the plan skill's script and
verified runtime identity when implementation starts. Commits for this work use
Conventional Commits and include both `ExecPlan: docs/plans/98-preserve-structured-script-session-errors.md`
and the `Intention:` trailer from this file's frontmatter. Work on the current
branch unless the user requests otherwise.


## Validation and Acceptance


A real script missing-relation failure preserves `42P01` through both public
transaction runners, and a public read through the shared pool helper also
preserves it. Explicit PostgreSQL `40001` and `40P01` failures survive the
no-retry script boundary as `TransientTransactionFailure`, matching prepared
statements. A refused connection remains `ConnectionLost`; pool timeout and
connection-session routing remain separately covered. Failure rolls back both
application writes and composed event appends. Existing prepared-statement
conflict and foreign-key behavior remains valid.

The actual integration calls must use the real store and disposable PostgreSQL;
mock store interpreters and manually rendered-error matching cannot satisfy
these gates. Unit tests of mapping and response values are supporting evidence.
Metrics response tests prove that typed unavailability still yields sanitized
503 and permanent server errors yield sanitized 500 with existing envelope
shapes. Existing successful-path structural checks pass, and diff inspection
confirms that no SQL work or retry policy was added.

Functional acceptance and release acceptance are recorded separately. Full
IR-19 acceptance additionally requires the published supported version and a
clean consumer using it. No tests, publication, or performance outcomes are
claimed by this initial plan.


## Idempotence and Recovery


The tests create disposable databases and bracket every additional pool. Keep
fault injection local to those pools and application fixture tables; never drop
shared store tables or terminate the shared server. Bound failing connection
and transient tests with timeouts, and always release their resources. Repeated
test runs must not require manual schema repair.

If a fixture does not reach the expected driver branch, record the actual
structured value and repair the fixture; do not weaken assertions to accept
textual `ConnectionError`. Preserve failing evidence before rerunning. There
are no production migrations or data transformations. Preserve unrelated
working-tree edits during recovery. Before retrying publication, check whether
the version is already published and reconcile its immutable artifact and tag
according to the release workflow rather than uploading a different payload.


## Interfaces and Dependencies


Keep the public function signatures and `StoreError` constructor set unchanged.
`UnexpectedServerError Text Text` and `TransientTransactionFailure Text Text`
carry SQLSTATE then server message. `ConnectionLost Text` and
`PoolAcquisitionTimeout` identify transport/session and pool acquisition failures.
The mapping functions in `Kiroku.Store.Error` retain their current signatures;
`extractServerError :: UsageError -> Maybe Errors.ServerError` remains internal.
Use `mapGenericUsageError :: UsageError -> StoreError` in `usePool` and preserve
transaction-specific duplicate-event handling in `mapTransactionUsageError`.

The implementation uses the existing Hasql, Hasql pool, and Hasql transaction
packages from `mori://hasql/hasql`, the existing Hspec test suite, disposable
PostgreSQL fixtures, and the existing metrics response mapper. It adds no new
runtime dependency, database object, store effect constructor, HTTP route, or
consumer-specific retry policy.

Initial planning note (2026-10-20): created from IR-19 and source inspection;
linked the accepted request and the user-requested Mina intention. Implementation
and supported-release verification remain future work.

Implementation revision (2026-10-20): started public PostgreSQL regression coverage, HTTP compatibility tests, documentation and ADR-20; resolved driver APIs from tagged Mori sources.

Milestone 1 revision (2026-10-20): captured the original 11 failures and verified all 13 focused cases pass after the mapping correction. Full store, metrics and structural validation follow.

Release preparation revision (2026-10-20): checked registry and upstream tags, prepared an unapplied two-package patch-release proposal, and recorded the PVP rationale and required release confirmation.

Documentation revision (2026-10-20): updated baseline context to reflect the implemented mapper, documented the bounded consumer audit and passing package checks, and linked ADR-20.

Milestone 2/3 revision (2026-10-20): full PostgreSQL 18.4 store and metrics suites passed (487 and 117 examples). Structural checks passed within the store suite; formatting, flake and strict bundle checks passed. Release-wide build and confirmation remain.

Release artifact revision (2026-10-20): an isolated archive of `f7b48b1` with only
`/tmp/ep98-release-metadata.patch` applied produced
`/tmp/ep98-release-sdist/kiroku-store-0.11.0.1.tar.gz` (SHA-256
`0e941f8d39c9d588e50339e2765dbd857d7b7e3b00610e226bb496c160ad0b72`)
and `/tmp/ep98-release-sdist/kiroku-metrics-0.3.0.1.tar.gz` (SHA-256
`2936dc01ba37e0962adac0e3bd8501145718eed030d00e0f2a5c0dacc65583f6`).
Both proposed packages pass `cabal check`, and the store archive includes the
new regression module. These are unpublished candidate artifacts. The prepared
`/tmp/ep98-clean-consumer` pins store 0.11.0.1 and accepts a migrated disposable
database URL; it must run against the published package after approval and
publication, with no source override. If temporary files are unavailable,
recreate the proposal by changing only the two package versions and moving the
Unreleased changelog headings to those versions dated 2026-10-20 in an isolated
copy of the implementation commit.

Validation completion revision (2026-10-20 00:30Z): the release-wide build passed. Functional work and all local checks are complete. The plan remains open solely for required release confirmation, publication and clean published-consumer verification; IR-19 remains in progress.

Release authorization revision (2026-10-20 01:20Z): the user approved the prepared two-package release. Applied the reviewed metadata; release validation, publication and consumer verification are underway. No further version/changelog confirmation is required.

Release validation revision (2026-10-20 01:30Z): all approved-version checks passed, documentation archives were generated, and source archive hashes exactly match the reviewed candidates. Creating the release commit and annotated tags; publication and consumer verification follow.
