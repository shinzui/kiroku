---
id: 85
slug: release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption
title: "Release the subscription hardening cohort and coordinate downstream adoption"
kind: exec-plan
created_at: 2026-08-27T21:14:25Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
provenance:
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      verdict: "changes-requested"
      note: "Perf review: release gate omitted ADR-5 perf-check and perf-telemetry"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      mode: "update"
      note: "Added perf-check and perf-telemetry to the release gate"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T00:37:26Z
      mode: "update"
      note: "Design review: updated forecast of public-surface changes and migrations for the release gate and clean-consumer proof"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T01:21:50Z
      mode: "update"
      note: "Design review, second pass: wider Keiro adoption scope, Checkpoint-module resize, ConsumerGroupSize, ADR-8"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-09T16:21:16Z
      mode: "update"
      note: "Audit source at e6ea664; distinguish completed baseline from remaining work, refresh request coverage and performance evidence requirements"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T18:48:29Z
      mode: "update"
      note: "Apply user PostgreSQL 18-only testing scope."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T00:17:55Z
      mode: "implement"
      note: "Reserve focused cumulative release comparison within user one-hour ceiling."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T02:48:14Z
      mode: "implement"
      note: "Begin integrated release readiness and bounded original-control evidence."
---

# Release the subscription hardening cohort and coordinate downstream adoption

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Plans 81, 82, 83, 84, and 86 change Kiroku behavior and public surfaces across the store,
migrations, observability consumers, and Shibuya adapter. Source-only completion is insufficient:
downstream users need a coherent published package set, and Keiro must consume Kiroku's supported
consumer-group resize operation instead of reaching into checkpoint tables.

After this plan, every affected Kiroku package has a PVP-correct independently versioned Hackage
release, matching source/docs archives, annotated tag, and GitHub release. A clean external
consumer resolves the cohort. In `mori://shinzui/keiro`, shard-count changes use the released
transaction-composable resize API to update Kiroku checkpoints and Keiro lease rows atomically;
the old transferred plan stays retired. No publication or downstream commit occurs without the
user's explicit release-time confirmation.


## Progress

- [x] (2026-10-10) Complete the user-authorized tail repeat with 12 valid trials, six new pairs and zero replacements; retain separate inconclusive reports, pooled fingerprint rejections and the failed full telemetry command plus focused diagnostic. Cleanup and collection finish within one hour; all VMs stopped and no lease.
- [x] (2026-10-10) Diagnose live-batch checkpoint accounting and complete the authorized bounded follow-up: 13 valid benchmark trials, three adapter pairs and two fan-out pairs; retain the cancelled final candidate, all adverse evidence and zero replacements. Cleanup and collection finish within the fixed one-hour budget.
- [x] (2026-10-10) Integrated practical performance acceptance: the user explicitly approves the bounded evidence and continuation to version review under ADR-11. Original zero-regression comparisons remain inconclusive and pooling rejected; adverse telemetry and uncertainty are preserved. Metadata and publication remain gated.
- [x] (2026-10-10) Gate: plans 81, 82, 83, 84, and 86 are Complete; current living sections, strict ADR validation and the configured capability gate pass. The lifetime member-guard plans 93/92 remain outside this cohort and unimplemented.
- [x] (2026-10-10) M1: verify all six current Hackage versions and upstream peeled tags, audit changed APIs and discover registered dependents. Exact proposed Cabal/bound/changelog patch is retained in `kiroku-store/bench/results/ep6-release/proposal/`; practical performance acceptance is approved; metadata confirmation is the next gate.
- [ ] M1: present exact package versions, bounds, and changelogs for user confirmation before editing release metadata.
- [ ] M2: update approved versions/bounds/changelogs and pass formatting, build, test, ADR-5 performance, migration, sdist, Haddock, and flake gates.
- [ ] M3: after a second explicit publication confirmation, commit, tag, push, publish Hackage/docs and GitHub releases in dependency order; verify clean-consumer resolution.
- [ ] M4: adopt the released public resize operation in `mori://shinzui/keiro` and prove atomic shard/checkpoint resizing without private Kiroku SQL.
- [ ] Record release URLs, tag commits, clean-consumer evidence, downstream commit, and retrospective.


