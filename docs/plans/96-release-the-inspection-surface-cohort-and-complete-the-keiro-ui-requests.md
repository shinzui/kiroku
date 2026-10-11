---
id: 96
slug: release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests
title: "Release the inspection surface cohort and complete the keiro-ui requests"
kind: exec-plan
created_at: 2026-09-30T22:35:20Z
intention: "intention_01m3t7a7jaeewbf71vqrzk4zd8"
master_plan: "docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T22:35:20Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:08Z
      mode: "update"
      note: "Correct current APIs, integration ownership and bounded observer work; runtime acceptance remains pending."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-11T01:31:56Z
      mode: "update"
      note: "Carry selected migration and unresolved original-control cost into release ownership"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-11T03:24:23Z
      mode: "implement"
      note: "Begin EP-7 integrated acceptance and release preparation"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:08Z
      verdict: "comments"
      note: "Source review corrections applied; SQL promotion and focused performance gates require implementation evidence."
---

# Release the inspection surface cohort and complete the keiro-ui requests

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current. It is EP-7 of
[MasterPlan 13](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md).


## Purpose / Big Picture

Publish the integrated inspection surface only after its APIs, compatibility and focused
performance gates pass. A consumer must be able to install the exact published
kiroku-inspect executable and build the library examples without this checkout.
Complete IR-8 through IR-12 with verified publication evidence, not only local source changes.
This plan publishes no UI and makes no downstream repository edits without authorization.


## Progress

- [x] (2026-09-30) Drafted the release coordination plan.
- [x] (2026-10-10) Reviewed current releases, cabal dependencies, typed decoding and performance obligations; superseded stale September version and benchmark scripts.
- [x] (2026-10-11) Confirm all six functional children Complete; retain their Progress/Outcomes in `bench/mp13-release/evidence/child-acceptance.txt`. Fresh `cabal build all -j1` and all six suites pass 672 examples.
- [x] (2026-10-11) Compile new-provider and every legacy-starter fixture against the proposed cohort; pass flake, capability, ADR and request validation.
- [ ] Pass cumulative performance acceptance: structural checks pass, but the aggregate workload gate has one retained failure; corrected local original-control diagnostics are complete and inconclusive; the final unchanged aggregate run also has a retained timing failure.
- [x] (2026-10-11) Verify Hackage/tag release truth, per-package diffs and matched dependency versions; prepare an unapplied six-package metadata/upgrade patch. Proposed versions are store 0.11.0.0, metrics 0.3.0.0, migrations 0.7.1.0, CLI 0.2.0.10, OTel 0.2.0.12 and adapter 0.6.0.1.
- [ ] Obtain concrete metadata/publication authorization after resolving performance acceptance.
- [x] (2026-10-11) Build the proposal in an isolated source copy; all six `cabal check` invocations pass, six public source archives are hashed/inspected, the proposed executable help passes and the appended upgrade blueprint validates.
- [x] (2026-10-11) Finish final proposal packaging: fresh full build, Nix executable, six Haddock archives, final new/legacy consumer compilation and both executable help checks pass. Source is `30307c1`; no artifact is uploaded.
- [ ] Publish and verify the authorized cohort after performance acceptance.
- [ ] Prove an exact-version clean consumer; complete requests and record outcomes.


## Surprises & Discoveries

The initial local comparison retains twelve verified trials and 567,808 measured appends. Its active adverse estimates and the six-trial cache-fix comparison (208,352 appends) are exploratory and confounded: only the candidate client retained stream names in the same process as the appenders. Preserve both sets, but do not diagnose production regression from them. Source inspection independently found `Map.keysSet cached` rebuilt all 4096 retained cache keys for each small batch. Commit `30307c1` replaces it with membership checks over requested ids; all 116 metrics examples pass, cache/lookup/wire behavior is preserved, and ADR-15 records batch-proportional work.

