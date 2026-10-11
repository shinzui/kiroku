# MP13 implementation-review validation — 2026-10-11 UTC

The unchanged workload gate passes on the dedicated PG18 cell. Cumulative
inspection-overhead acceptance remains **inconclusive**: no controlled observer
trial or original-control pair completed successfully. Nothing was published.

## Evidence obtained

- `gate/gate/fetched/output/workload-gate.log`: all **16 tests passed**, 13.52 seconds
  inside the workload. The pipeline/sequential ratios were 0.69 and 0.70 against
  the unchanged 0.90 ceiling; append-category was 0.99 against 1.05. All read gates
  passed. This compares the existing workload variants, not two runtime revisions.
- `gate/gate/fetched/cell/health.json`: all cell health gates passed. Durability was
  on, PG 18.3, and the database reset verified. No gate thresholds were relaxed.
- `verification.json`: independent verification of all 30 manifest-listed artifacts
  across the failed observer proof (14) and passed workload gate (16), including
  bytes and SHA-256. The cellctl verification transcripts agree.
- `structure.log`: 41 performance-structure tests passed, including the two browse
  query-plan checks now included in that group. This ran on the shared checkout,
  including concurrent plan 97 tests. Remote runtime sources exclude that work.
- `proof-local.json.gz` and `proof-local-control.json.gz`: candidate delivered
  44,404 ordered frames with exact names; control delivered 35,087 ordered frames.
  Both passed v2 validation. These are correctness proofs, not timing acceptance.
- `oracle.log`, `validator-tests.log`, `controller-tests.log`: the delivery oracle,
  12 malformed-evidence cases, and four controller failure/recovery checks pass.
  The existing 116 passing metrics tests from the implementation review remain
  applicable to the unchanged MP13 runtime. Those tests cover cache retention at
  4,096 entries and cold/warm/empty lookup behavior; live cache size was not sampled.

The candidate is `109d58f57dbd5757ad55792474d046a37cc2e87d`; the released control is
`364ffa82136fcfc83d39ead1234abffaf500844b`. Both were built from isolated git archives
with identical external dependencies. `payload.json` identifies the actual Linux
closure. `payload-source/` preserves its source before subsequent formatting,
entry-log capture and controller corrections. `protocol.json` retains the original
preparation record; it is not rewritten to pretend later fixes were present then.

## Failures, recovery and stop decision

The one-hour clock began at 04:16:12 UTC, before setup, and ends at 05:16:12 UTC.
`budget.json` is the sole budget; recovery never restarted it.

1. Initial startup failed the infrastructure owner's active-project check. No trial
   was submitted. The lease released and all instances remained stopped. The same
   journal resumed with explicit `tan-nb-exp` environment settings.
2. Observer proof `01a12941-6e5e-740e-8e81-76ad2e1a731b` sealed and hash-verified, but
   failed before measurement because the unprivileged benchmark role could not
   create `pg_stat_statements`. All original logs are retained under `proof/`.
3. A unique diagnostic template was added to the controller. Its initial IAP SSH
   attempt failed before creating a database or submitting a trial. An operator
   interrupt arrived during shutdown; explicit recovery verified lease release and
   all four instances stopped. This is recorded in `proof-template/setup-attempt-0/`
   and the recovery journal, not counted as a measured trial.
4. The unchanged workload gate passed as run
   `01a1294a-329d-73f0-b429-5e4a49f21642`. Its lease released and all four instances
   reached TERMINATED (`gate/journal.json` and `gate/power-after.json`).
5. The next observer setup attempt found alpha leased by the concurrent plan 97
   experiment. Acquisition failed safely; that lease and its run were not changed.
   Its busy response is retained in `proof-template/lease-acquire.stderr`.

A successful lifecycle proof (420-second admission allowance) plus five active
pairs (1,180 seconds including cleanup) no longer fit the remaining original
budget, even before waiting for the other lease. Remote work stopped early.
`completion.json` records zero verified remote observer trials, zero pairs, and no
owned remote execution or lease. The cell may be running for the other owner;
our shutdown evidence describes our own completed gate lifecycle.

The earlier failed local workload run and wide observer intervals remain retained
in `../evidence/`. This successful dedicated-host gate supersedes the *current
workload-gate status* only. It neither erases those samples nor establishes a
zero-regression result for the added index, HTTP polling or event-name enrichment.
The known index write/WAL cost remains part of cumulative acceptance.

## Remaining acceptance work

Use a new explicitly recorded experiment budget for a later attempt. First prove
template setup, ordered delivery, SQL diagnostics, verification and cleanup on one
small run. Then admit only the affected inactive/active cases that fit the measured
forecast. Retain five pairs per case and the original zero-slowdown/95%/6% policy.
The opaque probe also needs benchmark-grade normalization and checkpoint-symmetry
evidence before claiming formal acceptance. Do not treat an incomplete queue,
bootstrap-only interval or successful health check as that verdict.