## Surprises & Discoveries

- (2026-10-10) Cross-session pooling is rejected for a 4096-byte reported driver
  memory difference across VM boots; no input or policy is rewritten. The new
  three-pair adapter p99 interval narrows to -4.17%..+4.47%, but strict acceptance
  remains inconclusive. Full historical telemetry times out AnyVersion new-stream
  append while its focused unchanged-method diagnostic passes; retain both.

- (2026-10-10) Follow-up diagnosis proves the checkpoint gate assumed the wrong
  batching unit. AllStreams live delivery consumes publisher batches (maximum
  1000), independently of the subscription fetch limit. Both original control
  and candidate save once per delivered batch. Six actual-adapter local probes
  each delivered 1000 events and drained durable progress; table-update deltas
  exactly equalled observed batch counts (969, 992, 995, 939, 961, 897), including
  after idle and longer flush checks. Ten distinct pool backends were flushed.
  The harness now requires exact equality to delivery batches; event delivery,
  durable progress, durability and regression thresholds remain unchanged.
- (2026-10-10) The authorized follow-up has a fixed 03:31–04:31 UTC whole-work
  budget, including diagnosis, builds, submission, verification and cleanup.
  The two previously timed-out telemetry cases passed under unchanged CPU-time,
  baseline and timeout settings in 96.00 seconds: NoStream append 125 µs (32%
  below historical baseline), exhausted-category read 17.9 µs (reported same).
  The original full telemetry failure is retained; this focused repeat does not
  replace it. Tasty-bench uses CPU-time adaptation by default while its hard
  timeout is wall time, so I/O-heavy cases can time out; this is a plausible
  timing explanation, not proof of the original timeout cause.

- (2026-10-10) The initial real-adapter control errored on the unchanged
  checkpoint-frequency invariant after 44,545 steady deliveries. Sampler table
  counters lag observed load totals, consistent with cumulative-statistics lag,
  but exact failed locals were missing and the cause remains unproven. Stop the
  queue, retain the cancelled candidate, and add pre-failure diagnostic snapshots
  without relaxing the assertion or retrying a trial. Historical telemetry also
  timed out its NoStream new-stream append and exhausted-category cases.

- (2026-10-10) Payload publication requires a `./` or absolute flake root; the
  initial relative root failed before upload. The queue also requires integer
  `estimateMinutes`; a fractional planning estimate refused before creating a
  remote session. Both preparation failures are retained and corrected without
  replacing a performance trial or restarting the original clock.

- (2026-10-10) All six Hackage preferred-version responses match the latest
  upstream package-specific peeled tags. The migration package has no direct
  kiroku-store dependency, contrary to the release skill's package description;
  retain the normal publication order but do not invent a dependency bound.
- (2026-10-10) The retained harness lacks successful-hook fan-out and diagnostic
  activation. Small matched extensions add two independent live all-stream
  subscribers and an identity hook, plus a wrapper enabling the candidate's
  60-second watchdog. The initial formatter rejected CPP inside a do-block;
  preparation stopped before remote trials and was corrected with complete
  helper definitions. Original failure logs are retained.
- (2026-10-10) The publisher supports only released/head cohort names. The
  diagnostic wrapper uses the same verified head identity through an isolated
  root exporting it as kenshou-head; it changes no production package or operator
  source. Disabled/enabled costs are reported separately and descriptively.

- Refresh audit (2026-10-09): source, tests, and changelogs confirm the remaining acceptance
  work is unimplemented; the dated Context audit distinguishes existing baseline from this plan.
- Transfer audit (2026-08-27): the July source plan forecast `kiroku-store` 0.4 and adapter 0.5.
  Current source is already `kiroku-store` 0.8.0.0 and `shibuya-kiroku-adapter` 0.5.1.1. No
  forecast version from the transferred plan is usable release evidence.
- Transfer audit (2026-08-27): Kiroku packages are versioned and tagged independently. A store API
  change may require bound-only patch releases of internal dependents even when their runtime
  behavior did not change.