The corrected client retains original stream IDs and event positions in both arms, additionally checking candidate name presence. All six active trials verify: 296,504 measured appends, 355,809 exact tail events and 296 HTTP responses. Throughput is +4.968% with descriptive interval [-15.138%, +29.839%]; p50 -0.250% [-2.762%, +2.326%], p95 -12.257% [-47.540%, +46.755%] and p99 -21.676% [-70.418%, +107.374%]. Owned compilation has stopped, but other host work remains. These short shared-process diagnostics are inconclusive, not cumulative acceptance. No remote run/lease was started, no completed sample replaced, and the original 03:24:23–04:24:23 UTC budget was retained. The harness does not dynamically record lookup count, cache retention or SQL buffers; the required controlled-host evidence remains open.

All final proposed packages build from source `30307c1`, all six checks/source archives/documentation archives verify, and final new/legacy consumers compile. Both Cabal and Nix help checks pass. The older relocated build-directory attempt failed on vector unit identities; a fresh directory resolves the tooling failure without changing APIs or external bounds. The previous proposal and errors remain retained. See [release evidence](../../bench/mp13-release/evidence/README.md) for hashes, raw data and limitations.

2026-10-11 implementation: all proposed package baselines still point to released commit `364ffa82136fcfc83d39ead1234abffaf500844b`. CLI, OTel and the adapter have no source changes since their tags, so their patches only advance store bounds. Migration 0015 adds a schema feature without breaking the runner API: its proposal is 0.7.1.0. Metadata is staged outside the working tree, with the exact reviewable patch in `bench/mp13-release/evidence/release.patch`. No versions or changelog dates have been applied here.

The first aggregate workload run passes structural invariants and 15 of 16 timing cases, but category append is 1.57x its pre-0012 control (70.5 ± 87 ms versus 44.9 ± 40 ms). Parallel builds and another repository's tests were observed on this workstation. This is retained adverse evidence, not a regression diagnosis or permission to waive the gate. A local real-observer proof delivers 54,227 events exactly, resolves 27,116 names and completes 48 polls on verified durable PostgreSQL 18.6. Its two setup attempts and initial compile failure are retained. The comparison uses the same public starter on the released and integrated source; control polling intentionally gets its old 404 while candidate polling does the newly added reads. It is a preliminary diagnostic on a shared host, not controlled-host acceptance.

The three unchanged category-append focused repeats pass but retain high variance. The final unchanged full `just perf-check` completes in 210.03 seconds: structural checks pass, 14/16 workload cases pass, pipeline eight fails at 1.31x (1.71 ± 1.8 ms versus 1.30 ± 0.07 ms), and category append fails at 6.25x (48.3 ± 50 ms versus 7.74 ± 0.886 ms). Owned build jobs are stopped, while other host work remains. Retain both full failures and all three focused passes without diagnosing a source regression or waiving the gate. Stop further exploratory timings; investigate on a quiet controlled host before release. The local experiment finishes inside its original budget.

On 2026-10-10, Hackage preferred-version JSON and upstream annotated tags both identified
store 0.10.0.0 and metrics 0.2.0.0 as already released (tag targets
`364ffa82136fcfc83d39ead1234abffaf500844b`). Those were this plan's old future targets.
The checkout at `f1a0209` has store 0.10.0.0, metrics 0.2.0.0, CLI 0.2.0.9,
otel 0.2.0.11, adapter 0.6.0.0 and migrations 0.7.0.0. These are a dated snapshot,
not a reservation of future versions.

The migration package currently has no kiroku-store dependency. Do not copy the release
skill's older dependency summary or assume a fixed migration count. The existing blueprint
currently ends at the 0.8.0.2 -> 0.9.0.0 edge; inspect it again before adding guidance.
The shared publisher now carries DecodedBatch and expected read decode failures are typed.
The prior cohort's practical performance acceptance is not transferable to inspection load.


## Decision Log

- Decision (2026-10-11): retain both confounded comparisons and run one corrected active comparison with identical client bookkeeping; stop additional exploratory timing repeats after the unchanged aggregate check.
  Rationale: correct a known measurement flaw without replacing adverse samples or retrying until favorable. Shared-host intervals do not establish neutrality.
