---
type: Bug Report
title: Asynchronous cancellation is swallowed by observability and recovery
description: >-
  Three existential asynchronous-exception checks use asyncExceptionFromException
  with SomeAsyncException, causing callback cancellation to be silently dropped
  or treated as a recoverable failure and allowing store threads to keep running.
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-10-30T14:56:23Z"
timestamp: "2026-10-30T14:56:23Z"
bugId: BUG-6
status: confirmed
severity: degraded
origin: mori://shinzui/kotei/okf/friction-log/concepts/FRIC-5
affects: mori://shinzui/kiroku/packages/kiroku-store
capability: mori://shinzui/kiroku/okf/capabilities/concepts/CAP-14
affectedVersion: "0.11.0.1"
environment: >-
  Reproduced against kiroku-store 0.11.0.0 in Kotei and in a Kiroku 0.11.0.1
  checkout at 084fd8359850342447cdda8e632b7dc456c7fca4 using GHC 9.12.4 on
  native aarch64-darwin. The same three checks are present in kiroku-store
  0.13.0.0 source at b9442820bb18636023ae6a18161ad01b576dd425; that current
  version was inspected, not executed for this report.
observed: >-
  emitOrDrop returns normally when its callback throws AsyncCancelled instead
  of propagating cancellation. A deterministic regression fails on released
  source and passes after correcting the classifier. The same check in the
  publisher's recovery handler can convert cancellation into a loop error;
  notifier startup can wrap it as NotifierListenError. In Kotei's expanded
  deployment rehearsal, a completed subscription pass hung in its native cancel
  finalizer and the worker exceeded its shutdown drain deadline.
expected: >-
  emitOrDrop's documented contract drops synchronous callback failures and
  rethrows asynchronous exceptions, including thread cancellation. Publisher
  recovery and notifier startup should likewise preserve asynchronous exceptions
  rather than recovering from them or changing their type.
reproduction:
  - In the owning repository, enter nix develop and open cabal repl kiroku-store:lib:kiroku-store --repl-no-load.
  - Load docs/bug-reports/evidence/BUG-6/reproduce.hs and invoke main; the standalone probe needs no database connection.
  - Observe that the existential helper check prints Nothing while fromException prints Just AsyncCancelled, and the original emitter returns Right () for callback cancellation.
  - Apply the suggested current-head.patch to the recorded current HEAD and run the asynchronous regression and callback resilience group described in the body.
  - Expect the new regression to reject the original emitter and pass with the corrected classifier while synchronous callback failures remain suppressed.
workaround: >-
  No validated released workaround is established. Carry the suggested correction
  through the producer's normal review and release process before relying on
  cancellation during callbacks. A process supervisor can terminate an affected
  process after its existing shutdown deadline, but that does not establish
  graceful subscription cleanup. Disabling tracing does not fix the classifier.
reviews:
  - kind: model
    reviewer: codex-cli/gpt-6.1-sol
    reviewed_at: "2026-10-30T15:00:26Z"
    document_timestamp: "2026-10-30T14:56:23Z"
    scope: technical-accuracy
    outcome: commented
    provider: OpenAI
    model: gpt-6.1-sol
    effort: high
    context: >-
      Author verification of the released-source failure, compatibility-patch
      regression and callback resilience results, and current-HEAD patch applicability;
      this is not an independent review or independent reproduction.
---

# Asynchronous cancellation is swallowed by observability and recovery

The defect is confirmed, with a suggested patch; it is not fixed on the default
branch or in a release. The report originates in
`mori://shinzui/kotei/okf/friction-log/concepts/FRIC-5` while implementing
`mori://shinzui/kotei/plans/104-execute-steps-on-declared-remote-hosts`.

## Reproduction and contract

[`emitOrDrop`](../../kiroku-store/src/Kiroku/Store/Observability.hs) documents
that synchronous callback failures are dropped and asynchronous exceptions,
including cancellation, are rethrown. Its current implementation instead tests:

```haskell
case asyncExceptionFromException e of
  Just (ae :: SomeAsyncException) -> throwIO ae
  Nothing -> pure ()
```

`asyncExceptionFromException` is a decoder for a concrete exception inside
`SomeAsyncException`: it unwraps the existential and casts its payload. Asking
it for `SomeAsyncException` tries to cast that payload back to the wrapper,
which fails for `AsyncCancelled`, `ThreadKilled` and `UserInterrupt`. The
appropriate test for the existential wrapper itself is `fromException`.