- Transfer audit (2026-08-27): Keiro already refuses a startup `ShardCountMismatch` but offers no
  supported resize. Its `ensureShards` transaction inserts missing lease rows before it checks
  recorded counts, so a resize operation must be separately named and atomic rather than weakening
  that startup guard.


## Decision Log

- Decision (2026-10-10, explicit user acceptance): the user replied “accept let's continue” to the recommendation to accept the bounded cumulative evidence practically and proceed to version review. Close EP6's practical performance decision under ADR-11, preserving the inconclusive separate policies, rejected cross-session pooling, adverse telemetry and statistical uncertainty. No threshold, fingerprint, raw result or durability contract changes. This supersedes the prior inconclusive-measurement release block for this retained evidence; a reproducible append regression still blocks release. Metadata confirmation and later publication confirmation remain separate gates. Evidence and scope: `kiroku-store/bench/results/ep6-release/practical-acceptance.md`.

- Decision (2026-10-10): continue with a bounded repeat of the two affected paths
  after the user's instruction, reusing verified builds and calibration. Keep
  the original policy, rejected pooling and all adverse samples; do not count
  focused telemetry diagnostics as accepted replacement trials. No further
  queue or release action follows automatically from these results.

- Decision (2026-10-10): Defer version approval and publication while diagnosing
  the cumulative measurement failure. The user authorized this follow-up after
  the premature release proposal was corrected. Preserve the closed experiment
  and all invalid/adverse evidence; do not reset the new one-hour clock or loosen
  the statistical policy. Correct checkpoint accounting to the actual delivered
  batch unit and verify a small remote run before expanding coverage.

- Decision (2026-10-09): required testing for this cohort uses PostgreSQL 18.
  The user explicitly removed PostgreSQL 17 testing; preserve already collected
  PostgreSQL 17 evidence without requiring more trials. ADR-11 and the parent
  MasterPlan carry this scope correction.

- Decision: Apply ADR-11's write-performance constraint to this child's implementation and release
  evidence, including indirect CPU/GC/pool/checkpoint effects where applicable.
  Rationale: The user explicitly prioritizes performance, especially writes. A confirmed regression
  requires correction; unchanged append SQL alone is insufficient evidence.
  Date: 2026-10-09

- Decision: Do not choose package versions until every implementation plan is complete and current
  Hackage versions plus upstream tags have been verified.
  Rationale: PVP impact depends on the final exported types and semantics. The local Mori corpus is
  for source discovery and may lag authoritative release state.
  Date: 2026-08-27

- Decision: Follow the repository release skill exactly, including independent package versions,
  dependency order, and user confirmation before release metadata edits and publication.
  Rationale: A master plan does not broaden authority to commit, tag, push, or upload packages.
  The skill captures Kiroku's established release invariants.
  Date: 2026-08-27

- Decision: Release Kiroku before changing Keiro and adopt only public transaction-composable APIs.
  Rationale: Downstream bounds and compilation must be based on a retrievable artifact. Composing
  Kiroku checkpoint resize with Keiro lease-table resize in one Hasql transaction avoids the split
  state that private sequential SQL would create.
  Date: 2026-08-27

- Decision: Keep Keiro release out of scope unless separately authorized.
  Rationale: The acceptance target is downstream source adoption and test evidence. Publishing
  Keiro is a separate external action with its own release process.
  Date: 2026-08-27


## Outcomes & Retrospective

On 2026-10-10 the user explicitly accepted the retained bounded evidence practically and authorized continuation to version review. The practical performance decision is complete; statistical equivalence remains inconclusive, pooled operator comparisons remain rejected and full telemetry failures remain retained. No additional experiment is queued. EP6 remains In Progress for metadata approval, final artifacts, publication, clean-consumer verification and downstream adoption. See `kiroku-store/bench/results/ep6-release/practical-acceptance.md`.

