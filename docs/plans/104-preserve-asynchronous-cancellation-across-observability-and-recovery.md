---
id: 104
slug: preserve-asynchronous-cancellation-across-observability-and-recovery
title: "Preserve asynchronous cancellation across observability and recovery"
kind: exec-plan
created_at: 2026-10-30T17:27:22Z
intention: "intention_01m66xj8v0efta4hj6zzdy0d0n"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-30T17:27:22Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-30T17:53:16Z
      verdict: "changes-requested"
      note: "Probe and apply-check re-verified; publisher trigger, notifier seam choice, bug-report status vocabulary and evidence index step were unspecified"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-30T17:55:46Z
      mode: "update"
      note: "Applied review findings: publisher trigger, notifier seam decision, bug-report status and index steps, stable decoder reference, deadline alignment"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-30T18:32:12Z
      mode: "implement"
      note: "Implement boundary regressions, classifier corrections and final validation"
---

# Preserve asynchronous cancellation across observability and recovery

This ExecPlan is a living document. Update Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective as implementation proceeds. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and `agents/skills/exec-plan/ADR.md` for durable decisions.

## Purpose / Big Picture


Store shutdown must not hang because an observation callback or publisher recovery handler discards cancellation. Correct the three exception classifiers reported in [BUG-6](../bug-reports/asynchronous-cancellation-is-swallowed-by-observability-and-recovery.md), evaluate the attached patch against current source, and prove both cancellation propagation and preservation of ordinary error recovery. Success means deterministic tests fail with each original classifier and pass with the fix, real cancellation terminates the affected threads, and existing subscription and resource-cleanup behavior continues to pass.

This is a plan for implementation. Creating it does not establish that the patch has passed the current test suite or that consumer deployment failures are resolved.

## Progress


- [x] Milestone 1 (2026-10-30): The unchanged-source probe reproduced swallowed cancellation; 27 new examples produced 24 expected failures and three passing synchronous/success controls. The existing synchronous publisher recovery control also passed (one example).
- [x] Milestone 2 (2026-10-30): All 27 boundary examples pass with corrected classifiers; independent reverts fail observation (4/4), nested publisher callback (1/1), and notifier startup (4/4). Concrete payloads, real cancellation, connection cleanup and synchronous controls are covered.
- [x] Milestone 3 (2026-10-30): Candidate `46b5cd6` passes 27 focused cases, 36 publisher resilience cases, 632 store cases, all six repository suites (878 examples), and 52 structural cases. BUG-6 is fixed and unreleased, current-source evidence is retained, the changelog is updated, and ADR-23 records the policy. ADR checks pass; bug-bundle validation retains only its four known older-report findings.

## Surprises & Discoveries


2026-10-30: All 27 boundary examples pass after the three production corrections (1.45 seconds); the unchanged classifiers failed 24 of them (71.57 seconds). Direct queue registration forces publisher full fetch without a subscription worker obscuring the target boundary. Independent classifier reverts fail the corresponding assertions (4 observation, one nested publisher, four notifier startup). Final regression checks pass; the corrected probe propagates all three cancellation values and still suppresses the synchronous control.

2026-10-30: Strict validation revealed that the prescribed evidence Markdown file
became another Bug Report concept, and fixed reports require `fixedVersion` as well
as `resolution`. Retained the evidence as `.txt` and set `fixedVersion: unreleased`;
see FRIC-13 in `docs/friction-log/`. No validation gate was weakened.

## Decision Log


2026-10-30: Register the publisher queue directly with a bracketed unsubscribe action in the new regressions. This exercises the same full-fetch recovery boundary without creating an idle subscription worker that needs independent cancellation. The existing resilience control now explicitly verifies checkpoint and publisher progress after synchronous recovery.

2026-10-30: Treat the attached patch as a candidate correction, not sufficient acceptance evidence. Its three production edits address the reported misuse, but its one added example exercises only `emitOrDrop`. Require independently sensitive tests of publisher recovery and notifier startup before accepting the change.

2026-10-30: Inject the notifier startup LISTEN failure through a process-local `withListenHookForTest` seam in `Kiroku.Store.Notification`, not an argument-based startup variant. The module is exposed, so either seam adds a public symbol; the existing Worker hook pattern wins on precedent and leaves `startNotifier`'s signature unchanged. The hook wraps only the startup LISTEN call.

