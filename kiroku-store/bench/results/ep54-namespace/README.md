# Category namespace implementation evidence — 2026-10-26

The feature is functionally implemented. Performance acceptance remains blocked:
no remote benchmark executed and no comparison pairs exist. The available cell
client rejects the deployed descriptor's `instances.broker` field before uploading
work. This is FRIC-8 in `docs/friction-log/`, affecting
`mori://shinzui/load-testing-infra`. Its project-relative implementation is
`nixos/pkgs/cell-agent/src/src/bin/cellctl.rs` (artifact-level URI pending);
`submit` decodes the descriptor before reading or uploading a submission.

## Correctness and structural checks

The PostgreSQL 18 store suite passes **522 examples**, the adapter suite passes
**45**, and migration suites pass **25** examples on each of PostgreSQL 17/18.
The focused namespace group passes **26 examples** on both majors. These cover
catch-up/live/restart, groups, literal boundary semantics, deletion gaps, Stop,
Retry, dead letters, filtering, decode refusal, ordinary/atomic save failure,
fetch reconnect, listener reconnect, notification races, safety polling, and
registration cleanup. `full-store-final.log.gz`, `full-suites.log.gz`,
`namespace17-final.log.gz`, and `migrations17.log.gz` retain the checks.

`explain.jsonl.gz` retains **96 production EXPLAIN ANALYZE/BUFFERS cases** on PG18:
custom/generic plans, 1,000/20,000 global rows, windows 32/1024, dense/sparse/absent
matches, first/tail cursors, and plain/grouped statements. `explain-summary.json`
records rows, payload loops, buffers and sort space. Every case seeks the global
index and examines at most W visible global rows. Absent namespaces execute
zero payload-probe loops. The largest observed buffer count is 3,090 and largest
sort is 193 KiB; these payload-query measurements do not reuse the prototype's
nine-buffer metadata-only bound. MVCC visibility and dead tuples can add physical
work outside these clean fixtures.

`structure.json` verifies unchanged bodies for four append and two exact-category
SQL statements, unchanged append/publisher source, and byte-identical released
migrations 0001–0015. Migration 0016 alters only subscription checks and the schema
comment. There is no added stream/event index, append column or trigger, or
publisher decoding work. Namespace-disabled notification handling still pays an
empty-registry check, and store startup allocates the registry. This does not
establish runtime neutrality. Each namespace/group worker scans global history
independently; safety polling also traverses unrelated new rows.

`local-proof.json.gz` retains a final-query proof of **25,076** total appends
and **254** ordered namespace matches with the existing
category and inspection load. The namespace delivery oracle compares every
received position with the database's ordered matching positions and verifies
its checkpoint. Local timing is diagnostic and supplies no release verdict.

## Controlled comparison attempt and cleanup

`protocol.json` declares disabled and sparse-active cases with five alternating
pairs each, 10 seconds warmup and 30 seconds measurement. The original control
is `364ffa82136fcfc83d39ead1234abffaf500844b`; the isolated candidate source is
`c5ca341` (`sources.json`). The comparison would include cumulative inspection and
namespace cost, rather than assigning this feature a fresh slowdown allowance.
The 95% interval, 6% maximum width and zero-slowdown policy are unchanged.

The sole 60-minute budget began before build/setup (`budget.json`). The final
Linux closure was built and published (`payload.json`, `linux-build.log.gz`).
Setup failures and recovery were retained in the same proof journal. Missing
operator tools, an older Python and an unusable default SSH identity were
resolved before descriptor validation. The final client-side rejection prevented
upload; the journal's one failed row is a **submission intent**, not a remotely
executed or verified trial. `submission-absence.log` and `result-absence.log`
independently confirm no work/result objects under that run ID. No paired queue
was admitted, no adverse sample was replaced, and no statistical result exists.

`completion.json` and `power-final.json` prove the final state: lease released
and absent, diagnostic template removed, all four cell instances stopped, and
temporary OS Login key revoked and removed. No owned remote execution remains.
The experiment stopped early on an unsupported interface; unused budget was not
converted into retries or a weaker gate. A future attempt requires a compatible
client/deployed descriptor and a new explicit experiment budget. Keep this
failed attempt and its zero-trial count visible.

## Yujin development-machine authorization follow-up

At the user's request, the three Yujin public keys already authorized on
Sungkyung were registered without expiration in the current OS Login account.
A separate exclusive lease was used to start only the PostgreSQL machine and
verify IAP SSH directly from Yujin using its existing identity. The remote commands
returned the cell hostname, the expected OS Login username, and `postgres` from
`sudo -n -u postgres psql`. No private keys were copied. The PostgreSQL machine
was stopped again, the lease released, and all four cell machines verified
stopped. `oslogin-yujin/registered-keys.json` and `verification.json` retain the
public fingerprints and checks. FRIC-9 is now resolved. This fixes development
SSH access; the distinct deployed-descriptor/client mismatch still blocks the
performance comparison, and no additional benchmark was submitted.

## Preferred performance path selected afterward

The user selected `mori://shinzui/keiro-runtime-kenshou` as the preferred way to
run performance tests. Its current master source
`2129bb917da811ef1e90198d91db873cc8d05b7b` declares an optional broker on cell nodes,
parses `instances.broker`, and includes the optional VM in lifecycle handling.
Thus the rejection above belongs to the old direct `cellctl` path. Source
inspection establishes field support, not a successful live Kenshou submission.

Use the owner's exact-revision pairing and verification workflow. The current
subscription benchmark covers all/category targets and the quick performance
catalog contains uncalibrated Shibuya profiles. Namespace-specific coverage and
an appropriate explicit comparison are still needed. No existing quick profile
or earlier cohort acceptance can stand in for this feature's release evidence.
No new benchmark was run and no experiment clock was restarted for this decision.