The user-authorized tail repeat completed 12 additional valid trials, three
adapter pairs and three successful-hook fan-out pairs, without replacements.
Cleanup completed in 37.50 minutes from the conservative fixed 04:43:41–05:43:41
UTC clock; collection finished in 38.82 minutes. All four VMs are TERMINATED,
with no lease or quarantine. The new adapter throughput estimate is +0.39%
(95% -2.88% to +3.77%) and p99 +0.06% (-4.17% to +4.47%); new fan-out throughput
+1.60% (+0.89% to +2.31%), p99 -1.12% (-5.23% to +3.17%). The earlier +26.80%
adapter p99 increase did not reproduce and remains retained. Separate session
policies remain inconclusive. Pooling six adapter/five fan-out pairs is rejected
by the unchanged operator because reported driver memory differs by 4096 bytes
across VM boots; raw fingerprints and both infrastructure-failure reports are
preserved. Pooled estimates are descriptive only: adapter throughput +2.13%,
p99 +1.77% (95% -9.72% to +14.74%); fan-out throughput +2.25%, p99 -3.34%
(-7.76% to +1.29%). No strict pass or zero-regression proof is claimed.

The unchanged full historical telemetry repeat passed 29/30 cases but timed out
`AnyVersion (new stream)` after 100 seconds. Its focused repeat passed in 58.71
seconds through setup/cleanup without replacing the full failure. Exhausted-category
reads were 28% above the historical baseline; this adverse CPU-time telemetry is
retained. No further experiment is queued. Source and release metadata are
unchanged; practical performance acceptance is now approved by the user; metadata approval, publication and downstream adoption remain open. Evidence: `kiroku-store/bench/results/ep6-tail-repeat/README.md`.

EP6 is In Progress. All five implementation children are Complete. Integrated
`cabal build all` and `cabal test all --test-show-details=direct` pass (554 examples
across six suites), as do all six current-version `cabal check` runs and native
Nix formatting/pre-commit checks. The cumulative comparison stopped under its predeclared failure rule: its first
baseline adapter trial errored on checkpoint frequency, and the next candidate
was cancelled. Both sealed artifacts are independently hash-verified; zero valid
benchmark trials or matched pairs exist, with no replacements. Cleanup completed
25.14 minutes after the original clock began; all four VMs are TERMINATED, with
no lease or quarantine. Original statistical policy remains unchanged and the
gate is inconclusive. Historical telemetry failed two of 30 cases with 100-second
timeouts; the full adverse output is retained.

The separately authorized follow-up corrected a proven invalid batching
assumption and obtained 13 valid trials before its fixed cleanup cutoff. It has
three adapter pairs and two successful-hook fan-out pairs, plus calibration,
one descriptive diagnostic run and an unmatched fan-out baseline. The final
candidate scenario passed, but the cell was cancelled after the cutoff; all
sealed artifacts are verified and excluded from acceptance. Zero replacements
were used. All VMs are stopped, with no lease or quarantine; collection finished
within the 03:31–04:31 UTC budget. Adapter throughput +3.91% (95% -0.27% to
+8.27%), p99 +3.52% (-33.37% to +60.84%); fan-out throughput +3.23%
(-18.30% to +30.44%), p99 -6.59% (-31.64% to +27.66%). No candidate-specific
slowdown is confirmed, but zero regression and tail-latency safety remain
inconclusive. The original statistical policy is unchanged. The focused repeat
of both CPU telemetry timeout cases passed in 96.00 seconds without replacing
the original failure. Full evidence: `kiroku-store/bench/results/ep6-diagnosis/`.
Version review now proceeds on the explicit practical acceptance recorded above.

Authoritative release scope and the exact proposed metadata patch are retained in
`kiroku-store/bench/results/ep6-release/`. Package metadata remains unchanged
pending version confirmation. No release commit, tag, push, upload or downstream
change has occurred. Final archives, publication, clean-consumer proof and Keiro
adoption remain outstanding.


## Context and Orientation

Current audit (2026-10-10, production commit `5805117`): all five implementation
children are Complete; migrations 0013 and 0014 and the resize, rebind, typed
decode and opt-in stall APIs are implemented. Current Hackage/tag truth, proposed
versions and exact edits are retained under `kiroku-store/bench/results/ep6-release/`.