2026-10-30: Close BUG-6 with `status: fixed` and a `resolution` naming the fixing commit and the absence of a release. The bug-report profile has no verified or released status, so release state is recorded in prose rather than by inventing a status value.

2026-10-30: Preserve the existing synchronous-error branches and rethrow the caught `SomeException` on an asynchronous match. Do not introduce blanket masking, retries, dependency upgrades, schema changes, or process-wide signal handling. Review adjacent notifier cancellation behavior explicitly, but do not claim this patch fixes all shutdown failures.

## Outcomes & Retrospective


Implemented in `46b5cd6` without dependency changes, schema changes or a version bump.
All three original classifiers have independently sensitive regressions, and direct
and real cross-thread cancellation preserves concrete types and custom payloads.
Synchronous publisher retry now also checks durable checkpoint progress. No listener
connections remain after tested startup failures.

[Current-source evidence](../bug-reports/evidence/BUG-6/current-head-validation.txt)
records the commands, environment, counts, baseline failures and sensitivity results.
[ADR-23](../adr/0023-recovery-boundaries-preserve-asynchronous-exception-family-membership.md)
distills the exception-family policy and remaining notifier-policy limit. BUG-6 is
fixed in source and unreleased; consumer deployment and OpenTelemetry symptoms remain
outside this claim. [FRIC-13](../friction-log/13-bug-6-evidence-path-conflicts-with-recursive-bundle-validation.md)
was resolved by correcting this plan’s evidence suffix and the fixed-report metadata;
strict bug-bundle validation now adds no findings for BUG-6.

## Context and Orientation


Creation-time verification on 2026-10-30: `git apply --check` accepted the suggested current-head patch. Running the standalone probe against unchanged current source under GHC 9.12.4 produced `Nothing`, `Just AsyncCancelled`, then four `Right ()` results, independently reproducing the emitter defect. No corrected-source test suite has been run in this planning session. The report’s repository-relative GHCi load command initially failed because Cabal changes to the package directory; Concrete Steps below corrects that path. Review re-verification on 2026-10-30 at commit `61841f5` repeated both checks: `git apply --check` passed, `:!pwd` in the GHCi session printed the `kiroku-store` package directory, and the probe printed the same `Nothing`, `Just AsyncCancelled` and four `Right ()` lines.

The affected package is `kiroku-store`, currently version `0.13.0.0` in `kiroku-store/kiroku-store.cabal`. The report and attachments are under `docs/bug-reports/evidence/BUG-6/`: `current-head.patch` targets current source, `kiroku-store-0.11.0.1.patch` is historical compatibility evidence, `validation.txt` distinguishes executed historical tests from the apply-checked current adaptation, and `reproduce.hs` is a database-free probe.

`kiroku-store/src/Kiroku/Store/Observability.hs` defines `emitOrDrop`: optional operational-event callbacks run normally; synchronous callback failures are discarded; asynchronous exceptions must escape. An asynchronous exception here means a value registered under Haskell's `SomeAsyncException` exception family. It includes `AsyncCancelled`, `ThreadKilled`, and `UserInterrupt`, even when explicitly raised with `throwIO`. The exception family does not reveal how an arbitrary exception was delivered; this plan does not promise to classify every value sent with `throwTo` as cancellation.

`asyncExceptionFromException` extracts a concrete payload from that family. Requesting the wrapper itself fails for ordinary payloads. `fromException e :: Maybe SomeAsyncException` instead tests family membership. The proposed correction then rethrows `e`, retaining the original exception value rather than reconstructing a payload. Source inspection supports the classification change; tests must establish concrete type and payload preservation, and any stronger claim about diagnostic context must be separately verified against the configured compiler.