Run the [standalone probe](evidence/BUG-6/reproduce.hs) from the repository root:

```bash
nix develop --no-write-lock-file -c cabal repl kiroku-store:lib:kiroku-store --repl-no-load
```

At the GHCi prompt:

```text
:load docs/bug-reports/evidence/BUG-6/reproduce.hs
main
```

The original emitter prints the following values. The last four lines are
cancellation, two runtime asynchronous exceptions, and an ordinary synchronous
callback failure respectively:

```text
Nothing
Just AsyncCancelled
Right ()
Right ()
Right ()
Right ()
```

After the correction, the first two classifier demonstrations stay unchanged,
while the emitter results become:

```text
Left AsyncCancelled
Left thread killed
Left user interrupt
Right ()
```

This reproducer does not need PostgreSQL. The existing complete test executable
acquires its shared migrated PostgreSQL fixture even for a filtered regression.

## Suggested patch

[Current HEAD patch](evidence/BUG-6/current-head.patch) applies cleanly to
`b9442820bb18636023ae6a18161ad01b576dd425`. It changes the three incorrect
existential checks and adds a regression in
[`Test.PublisherCallbackResilience`](../../kiroku-store/test/Test/PublisherCallbackResilience.hs).
No runtime source has been changed by filing this report. The essential change is:

```diff
-case asyncExceptionFromException e of
-  Just (ae :: SomeAsyncException) -> throwIO ae
+case fromException e of
+  Just (_ :: SomeAsyncException) -> throwIO e
   Nothing -> pure ()
```

Apply the same classification correction in the publisher's
`fetchAndBroadcast` recovery handler in
[`Kiroku.Store.Subscription.EventPublisher`](../../kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs)
and notifier startup's `Notifications.listen` exception handler in
[`Kiroku.Store.Notification`](../../kiroku-store/src/Kiroku/Store/Notification.hs).
Retain each synchronous-error branch and rethrow the original exception to
preserve its type and context. Notification's existing checks that decode the
concrete `Async.AsyncCancelled` type already use the helper correctly and are
left intact. The report does not qualify other notifier cancellation boundaries.

Review and exercise the current-HEAD patch with:

```bash
git apply --check docs/bug-reports/evidence/BUG-6/current-head.patch
git apply docs/bug-reports/evidence/BUG-6/current-head.patch
nix develop --no-write-lock-file -c cabal test kiroku-store:test:kiroku-store-test --test-show-details=direct --test-options=--match=asynchronous
nix develop --no-write-lock-file -c cabal test kiroku-store:test:kiroku-store-test --test-show-details=direct --test-options=--match=resilience
```

The [compatibility patch](evidence/BUG-6/kiroku-store-0.11.0.1.patch) applies to
released `0.11.0.1` at `084fd8359850342447cdda8e632b7dc456c7fca4`. Its local,
unpublished commit is `dbe29166f8b38f842759e685555df55d5c1f0fb4`. Both attached
patches include their regression; neither is a dependency override or a claim
that a fixed release exists.

## Executed validation and limits

The [retained validation summary](evidence/BUG-6/validation.txt) distinguishes the
executed compatibility patch from the current-HEAD adaptation. On GHC 9.12.4,
restoring the original `0.11.0.1` emitter while retaining the regression yields
one example and one failure: `did not get expected exception: AsyncCancelled`.
With the compatibility correction restored, all 22 callback resilience examples
pass after formatting. An earlier `--match=preserves` selection passed 38
examples; that broader selection includes unrelated cases and is not 38
cancellation tests. The current-HEAD adaptation is apply-checked only.

The pure regression directly establishes the emitter failure and its correction.
The other two edits correct the identical classifier misuse by source inspection;
the report does not claim a separately fault-injected notifier or publisher run.

Kotei's subscription finalizer hang is a consumer impact, not proof that every
shutdown failure has this cause. OpenTelemetry SDK span hooks independently
catch asynchronous cancellation, so Kotei also needs its own cancellation
boundary around those hooks. Its two native span-start/span-end cancellation
tests still fail with released Kiroku, even with that boundary. The earlier
observation of a worker continuing to poll after SIGTERM remains separate;
neither this suggested patch nor the focused tests establish that symptom is
resolved or that Kotei's full first-deployment qualification passes.