Historical source audit (2026-10-09, `e6ea664`): at that point all five
implementation children were Not Started. Checked-in versions are store 0.9.0.1, migrations 0.6.0.0, adapter 0.5.1.5,
otel 0.2.0.10, metrics 0.1.0.10, and CLI 0.2.0.8. The migration manifest ends at `0012.sql`.
These are checkout observations, not fresh Hackage/tag verification or a proposed next cohort.
The releases recorded in their changelogs contain lifecycle cleanup, category indexing, and
publisher heap fixes, not the missing resize/rebind/typed-decode/stall APIs. None completes this
release plan or establishes downstream adoption of those absent APIs.

Preserve the existing migration-0012 cutover constraints in
[ADR-10](../adr/0010-category-reads-use-a-denormalized-category-index-on-all-rows.md). EP-3 and
EP-4 supply focused correctness and structural evidence for reads/live fan-out and
real acknowledgements; the synthetic overhead benchmark does not measure the real
adapter. Select the integrated release comparison from these changed paths and
remaining risks, alongside `just test-pg 18` and the existing ADR-5 gates. Recheck the independently owned member-guard
plans 93/92 and their release state before selecting the final package diff.

Kiroku's repository release instructions are in `.agents/skills/release/SKILL.md`. Publishable
packages, in dependency order, are `kiroku-store`, `kiroku-store-migrations`, `kiroku-otel`,
`kiroku-cli`, `kiroku-metrics`, and `shibuya-kiroku-adapter`. Only packages changed since their
last package-specific tag need a release, but a new `kiroku-store` major/minor line can require
dependent bound updates and corresponding patch releases. `kiroku-test-support` and example/test
components are not Hackage packages.

Plans 81 and 82 change checkpoint public APIs and each adds a migration; plan 82's migration also
drops `stream_name`. Plan 83 changes the type of `decodeHook` in `StoreSettings`, adds an
`undecodableHandler` subscription field and a `StopUndecodable` stop reason, and adds a
`StoreError` constructor, a dead-letter reason, and an observability constructor. Plan 84 adds a
store subscription config field and observability constructor and changes both adapter config
records, including their batch and buffer size types. Plans 81 and 82 replace runtime
configuration checks with validated types (`BatchSize`, `StreamBufferSize`, `ConsumerGroupSize`)
and add an exception-hierarchy parent for runtime startup refusals. Plan 86 is an internal bug
fix. Their final diffs, not these forecasts, determine PVP, but `kiroku-store` will be a major
bump. Relevant durable records are
[ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md),
[ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md),
[ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md),
and any ADR created by plan 83 or 84.

Use Mori to discover reverse dependencies with `mori registry dependents shinzui/kiroku
--packages --json`, but verify released versions against Hackage and package tags. The release
skill requires all package tests, `nix fmt`, `cabal build all`, `cabal test all`, and
`nix flake check` before publication, then `cabal check`, source archive, and Hackage Haddock
archive per package. This plan additionally requires the
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) gates `just perf-check` and
`just perf-telemetry`, because plans 81 through 84 change the checkpoint upsert, the publisher
loop, and the adapter bridge; the MasterPlan's Performance gates integration point names the
telemetry cells to report.

The downstream repository is `mori://shinzui/keiro`. Its project-relative
`keiro/src/Keiro/Subscription/Shard.hs` defines `ensureShards` and
`ShardCountMismatch`; `keiro/src/Keiro/Subscription/Shard/Schema.hs` owns the
`keiro_subscription_shards` transaction statements. `ensureShards` currently proves startup
topology matches but cannot resize it. The transferred source master plan is
`mori://shinzui/keiro/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review`
and remains a historical transfer record.


## Plan of Work

### Milestone 1 — establish release truth and obtain approval

Confirm all five implementation child plans are complete. Inspect each publishable package's
current Cabal version, newest `<package>-v*` tag, commits since that tag, changelog, and public API
diff. Query Hackage and upstream tags at execution time. Use Mori reverse dependencies to identify
registered consumers, then inspect in-repository dependency bounds.

Produce a review table with package, current authoritative version, last tag, change set, proposed
PVP bump, dependent bound edits, and justification. Show every proposed Cabal/changelog edit.
Stop and request user confirmation as required by the release skill. Do not edit versions merely
because this plan has reached the gate.