Dependency lookup used `mori registry list`, `mori registry search base`, and `mori registry show simonmar/async --full`. No base corpus was returned. `mori://simonmar/async/packages/async` supplies the cancellation implementation; its `Exception AsyncCancelled` instance uses the concrete decoder correctly. Source location: canonical project `mori://simonmar/async`, project-relative `async/Control/Concurrent/Async/Internal.hs` (artifact-level URI pending); the registered corpus is `async` 2.2.6. The decoder in `base` unwraps the family wrapper and casts the payload to the requested type ([`Control.Exception` documentation](https://hackage.haskell.org/package/base/docs/Control-Exception.html#v:asyncExceptionFromException)), which is why asking it for the wrapper type itself never succeeds. No dependency bounds or pins are selected by this plan.

```haskell
asyncExceptionFromException :: Exception e => SomeException -> Maybe e
asyncExceptionFromException x = do
  SomeAsyncException a <- fromException x
  cast a
```

`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` wraps `fetchAndBroadcast` in a broad exception handler. Synchronous failures emit `KirokuEventPublisherLoopError` and retry on a later wakeup without advancing the published position after partial delivery. This preserves at-least-once delivery: duplicates can occur after failure, but events must not be silently skipped. The same wrong classifier currently treats cancellation as a recoverable loop error. A decode hook provides an existing injection point inside this boundary. The publisher runs observability callbacks on its own thread through `emitOrDrop` in two places: `KirokuEventPublisherDecodeFailed` when the decode hook returns a `Left` for an event, and `KirokuEventPublisherPoolError` when the read query fails. The decode-failure event is the deterministic way for a test to run a callback on the publisher thread. The `eventHandler` callback is shared by the notifier, publisher and worker threads, so a throwing test callback must match on the specific event constructor it targets. The exported `EventPublisher` record exposes its thread handle as `publisherThread`, reachable from a store's `publisher` field, and `publisherPosition` reads the last-published position.

`kiroku-store/src/Kiroku/Store/Notification.hs` wraps initial `Notifications.listen` failures in `NotifierListenError`, inside `bracketOnError`, which releases the acquired connection when startup fails. Cancellation must retain its type and trigger that cleanup. The later listener and reconnect handlers decode concrete `Async.AsyncCancelled` correctly; they currently treat other asynchronous exception types as reconnect causes. Their classification policy is a separate question from the wrapper misuse. Cancellation arriving inside callbacks in those paths must be examined because nested recovery can change the final outcome. `stopNotifier` owns final connection release after joining the listener. `startNotifier` is exported and takes only a connection string, a schema name and the optional event handler, so a test can start it directly against a `withMigratedTestDatabase` connection string without constructing a store; the `Notifier reconnection` group in `kiroku-store/test/Main.hs` already does this and asserts that `listenerCount` returns to zero after shutdown. The module has no LISTEN injection seam today. `Kiroku.Store.Notification` and `Kiroku.Store.Subscription.Worker` are both exposed library modules, so any test seam added to either is a public symbol.

`kiroku-store/test/Test/PublisherCallbackResilience.hs` already covers one-shot decode-hook recovery and throwing event handlers. `kiroku-store/test/Test/StartupFailureSurfacing.hs`, `kiroku-store/test/Test/SubscriptionReconnect.hs`, `kiroku-store/test/Test/HandlerStall.hs`, and lifecycle/notifier cases in `kiroku-store/test/Main.hs` cover adjacent behavior. `kiroku-store/test/Test/Helpers.hs` provides isolated store fixtures, synchronization helpers, listener PID lookup and listener counts. `kiroku-test-support/src/Kiroku/Test/Postgres.hs` supplies ephemeral PostgreSQL. The test executable acquires its shared migrated database before Hspec filtering (`main = withSharedMigratedPostgres $ hspec $ do` in `kiroku-store/test/Main.hs`), so even pure filtered examples require PostgreSQL on PATH. Use the Nix development shell; no external database setup is needed. Hspec runs examples sequentially here because no test module uses `parallel`. No existing example description contains the word `asynchronous`, so a `--match=asynchronous` filter selects only the new boundary examples.

The bug report lives in the profile-governed OKF bundle `docs/bug-reports/`. Its `status` vocabulary is `reported`, `confirmed`, `in-progress`, `fixed`, `wont-fix`, `duplicate`, `not-a-bug` and `cannot-reproduce`; `fixed` is terminal and requires `resolution` and `fixedVersion` fields under strict validation; use `fixedVersion: unreleased` until publication. There is no verified or released status, so release state is recorded in `resolution` and the body, as the four existing `fixed` reports do. Strict validation of the bundle currently fails on four older reports that lack `reviews` metadata; no diagnostic names BUG-6 and this plan does not repair those reports. The `index.md` files under `docs/bug-reports/` are generated listings that `okf index` rewrites.

Relevant ADRs consulted are [ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md), which requires proportional evidence and cheap default paths, and [ADR-13](../adr/0013-handler-stall-diagnostics-are-worker-owned-and-advisory.md), which preserves consumer acknowledgement ownership, scoped watchdog cleanup and cancellation propagation. Preserve those contracts. No ADR specifically defines these three exception classifiers.

## Plan of Work


### Milestone 1: Establish sensitive regressions


Run the standalone probe on unchanged current source. Add separate examples for absent and successful callbacks, synchronous failure suppression, `AsyncCancelled`, `ThreadKilled`, `UserInterrupt`, and a custom asynchronous exception carrying a payload. Give the custom type an explicit `Exception` instance using the asynchronous conversion functions; do not derive the default synchronous instance. Assert the concrete exception and payload outside the emitter, not only that some exception occurred.

Extend `kiroku-store/test/Test/PublisherCallbackResilience.hs` with a publisher test that registers a queue subscriber, appends an event, and raises the selected exception from the decode hook during full fetch. Observe publisher-thread termination through `Async.waitCatch` on `publisherThread` of the store's `publisher` field, no `KirokuEventPublisherLoopError` emission, and a `publisherPosition` that has not advanced past the failed batch. Include a callback cancellation path through `emitOrDrop` and the outer publisher handler: return a `Left` decode failure for a marked event type so the publisher emits `KirokuEventPublisherDecodeFailed`, and make the `eventHandler` raise the asynchronous exception only on that constructor. This path proves that fixing only `emitOrDrop` is insufficient, because the rethrown exception then reaches the outer handler and the original classifier turns it into a loop error. The queue subscriber's worker stays blocked once the publisher thread dies, so the test must cancel its handle in a cleanup step that also runs on assertion failure. Retain the existing synchronous one-shot recovery case as the paired control and assert subsequent delivery/checkpoint progress.

Add `kiroku-store/test/Test/AsyncCancellation.hs`, register it in `kiroku-store/test/Main.hs` and the test component's `other-modules`. Call `startNotifier` directly against a `withMigratedTestDatabase` connection string, as the `Notifier reconnection` group in `kiroku-store/test/Main.hs` does, and exercise the actual startup handler with an injected LISTEN action that runs after a real connection has been acquired. Add a process-local, bracket-restored hook named `withListenHookForTest` to `kiroku-store/src/Kiroku/Store/Notification.hs`, following the `withLoadCheckpointHookForTest` pattern in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`: an `IORef` holding `Maybe (IO () -> IO ())`, unset in production, consulted only by the startup LISTEN call, which passes the real `Notifications.listen` action to the hook so a test can throw instead of listening or block before listening. Both candidate seams would add a public symbol because the module is exposed, so the established pattern wins; mark the export test-only in its Haddock. The hook must run inside the production catch and resource bracket, not a copied test implementation of the classifier. Hspec already runs these examples sequentially, and the bracket restores the hook even when an example fails. Test asynchronous failures and an ordinary synchronous exception; check that the latter is wrapped as `NotifierListenError` with its original cause and that both failures release the acquired connection without starting a listener.

Use MVar or STM barriers (thread-safe rendezvous points) to prove execution has reached the target action before cancellation. A timeout only bounds failure; a timed-out wait is not a successful cancellation. Add controlled fallback release of blocked test actions so a failing baseline cannot hang fixture teardown. For notifier startup, verify a clean baseline connection count, acquire exactly one connection, and observe return to baseline after failure; poll `listenerCount` with a bounded wait rather than reading it once, because the backend exits after the client closes the socket, and reuse listener PID helpers where their query applies.

Milestone 1 ends with retained failures on the original classifiers, identified by boundary and exception case, plus passing synchronous controls. Do not rely on arbitrary sleeps or the historical compatibility results.

### Milestone 2: Correct and evaluate the patch


Apply `current-head.patch` only after inspecting its hunks and reconciling overlapping test edits. In all three reported sites replace the wrapper decoder with `fromException`, rethrowing the original exception. Keep each `Nothing` branch unchanged and format imports. The patch's bundled example can be replaced by the more diagnostic separate cases from milestone 1.

Add cross-thread delivery tests: block inside the emitter callback, publisher decode hook, and injected notifier LISTEN action; signal entry; cancel the target with `Async.cancel`; observe completion and cleanup within a bounded deadline matching the ten-second `timeoutMicros` already used by `kiroku-store/test/Test/PublisherCallbackResilience.hs`. Ensure both the cancellation request and join are bounded, since `cancel` itself waits. Record the target's `waitCatch` result and assert the expected cancellation type. Also exercise runtime `ThreadKilled` or the custom asynchronous payload through `throwTo`, with a bounded sender. All spawned threads and fixtures must be joined or released even on assertion failure.

Review `SomeException` handlers reachable from these paths, particularly notifier reconnect callbacks and recovery. Record which exceptions intentionally terminate normally and which propagate. Preserve the current concrete `AsyncCancelled` handling unless a regression proves it prevents the required cancellation outcome. If a fix to an adjacent boundary is necessary to satisfy this plan's scoped cancellation acceptance, include it with its own failing-before/passing-after test. A broader guarantee about every notifier exception or consumer SIGTERM behavior requires a separate scope decision; record any residual issue instead of silently claiming it fixed.

Demonstrate each test's sensitivity by temporarily reverting one production classifier at a time while retaining tests. Each corresponding test must fail; restore the correction before continuing. This guards against tests that pass because another boundary handles the exception first. Milestone 2 ends when every corrected boundary passes direct and real cancellation checks, and synchronous recovery and resource cleanup still pass.

### Milestone 3: Verify the final candidate and reconcile evidence


Run the focused tests, then the entire store suite and repository suites in the configured development shell. Run existing structural performance tests. Review the diff for unchanged success-path SQL, pool operations, checkpoint semantics, callback-free paths, and per-event allocations. A classifier-only exceptional-path change needs no remote benchmark matrix; if the test seam or implementation introduces ordinary-path work, remove it or justify a focused affected-path measurement under ADR-11 and the repository's whole-experiment budget.

Record commands, compiler/PostgreSQL versions, candidate commit, example counts and failure summaries in `docs/bug-reports/evidence/BUG-6/current-head-validation.txt`, then run `okf index docs/bug-reports --write` so `docs/bug-reports/evidence/BUG-6/index.md` lists the new file. Preserve historical evidence. Move the bug report from `confirmed` to `fixed` only when the acceptance evidence is complete, setting `fixedVersion: unreleased` and adding a `resolution` that names the fixing commit and states that no release contains it yet; the profile has no verified or released status, so that distinction lives in `resolution` and the body. Re-run strict bundle validation afterwards and confirm that the only remaining diagnostics are the four pre-existing `reviews` findings on older reports. Add an unreleased note in `kiroku-store/CHANGELOG.md`. Do not bump versions or publish as part of this plan. Distill the durable classification and cancellation policy into an ADR using `agents/skills/exec-plan/ADR.md`, including the repository's profiled validation and log requirements. Triage implementation friction and fill Outcomes only when the acceptance evidence is complete.

## Concrete Steps


Run commands from the repository root. Begin with:

```bash
git status --short
git apply --check docs/bug-reports/evidence/BUG-6/current-head.patch
nix develop --no-write-lock-file -c cabal repl kiroku-store:lib:kiroku-store --repl-no-load
```

Cabal starts this GHCi session in the package directory. Load the probe relative to that directory:

```text
:load ../docs/bug-reports/evidence/BUG-6/reproduce.hs
main
:quit
```

Before correction the last four results are `Right ()`. After correction they must be `Left AsyncCancelled`, `Left thread killed`, `Left user interrupt`, and `Right ()`. The initial classifier demonstration remains `Nothing` then `Just AsyncCancelled` in both cases. Inspect GHCi diagnostics, since a session can exit zero after a failed load.

Use the following after adding tests; give new boundary tests descriptions containing `asynchronous`:

```bash
nix develop --no-write-lock-file -c cabal test kiroku-store:test:kiroku-store-test --test-show-details=direct --test-options=--match=asynchronous
nix develop --no-write-lock-file -c cabal test kiroku-store:test:kiroku-store-test --test-show-details=direct --test-options=--match=resilience
```

The first command's example count is exactly the number of new boundary examples, because no existing description contains `asynchronous`; the second selects the whole `publisher callback resilience` group, so its count grows by the examples added there.

If the patch still applies without overlapping edits:

```bash
git apply docs/bug-reports/evidence/BUG-6/current-head.patch
```

Otherwise implement its three reviewed production changes directly; do not force stale hunks. At the final candidate boundary:

```bash
nix fmt
nix develop --no-write-lock-file -c cabal test kiroku-store:test:kiroku-store-test --test-show-details=direct
nix develop --no-write-lock-file -c cabal test all --test-show-details=direct
nix develop --no-write-lock-file -c just perf-structure
git diff --check
```

Expect nonzero example counts, zero failed examples and successful suite exits. Inspect formatting changes and retain only task-relevant changes. After the evidence, bug-report and ADR edits, run the documentation checks:

```bash
okf index docs/bug-reports --write
okf validate docs/bug-reports --strict --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce
just adr-validate
```

The bug-report validation is expected to exit nonzero today because four older reports lack `reviews` metadata; acceptance requires that no diagnostic names BUG-6, not a clean exit. `just adr-validate` must pass. Report unavailable or failing suites explicitly; do not interpret a missing environment as a pass. The repository provides `just test-pg 17` and `just test-pg 18` if a discovered database-version risk requires expansion; the classifier change alone does not justify a full version matrix.

## Validation and Acceptance


Every original faulty classifier must have a deterministic failing regression and pass after correction. Asynchronous values must preserve concrete type and payload; callback absence and success must remain harmless, and synchronous callbacks must still be suppressed. Publisher cancellation must terminate its worker without a loop-error event or false progress, while a synchronous hook failure must allow later retry and delivery. Notifier startup cancellation must escape unwrapped, with no leaked connection or listener; synchronous LISTEN failure must remain `NotifierListenError` with its cause preserved. Real cancellation must pass barriers at the intended boundary and finish within the bounded deadline, including test cleanup.

All required suites and structural checks must pass on the final production candidate. Existing reconnect, shutdown, callback resilience, acknowledgement, checkpoint and watchdog tests provide regression coverage alongside the new boundary-specific tests. Record remaining uncertainty honestly: this evidence does not prove every possible scheduling interleaving, the separate consumer OpenTelemetry issue, or all SIGTERM deployment symptoms resolved. No claim of statistical performance equivalence is required or implied.

## Idempotence and Recovery


Tests use ephemeral databases and are repeatable. Save baseline and candidate results separately. `git apply --check` is read-only; apply the patch only once. Use precise edits when reverting individual classifiers for test sensitivity and restore them immediately after the expected failure. Never reset unrelated work or delete historical evidence. Keep cancellation requests, waits and fallback cleanup bounded so failures cannot stall subsequent suites. Restore all test hooks in a bracket even when cancellation interrupts the test. If a check fails, preserve the failure and diagnose it before expanding coverage or accepting the milestone.

## Interfaces and Dependencies


Keep `emitOrDrop`, `startNotifier`, `stopNotifier`, publisher lifecycle functions, exception types and synchronous recovery behavior source-compatible. The intended production correction uses existing `Control.Exception` functions and needs no new package. `mori://simonmar/async/packages/async` supplies real thread cancellation for tests. Discover any additional dependency API with Mori before use; verify registry releases and upstream tags before choosing any new bound or workaround. Avoid adding a public test-only API without explicitly recording and reviewing that tradeoff. Keep production resource ownership with the existing notifier brackets and stop functions.

Revision note (2026-10-30, implementation): Use `current-head-validation.txt` because every non-reserved Markdown file inside the bug bundle is validated as a Bug Report concept; fixed reports also require `fixedVersion: unreleased`. This reconciles the prescribed evidence with the pinned bundle contract without adding another bug concept.

Revision note (2026-10-30): Applied review findings before implementation. Named the deterministic publisher-thread callback trigger (`KirokuEventPublisherDecodeFailed`), the publisher thread handle and the blocked-worker cleanup; chose the `withListenHookForTest` seam for notifier startup after verifying both modules are exposed; recorded the bug-report status vocabulary, the evidence index regeneration step and the pre-existing bundle validation failures; replaced an ephemeral GHC artifact link with the decoder definition; aligned the cancellation deadline with the existing ten-second test bound; and recorded the review re-verification of the probe and patch apply-check.
