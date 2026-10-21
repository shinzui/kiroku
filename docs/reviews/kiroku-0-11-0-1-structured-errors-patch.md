---
type: Review
title: Kiroku 0.11.0.1 structured script error patch
description: The 0.11.0.0 to 0.11.0.1 patch preserves SQLSTATE and server messages from script and statement failures through every error mapper, keeps connection loss and pool timeouts typed, adds no work to any append, read or subscription hot path, is covered by a new store suite and updated sanitization tests, and its one behavioural change, typed constructors replacing the ConnectionError catch-all on pool-backed reads, is documented and already handled by keiro's transient-error classification.
generated:
  by: process:claude-code
  at: "2026-10-21T13:57:37Z"
reviewId: REV-4
subject: mori://shinzui/kiroku
subjectKind: project
reviewedSha: 084fd8359850342447cdda8e632b7dc456c7fca4
coverage: incremental
baseSha: 7394055de458bef8f6ec2e68231f3ca7932bb9be
previousReview: REV-3
reviewedAt: "2026-10-21T13:57:37Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5-1
effort: high
outcome: approved
dimensions:
  - correctness
  - performance
  - test-coverage
  - documentation
  - operability
context: >-
  Reviewed the eight commits between the kiroku-store-v0.11.0.0 tag and the
  kiroku-store-v0.11.0.1 / kiroku-metrics-v0.3.0.1 release commit. The whole
  source and test diff (kiroku-store Error.hs, Effect.hs, Transaction.hs,
  kiroku-metrics JSON.hs, the new ScriptSessionErrors suite and the updated
  metrics sanitization specs) was read in full by this reviewer. Repository
  HEAD at e2cdc892 differs from the reviewed commit only under docs/releases
  and .seihou, so the gates run at HEAD apply to the reviewed source. The
  keiro consumer's StoreError classification was read at keiro HEAD to judge
  the downstream effect of the behavioural change.
---

# Kiroku 0.11.0.1 structured script error patch

## Verdict

Approved. The patch does what its changelog says and nothing else. Script
failures raised through `Tx.sql` now carry their PostgreSQL SQLSTATE and
message exactly as prepared-statement failures already did, session-level
connection loss maps to `ConnectionLost`, and the shared pool helper used by
public reads returns the existing typed constructors instead of flattening
every usage error into `ConnectionError`. No constructor was added, no SQL
changed, and no retry policy changed.

## What changed

| File | Change |
| --- | --- |
| `kiroku-store/src/Kiroku/Store/Error.hs` | `mapGenericUsageError`, `mapSessionError` and `extractServerError` gain the `ScriptSessionError` and `ConnectionSessionError` arms. |
| `kiroku-store/src/Kiroku/Store/Effect.hs` | `usePool` maps the pool usage error through `mapGenericUsageError` instead of `ConnectionError (show err)`. |
| `kiroku-store/src/Kiroku/Store/Transaction.hs` | Haddock only: documents the error contract of `runTransaction` and `runTransactionNoRetry`. |
| `kiroku-metrics/src/Kiroku/Metrics/JSON.hs` | `storeErrorResponse` keeps 503 for `ConnectionLost`, `PoolAcquisitionTimeout` and `TransientTransactionFailure`; permanent server errors stay 500. |

## Correctness

- The script arm reuses `mapServerError`, so a script `23505` still resolves
  to `DuplicateEvent`, `StreamAlreadyExists` or the expected-version fallback
  by exact constraint name, and `40001` / `40P01` still resolve to
  `TransientTransactionFailure`. The new suite asserts this for every mapper
  (`mapGenericUsageError`, `mapTransactionUsageError`, `mapUsageError`,
  `mapLinkUsageError`, `attributeMultiStreamError`) across five SQLSTATEs.
- `ConnectionSessionError` is matched before the generic session arm in both
  `mapGenericUsageError` and `mapSessionError`, so a dropped connection is
  `ConnectionLost` and not a `ConnectionError` string. Driver errors keep the
  `ConnectionError` catch-all, which the changelog states.
- `usePool` is the only call-site change. Every `Store` interpreter case that
  reads through it (stream, `$all`, category, causation, metadata, browse,
  dead-letter and checkpoint reads) now surfaces `ConnectionLost`,
  `PoolAcquisitionTimeout`, `TransientTransactionFailure` or
  `UnexpectedServerError` where it previously surfaced `ConnectionError`. The
  changelog records this and tells callers matching only the catch-all to
  handle the specific constructors.
- Transactions roll back before the error is returned: the suite proves an
  application write and a composed append are both absent after a script
  failure.

## Hot-path performance

No timing experiment was needed and none is claimed. The only runtime change
is on the error branch of `usePool`; the success branch is untouched, no
statement, round trip or allocation was added to any append, read, publisher
or worker path, and the metrics change is in a response constructor reached
only after a store failure. The release record's statement that no timing
experiment was needed is consistent with the diff.

At repository HEAD, whose package source equals the reviewed commit, the
authoritative gates from ADR-5 pass: `just perf-structure` (41 examples,
0 failures, including the browse and stream-head plan checks) and
`just perf-workload-gate` (16 cases passed, pipeline ratios 0.86x and 0.87x
against the 0.90 ceiling, every category-read ratio at or below 0.39x). The
`append-category-column` cell of that gate also passed, but its control arm
is not a valid measurement on this host; that is a finding of REV-1, where
the cell belongs, and it does not bear on this error-path patch.

## Test coverage

- New `Test.ScriptSessionErrors` (14 examples): missing relation through both
  transaction runners, `40001` and `40P01` through script and prepared
  statement, rollback of side writes and composed appends, the pool-backed
  public read, genuine connection establishment failure, every contextual
  mapper, constraint attribution and the session-loss / timeout / unsupported
  split. A regression in any arm added by this patch would fail here.
- Metrics: the browse, checkpoints, dead-letters and CORS specs each gained
  the five new typed failures and assert the body never contains the server
  text, and that HEAD mirrors GET status and headers.
- Retained release logs show 487 store and 117 metrics examples passing at
  the release commit.

## Documentation and downstream

- Both changelogs describe the behaviour change and its scope accurately.
  The `runTransactionNoRetry` Haddock now says serialization failures surface
  as `TransientTransactionFailure` instead of `ConnectionError`, matching the
  code.
- No upgrade-blueprint edge was added for the patch. That is acceptable: the
  change needs judgement only from a consumer that matched `ConnectionError`
  as a catch-all, and the changelog names that case. keiro, the first-party
  consumer, already classifies `ConnectionLost`, `PoolAcquisitionTimeout` and
  `TransientTransactionFailure` as transient and `UnexpectedServerError` as
  permanent in `Keiro.ProcessManager.isTransientStoreError`, so a missing
  relation reported by a script is now halted rather than retried, which is
  the correct direction.
- The release record under `docs/releases/2026-10-20-structured-script-errors`
  retains publication hashes, served-documentation checks and a clean external
  consumer pinned to the published versions.

## Limits

- No remote cell was used and no timing experiment was run for this patch;
  the hot-path claim rests on the diff and the local ADR-5 gates.
- The eight commits were read as one increment at the release commit; the
  intermediate commit states were not built separately.