- Decision (2026-10-11): prepare a metadata patch and validate an isolated proposal without applying approved package metadata or publishing.
  Rationale: the release skill requires concrete version/changelog confirmation; performance acceptance is still open.
- Decision (2026-10-11): begin with a bounded local original-control diagnostic, retaining the existing policy verdict and failed workload gate.
  Rationale: the public HTTP/tail paths need real-load evidence, and this workstation has other active work. Remote calibration or a practical decision must not be inferred from exploratory timings.

- Decision (2026-09-30, retained): one coordinated release child owns version assignment,
  publication, clean-consumer verification and final request completion.
  Rationale: all six children must agree on one released surface and dependency set.
- Decision (2026-10-10): replace fixed old-version substitutions and archive counts with
  registry/tag verification and per-package diff review.
  Rationale: store 0.10 and metrics 0.2 already shipped; library constructor changes still
  require PVP review even when HTTP additions are compatible.
- Decision (2026-10-10): require a focused cumulative original-control comparison with real
  observers, not a mandatory full telemetry matrix or the old pipeline ratio as a proxy.
  Rationale: read-only observers share resources with appenders; ADR-15 applies ADR-11's
  proportional scope without inheriting its previous cohort's acceptance.
- Decision (2026-10-10): stop before publication absent authorization; honor explicit
  authorization already granted for this cohort without duplicate confirmation prompts.
  Rationale: a plan review does not authorize a release or cross-repository writes.


## Outcomes & Retrospective

2026-10-11 checkpoint: EP-7 is In Progress. Functional integration and final isolated release packaging are validated, with retained evidence under `bench/mp13-release/evidence/`. The requested-id cache optimization is committed and its 116 metrics tests pass. The authoritative workload gate is failed and cumulative observer acceptance is inconclusive; publication authorization and exact published-consumer proof remain pending. Documentation/Nix proposal packaging is complete. No package version, published artifact, tag, downstream state or request completion has changed.

Historical planning review: no implementation or benchmark was performed by that review; runtime acceptance remained pending.


## Context and Orientation

Hard dependencies are the checked-in plans
[90](90-add-configurable-cors-support-to-kiroku-metrics.md) (CORS and errors),
[87](87-serve-durable-subscription-checkpoints-over-http.md) (providers, checkpoints and lifecycle),
[88](88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md) (browse reads),
[89](89-expose-a-public-dead-letter-read-api.md) (dead letters),
[94](94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md)
(tail delivery) and
[95](95-serve-the-kiroku-inspection-surface-standalone-and-make-it-self-describing.md)
(discovery and standalone). All remain independently testable and leave versions unreleased.

Source packages live in their same-named root directories. Store has no internal runtime
dependency; CLI, otel, metrics and shibuya-kiroku-adapter currently depend on store.
Metrics also depends on CLI. kiroku-test-support is local test infrastructure, not a release.
Re-read every cabal stanza and query Mori dependents before deciding a cohort.
The approved browse design (ADR-17) adds migration 0015 and one partial C-collated
stream-name index. The migration package therefore joins the release cohort based
on its own schema change; re-derive its version from the actual diff. No separate
namespace or category/name replacement index is added.

[ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
freezes published wire contracts;
[ADR-12](../adr/0012-decode-failures-are-per-event-outcomes-with-independent-subscription-dispositions.md)
governs typed decoding;
[ADR-15](../adr/0015-inspection-observers-preserve-wire-contracts-and-bound-shared-work.md)
governs inspection compatibility and bounded work;
[ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
requires proportional performance evidence with no intentional append regression budget.

The new checkpoint path is /subscription-checkpoints, so /subscriptions/checkpoints still
names a valid live subscription. Existing route bodies and old starter signatures remain
published contracts. New read routes support GET/HEAD and structured sanitized errors;
HEAD has no body and other methods give 405 with Allow: GET, HEAD.

PVP versions have four components A.B.C.D. Store's closed effect gains constructors, so the
next release needs a major A.B bump; metrics adds exported config/record constructors, also
major. The current forecast is store 0.11.0.0 / metrics 0.3.0.0. Determine dependent bumps
independently: a bound-only package is not automatically major. Record source compatibility
for defaults-based record updates separately from positional or complete construction.

The requests are under docs/improvement-requests:
IR-8 expose-a-rest-read-api-for-browsing-streams-categories-and-events.md;
IR-9 expose-a-public-dead-letter-read-api.md;
IR-10 serve-durable-subscription-checkpoints-over-http.md;
IR-11 add-configurable-cors-support-to-kiroku-metrics.md;
IR-12 converge-the-websocket-protocol-with-the-cross-project-convention.md.
Their origin is `mori://shinzui/keiro-ui`. CAP-17 is
docs/capabilities/operational-http-endpoints.md. Preserve its original since version.
The downstream architecture contract is
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`; updates to another repository need
their own authority and use canonical Mori references.


## Plan of Work

### Milestone 1 — integrated API and proportional performance gate

First verify every dependency's Progress and acceptance, including prefix SQL's promotion
gate. A small output LIMIT without bounded query work is not accepted. Run builds and
focused correctness tests covering changed store constructors, umbrella exports, old starters,
typed failures, SQL parameter order, cursor boundaries, route collision, CORS Vary, mounted
WebSockets, capabilities versus real dispatch, readiness and shutdown, overflow ordering
and the 4096-entry cache. Run existing structural/workload controls required by
docs/PERF-REGRESSION-GATES.md. Existing tests must not be weakened to accommodate regressions.

Prepare one focused PostgreSQL 18 before/after comparison using an immutable pre-inspection
control and the integrated candidate, identical settings, dataset, hardware and load.
Include the inactive/disabled observer baseline and one representative active observer
workload: bounded browse/dead-letter polling plus a real WebSocket tail alongside appends.
Cover warm-name and distinct-name delivery within that workload and record lookup count,
cache retention, append throughput and latency, and actual SQL rows/buffers. Use the actual
production APIs, not an adapter-only catch-up benchmark.

Before remote execution, report the selected cases, paired trial count, warmup and
measurement durations, calibration/reset overhead, total wall time, comparison policy,
uncertainty target and stopping conditions. Start with existing valid evidence and the
smallest useful comparison; expand only for a specific unresolved risk or consistent
adverse signal. The single 60-minute budget includes setup, recovery and repeats.
Prove submission/result verification/lease release with a small run before expanding.
Use a bounded persistent controller with retained journals; inspect real phase, power
state and verified-trial count. Release the owned lease on every exit.

No universal 1% precision or full configuration/version matrix is required. PostgreSQL 17
performance trials are outside scope; use supported versions for new SQL correctness where
needed. The old pipeline-versus-sequential ratio and historical catch-up telemetry are
additional evidence, not the original-control comparison. Do not automatically rerun all
historical telemetry. Reuse valid artifacts only if source and workload inputs match.

Record effects and uncertainty under a new inspection-specific results directory, separate
from MP12 evidence. A reproducible append regression blocks release. Noisy evidence remains
inconclusive, not a no-regression claim. If practical acceptance needs user judgment, report
that exact limitation and obtain it; prior acceptance for another cohort is not permission.
Do not weaken a gate, discard adverse samples or retry until favorable.

### Milestone 2 — establish and approve release truth

Read agents/skills/release/SKILL.md in full at execution time. Query Hackage and upstream tags
for each proposed package and compare commits since each last release. Use Mori to discover
dependency sources and dependents, but do not infer latest releases from its cached corpus.
Present package, current release, proposed version, reason, dependencies and evidence.
Verify every required lower/upper bound against authoritative released APIs.

Prepare a reviewable version/bounds/changelog proposal. Follow the release skill's approval
boundary before changing approved metadata or publishing, unless the user has explicitly
authorized the concrete cohort and scope already. Planning review alone grants neither.
Do not invent a fixed five- or six-package cohort or an exact archive count.

Append an upgrade blueprint edge for the actual released window. From the current baseline
this is store 0.10.0.0 to the approved inspection major, with its own appropriately named
file; do not create a mislabeled 0.9 -> 0.10 edge or overwrite an existing migration guide.
Describe new Store constructors, config/Subscriber constructor compatibility, unchanged
starter signatures, the new executable, typed decoding assumptions and approved bounds.
Document migration 0015's transactional index build and maintenance-window write
pause after verifying the merged schema diff; preserve all earlier manifest entries.
Preserve earlier edges and bump the blueprint version based on its actual current state.

Apply approved metadata to every relevant library, test, example and executable stanza.
Date Unreleased changelogs on the actual release day. Record the real APIs changed rather
than claiming all record additions source-compatible. No dependency upper bound is widened
merely because a build happens to solve locally.

### Milestone 3 — build, archive, publish and verify

Run release-skill format, build, test and flake checks; run each package's cabal check from
that package directory, not an invented --cabal-file flag. Add newly created files to Git
only when needed for Nix visibility, preserving unrelated user changes.
Build kiroku-metrics and prove its Nix result includes bin/kiroku-inspect.
Run the example and exact executable --help. Validate ADR/capability/request bundles.

Produce source and Haddock archives for the actual cohort, record SHA-256 hashes and inspect
tar listings for public modules, license/changelog, app-inspect/Main.hs and correct default
flags. Publication is permitted only after required evidence and explicit authorization.
Commit on the current branch with a Conventional Commit and this plan's MasterPlan,
ExecPlan and Intention trailers. Push only the new authorized annotated package tags, never
all unrelated local tags. Publish in dependency order (store before its dependents; CLI
before metrics), then docs and GitHub releases per the release skill. Verify exact versions,
tag targets, source archives and documentation independently. Never replace an existing
artifact/version or move a published tag; stop dependent uploads after a dependency fails.

### Milestone 4 — exact-version consumer and request completion

In a fresh temporary directory created with mktemp -d, create a small Cabal project using
only published packages and explicit exact-version constraints. Do not include local
source packages, a source-repository-package override or this checkout's cabal.project.
Compile a consumer that imports Kiroku.Metrics wholesale, constructs validated browse/dead-letter
queries, calls listStreams/listCategories/getEvent/subscriptionDeadLetters, uses current
decodeHook results, builds all ServerProviders fields, and starts with the bracketed
providers API. Compile a second fixture using every preserved legacy starter.

Install kiroku-inspect with a constraint `kiroku-metrics == <approved-version>` and an
isolated install directory, then run --help and a migrated-database smoke test for
/capabilities, /subscription-checkpoints, /streams, /subscriptions, dead letters and /ws/events.
Resolve/inspect the install plan to prove the published versions were selected.
Check readiness, allowed-origin access and clean shutdown. Preserve the short transcript.

Only then mark IR-8..IR-12 completed with completedAt, updated timestamp, verified versions
and exact artifact links. Add bundle log entries and validate against the current profile.
Provide a consumer handoff using canonical Mori references, including the changed unreleased
checkpoint route choice and the four coded WebSocket errors. Do not edit/send to downstream
projects unless requested. Distill any additional durable lessons into ADRs and mark EP-7
complete only when every authorized acceptance requirement is satisfied.


## Concrete Steps

Run from the repository root unless stated otherwise. Start with read-only inspection:

```bash
git status --short
git log -1 --format='%H %s'
mori registry show shinzui/kiroku --full
mori registry dependents shinzui/kiroku --packages
rg -n '^version:|kiroku-store|kiroku-cli' kiroku-store/kiroku-store.cabal kiroku-metrics/kiroku-metrics.cabal kiroku-cli/kiroku-cli.cabal kiroku-otel/kiroku-otel.cabal shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal
curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json
curl -fsSL https://hackage.haskell.org/package/kiroku-metrics/preferred.json
git ls-remote --tags origin 'kiroku-store-v*' 'kiroku-metrics-v*'
```

Repeat registry/tag checks for all actual cohort packages. Capture exact outputs in Progress.
After implementation and metadata authorization, the ordinary release checks include:

```bash
nix fmt
cabal build all
cabal test all
nix flake check
nix build .#kiroku-metrics
cabal run kiroku-metrics:exe:kiroku-inspect -- --help
cabal run -fexample kiroku-metrics-example
just perf-structure
just adr-validate
just capabilities-validate
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
```

Read Justfile and the performance-gates document before invoking workload or remote runners.
No fixed remote queue is pre-authorized by this document. From each package directory run
`cabal check`, `cabal sdist` and the release-skill Haddock command; record generated paths
rather than guessing archive names. A successful local build is not publication evidence.


## Validation and Acceptance

Acceptance requires passing child/API checks, original-control performance evidence with an
explicit verdict, approved PVP metadata, verified exact-version source/docs artifacts and
tags, and a clean consumer build/install. Disabling WebSockets must actually disable upgrades;
an occupied port must fail before onListening; overflow notice must precede survivors;
bounded name state must remain bounded under high stream cardinality.
The released guide must distinguish process-local metrics/live subscriptions from durable
database state and describe losses/recovery truthfully.

The final report separates functional completion, verified trial counts, any active remote
execution, inconclusive evidence, practical acceptance and publication. Every request
completion links to actual releases. No benchmark or package publication is claimed by this
planning revision.


## Idempotence and Recovery

Read-only checks and local builds can be rerun; inspect the working tree before repeating
metadata edits. Preserve unrelated edits and existing changelog sections. Resume the owned
benchmark journal rather than restarting its budget. Keep interrupted/adverse samples and
validate input hashes before reuse. Release the owned remote lease on every exit.

Uploads and tags are not idempotent mutations. Before resuming a partial release, inspect
Hackage, GitHub and remote tags to identify completed artifacts, verify their hashes and
continue only missing authorized steps. Never overwrite a published version. If publication
is deferred, keep implementation complete but release/request completion pending.
Do not use git checkout -- or broad restores to discard a dirty tree.


## Interfaces and Dependencies

Use the actual exported API from the children as the clean-consumer authority. The completed
ServerProviders record has webSocketServer, subscriptionStatus, checkpointInventory, storeBrowsing,
deadLetters and webSocketChannels. ProviderPresence uses presentWebSocketChannels to avoid
a conflicting umbrella export. Capabilities uses corsIsEnabled, while Cors exports corsEnabled.
InspectHooks.onListening is `Int -> Capabilities -> IO ()`. BrowseLimits is abstract and
validated; dead-letter limits remain validated. The event resolver preserves DecodedBatch
and typed EventDecodeFailed behavior; its cache is bounded.

There is one structured JSON helper owner (plan 90), one server/lifecycle owner (plan 87),
one resolved-event encoder owner (plan 88), and one release owner (this plan).
The default-off middleware and existing append/publisher fast paths are part of acceptance,
not optional optimization. Dependency bounds and independent package versions come from
Milestone 2, never September's fixed literals.


## Revision Notes

2026-09-30: Created as the coordinated release and request-completion child.

2026-10-10: Replaced stale release scripts with current-source and registry-derived release
steps; preserved the original publication scope while adding API/lifecycle proof and
proportional original-control performance acceptance. Store 0.10 and metrics 0.2 are already
released. No runtime acceptance or publication occurred in this update.


2026-10-11 handoff: EP-3 local implementation is complete and the user endorsed
retaining the selected shared index. The [selected-layout evidence](../../bench/mp13-index/evidence/2026-10-10-byte-name/README.md)
has 21 verified trials. Fresh throughput is -2.980% [-6.128%, +0.274%], p99
+3.700% [-3.814%, +11.802%]; observer throughput is -1.722% [-4.631%, +1.276%],
p99 +0.308% [-3.556%, +4.327%]. Both zero-slowdown verdicts remain inconclusive
and most intervals miss the declared precision target. This endorsement allows
continued local implementation, without relaxing any performance gate or
authorizing production migration/publication. Reuse valid evidence with matching
inputs; remaining cumulative HTTP/tail/inventory acceptance stays here. Future
plan 54 shares the same physical cost and gets no independent additive allowance.