### Milestone 2 — prepare and verify the approved cohort

Apply only the approved independent bumps. Update every internal dependency bound in library, test,
executable, and benchmark stanzas; add dated changelog sections. Plans 81 and 82 each add a
migration; prove both fresh installation and upgrade from the newest released manifest snapshot,
including that plan 82's column addition rewrites no rows.

Run repository-wide formatting/build/test/flake gates, then `just perf-check` and
`just perf-telemetry`; record the telemetry cells named in the MasterPlan's Performance gates
integration point against their baseline rows. Select and run the bounded cumulative comparison specified below, reusing valid
child evidence. The synthetic overhead benchmark does not establish real adapter
cost. Run the PostgreSQL 18 tests. Run `cabal check`, `cabal sdist`, and
Hackage Haddock generation for each proposed package without uploading. Inspect each source
archive for its public modules, migration manifest/payload, changelog, license, and generated
documentation. Stage newly created files before `nix flake check` so Nix sees them, but do not
commit.

Present the final diff, test matrix, archive names/hashes, and package order. Request explicit
confirmation before commit, tags, push, or upload.

### Milestone 3 — publish and independently verify

After confirmation, create one Conventional Commit release commit, one annotated package tag per
released package, and push commit plus tags. Upload source and documentation archives in dependency
order; stop immediately if any dependency upload fails. Create one GitHub release per tag.

Refresh package metadata and build a clean temporary consumer outside the worktree using exact
published versions. Import the new store resize and rebind operations, the typed decode hook, the
startup-failure parent, the handler-stall event, and the adapter config fields, run a minimal
compile, and record Hackage URLs, hashes, annotated tag objects/peeled commits, GitHub release URLs,
and consumer transcript in Outcomes.

### Milestone 4 — adopt safe resize in Keiro

Only after Hackage verification, update `mori://shinzui/keiro` dependency bounds to the released
cohort. In its project-relative `keiro/src/Keiro/Subscription/Shard/Schema.hs`, add transactional
helpers that lock the complete subscription lease-row set and refuse resize while any owner is
active. Add `resizeShardCount` in `keiro/src/Keiro/Subscription/Shard.hs`. In one
`Hasql.Transaction.Transaction` it must:

1. construct Kiroku's `ConsumerGroupSize` from the new count, whose `Either` is the validation,
   and lock existing Keiro shard rows;
2. refuse with typed `ShardResizeActiveLeases` unless every owner is clear;
3. call Kiroku's released `resizeConsumerGroupTx` for the same subscription;
4. replace Keiro rows with buckets `0 .. newSize - 1` and the new recorded count;
5. return both Kiroku's resume position/report and Keiro's old/new topology.

Adopting the released cohort in Keiro is wider than the resize seam. Keiro must construct its
subscription configuration through `mkBatchSize` and `mkConsumerGroup`, classify the new
`EventDecodeFailed` store error as non-transient in its error mapping, decide whether its
projections supply an `undecodableHandler` or accept the default stop, catch
`SomeSubscriptionStartupFailure` in its worker supervisor and align `ShardCountMismatch` with
Kiroku's `ConsumerGroupSizeMismatch`, and update any decode hook it configures to the typed
result. Record each of these in the Keiro change alongside the resize adoption.

Retain `ensureShards` as a strict startup guard. Add tests for active-lease refusal, idempotent
same-size resize, deliberately skewed Kiroku checkpoints, atomic rollback after injected failure,
and post-resize delivery with no missing event ids. The test must import the released public
module and contain no SQL against `kiroku.subscriptions`. Update Keiro's shard documentation and
transferred-plan status. Commit only if separately authorized by the user; do not release Keiro in
this plan.


## Concrete Steps

Run the whole integrated cohort against the original pre-cohort control, not only each child's
immediate predecessor, to expose cumulative costs. Present each write scenario separately with
uncertainty and raw results. Reproducible default-path append regressions keep the release gate open. The user’s explicit practical acceptance on 2026-10-10 closes the evidence decision for the retained cumulative results despite statistical inconclusiveness, without changing the comparison policy or claiming equivalence. Proceed to metadata review; publication still requires its own approval and artifact checks. Separately report opt-in watchdog cost and preserve the existing structural/controlled append gates.

Run release preparation from the Kiroku repository root:

```bash
mori registry dependents shinzui/kiroku --packages --json
git tag --list '*-v*' --sort=-version:refname
nix fmt
cabal build all
cabal test all --test-show-details=direct
just test-pg 18
nix flake check
just perf-check
just perf-telemetry
```

For every package approved for release, from its package directory:

```bash
cabal check
cabal sdist
cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump
```

The release skill supplies the exact commit, tag, upload, and GitHub commands once the versions
are known. Do not substitute placeholder versions into executable commands. Expected pre-release
evidence has this shape:

```text
package                         PVP decision   source archive   docs archive   tests
kiroku-store                    <approved>     present          present        PASS
shibuya-kiroku-adapter          <approved>     present          present        PASS
<affected dependents>           <approved>     present          present        PASS
```

After publication, run from a fresh temporary consumer and record exact version constraints:

```bash
cabal update
cabal build all
```

Then run from `mori://shinzui/keiro`:

```bash
cabal build keiro:keiro-test
cabal test keiro:keiro-test \
  --test-show-details=direct \
  --test-options='--match "shard count resize"'
cabal test keiro:keiro-test --test-show-details=direct
```


## Validation and Acceptance

Integrated write-performance acceptance (user direction, 2026-10-09):
[ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
reserves one focused cumulative append comparison for this release stage. Reuse
retained valid evidence and original control `e6ea664`; select cases from actual
changed paths and unresolved risks, including confirmed live hook fan-out and
real adapter acknowledgements with diagnostic tracking disabled/enabled where
applicable. PostgreSQL 18, durability, compiler/RTS/pool settings and delivered
work must match. Keep append SQL/round trips and checkpoint frequency unchanged.

Before any remote run, declare cases, trial count, warmup/measurement durations,
setup/reset/recovery overhead, uncertainty target and stop conditions. The entire
experiment must finish within the user's one-hour ceiling, including cleanup;
pass the remaining budget forward and never restart it. Prove submission/result
verification/lease release with a small run or reuse a verified recovery check.
Use a bounded persistent controller with retained results and release its lease
on every exit. No universal matrix, five-pair minimum or 1%/3% resolution mandate
requires expanding a queue. Preserve the original statistical policy and all
unmatched, interrupted, inconclusive and adverse evidence. Report uncertainty
honestly; a reproducible append regression still blocks release. If useful
precision cannot fit, report the conflict before launching or keep acceptance
inconclusive. Never change durability or post-hoc thresholds to manufacture a pass. For the retained EP6 results, the user explicitly approved practical acceptance on 2026-10-10 with these limitations preserved; no further experiment is required to proceed to metadata review.

All Kiroku child-plan acceptance tests, ADR/OKF gates, ADR-5 performance gates (with
focused integrated coverage selected above), PostgreSQL 18 package tests,
migration paths, source archives, Haddocks, and flake checks must pass before publication. Hackage
source/docs versions, annotated tags, GitHub releases, and peeled commits must agree. A clean
consumer must resolve only published artifacts and compile the new APIs.

Keiro acceptance requires an active lease to refuse before either table changes; a stopped
skewed-size group must atomically equalize Kiroku checkpoints and replace Keiro shard rows; a
forced transaction failure must leave both old topologies intact; repeating the operation must be
idempotent; and new workers must deliver every seeded event id at least once. No downstream
module, test, or documentation may use private Kiroku checkpoint SQL.


## Idempotence and Recovery

Readiness checks, builds, tests, archive generation, and clean-consumer verification are
repeatable. Version/changelog edits remain uncommitted until approved and can be corrected with a
new patch. Never overwrite a published Hackage version or move an existing tag.

If an upload fails, stop before publishing any dependent and resume with the same immutable
archive after diagnosing it. If a package was published but a later dependent fails, record the
partial cohort honestly and publish the dependent only after its gate passes. The Keiro resize
transaction is atomic and repeatable; at-least-once rewind may duplicate deliveries but cannot
lose events. External publication and commits are not implied by executing earlier milestones.


## Interfaces and Dependencies

Versions are intentionally unspecified until milestone 1. Release order is:

```text
kiroku-store
kiroku-store-migrations
kiroku-otel
kiroku-cli
kiroku-metrics
shibuya-kiroku-adapter
```

Only changed packages and dependents needing new bounds are published. Kiroku source discovery
uses `mori://shinzui/kiroku` and downstream discovery uses `mori://shinzui/keiro`; Hackage and
upstream tags remain authoritative for release selection.

Keiro's public adoption surface has this semantic shape:

```haskell
resizeShardCount ::
    (Store :> es) =>
    SubscriptionName ->
    Int ->
    Eff es ShardResizeResult
```

`ShardResizeResult` includes Kiroku's `ConsumerGroupResizeReport` plus old/new Keiro counts.
`ShardResizeActiveLeases` identifies the subscription and active buckets without exposing private
Kiroku schema. The implementation composes the released
`Kiroku.Store.Subscription.Checkpoint.resizeConsumerGroupTx` with Keiro's Hasql transaction;
no new external dependency is expected beyond the approved Kiroku bound.


Revision note (2026-09-09): Performance review under ADR-5. Added `just perf-check` and
`just perf-telemetry` to the release gate in Progress, Context, milestone 2, the concrete steps,
and acceptance, with the telemetry cells owned by the MasterPlan's Performance gates integration
point.

Revision note (2026-09-09): Design review. Updated the forecast of public-surface changes from
plans 82, 83, and 84 (typed decode hook, `RetryPolicy` record, startup-failure parent, worker
stall event, two migrations) so the release gate and the clean-consumer proof cover them.

Revision note (2026-09-09): Design review, second pass. Widened the Keiro adoption milestone to
cover validated configuration constructors, the new store error classification, the undecodable
handler choice, the startup-refusal parent, and any typed decode hook; corrected the resize
module and report names; cited ADR-8.

Revision note (2026-10-09): Audited current source, tests, migrations, and related records at
`e6ea664`; retained unfinished milestones, documented existing baseline and actual request
coverage, and refreshed integration/performance context. This is a documentation update, not
implementation or new runtime-test evidence.

Revision note (2026-10-09, write-performance requirement): Applied ADR-11 and blocking write-path
acceptance, with per-child ownership and evidence requirements. The user explicitly prioritizes
write performance. Implementation and benchmark gates remain open.

Revision note (2026-10-09): EP6 owns the cumulative append comparison within the one-hour whole-experiment ceiling; supersede obsolete mandatory matrices and unbounded precision escalation while retaining original evidence and regression policy.

Revision note (2026-10-10): Retain authoritative scope and exact metadata proposal,
passing integrated correctness/packaging/document checks, failed historical
telemetry and the stopped cumulative experiment. No matched performance result
is available; diagnostic capture improves future failures while preserving the
original invariant and no-replacement rule. Approval, final archives, publication
and Keiro adoption remain outstanding.

Revision note (2026-10-10): Defer release approval; diagnose live publisher batching with six exact local adapter checks and retain the focused CPU telemetry repeat. The follow-up uses one fixed 03:31–04:31 UTC budget. Remote evidence remains pending.

Revision note (2026-10-10): Close the authorized follow-up within one hour, retain 13 valid trials and the cancelled final candidate, report five matched pairs plus descriptive diagnostic cost, and keep p99/statistical acceptance and release open. All remote resources are stopped.

Revision note (2026-10-10, tail repeat): preserve 12 new valid trials/six pairs, cross-session fingerprint rejections, adverse full telemetry and its focused diagnostic; narrow the non-reproduced adapter tail signal without claiming strict acceptance. Performance, metadata approval and publication remain outstanding.

Revision note (2026-10-10, explicit practical acceptance): record the user’s approval to close the cumulative performance decision and proceed to version review. Preserve all strict verdicts, rejected pooling, adverse telemetry and uncertainty; package metadata and publication still require their own confirmations.
