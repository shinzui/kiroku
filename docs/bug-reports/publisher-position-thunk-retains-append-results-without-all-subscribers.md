---
type: Bug Report
title: Publisher position thunk retains append results without all-stream subscribers
description: The empty-subscriber publisher path stores an unevaluated max in its position TVar, retaining a chain of Hasql results and large objects as events are appended.
generated:
  by: process:codex
  at: "2026-09-25T21:47:43Z"
bugId: BUG-3
status: fixed
fixedVersion: "0.9.0.1"
resolution: >-
  Released in kiroku-store 0.9.0.1. cheapAdvance forces the next scalar global
  position before writing it to the TVar. Its regression test failed on the
  old code with 7.09 MB of large-object growth over 12,000 appends and passed
  with the fix. In a version-locked three-minute Keiro command soak, changing
  only this Kiroku source update reduced post-major live growth from 93.1 MB
  to 1.6 MB while all commands and durable checks passed. A full live-worker
  soak against the released package remains to be run.
severity: degraded
origin: mori://shinzui/keiro/okf/bug-reports/concepts/BUG-1
affects: mori://shinzui/kiroku/packages/kiroku-store
affectedVersion: "0.8.0.1 through 0.9.0.0"
environment: GHC 9.12.4 on macOS arm64 with PostgreSQL 18; reproduced on Kiroku 0.8.0.1 in the released Kenshou cohort and on Kiroku 0.9.0.0 in Keiro's isolated append leg.
observed: In a 20,000-append isolated run, post-major live heap grew 16.92 MiB at 1,184 bytes per operation and large-object bytes reached 15.03 MiB. Info-table profiles of two live write-side workers identify the same growing publisher thunk at EventPublisher.hs line 251 and a Hasql decoder closure.
expected: With no all-stream queue subscribers, advancing the publisher's scalar global position should retain only the current position, so post-major live and large-object heap settle under steady appends.
reproduction:
  - In the Keiro repository, run `KEIRO_RETENTION_LEGS=kiroku-append-only KEIRO_RETENTION_OPERATIONS=20000 KEIRO_RETENTION_REPORT_ONLY=1 cabal test keiro-retention --test-show-details=direct` against released Kiroku 0.9.0.0. The Keiro reproduction and measurements are recorded in `mori://shinzui/keiro/plans/297-isolate-and-fix-write-side-worker-heap-retention-under-steady-subscription-load`.
  - Keep the store open and inspect the six to twelve post-major samples; the direct append path retains large objects even without a Kiroku subscription consumer.
  - Profile either `keiro/pm-worker` or `keiro/router-worker` in the released `mori://shinzui/keiro-runtime-kenshou` cohort with `kenshou diagnose profile --mode info-table`. Both profiles name `Kiroku.Store.Subscription.EventPublisher` line 251 among the growing sites.
  - In an isolated Kiroku 0.9.0.0 worktree, force `nextPos = max cur tailPos` before writing `GlobalPosition nextPos` to `posVar`, then rerun the isolated append leg. The 20,000-append comparison held large-object bytes near 0.30 MiB and lowered the live-heap slope to 332 bytes per operation.
workaround: Upgrade to kiroku-store 0.9.0.1 or later. Upgrading from 0.8 requires stopping older writers and applying schema migration 0012 before starting new writers; there is no rolling cutover. The full live-worker soak still needs re-verification.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-25T20:21:55Z"
    document_timestamp: "2026-09-25T20:20:33Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Checked the released and current publisher source, both worker info-table profiles, the isolated strict-update comparison, and the BUG-3 bundle fields.
---

# Publisher position thunk retains append results without all-stream subscribers

`publisherLoop` uses `cheapAdvance` when its all-stream queue subscriber map is empty. This is also the normal state for category subscriptions, which use the notification-driven worker loop. `cheapAdvance` reads the database tail position and writes:

```haskell
GlobalPosition cur <- readTVar posVar
writeTVar posVar (GlobalPosition (max cur tailPos))
```

`GlobalPosition` is a non-strict newtype over `Int64`, and `writeTVar` does not force the value. Each new `max` can therefore retain the previous position expression and the Hasql result that supplied `tailPos`. The empty-subscriber path does not otherwise need to evaluate that position. This explains why a long sequence of append notifications can retain earlier decoder closures and their backing large objects.

On the exact released Kenshou cohort (Kiroku 0.8.0.1), the process-manager and router child profiles both reproduced the reported post-major growth. Their info-table censuses independently found the publisher line 251 as a growing site (+307,488 and +323,392 bytes respectively) and `Hasql.Codecs.Decoders.Value` lines 97–98 (+230,616 and +242,544 bytes). Their RTS large-object bytes reached 19,930,464 and 16,616,720 respectively. The closure census accounts for much less than the RTS large-object total, so those byte counts are not interchangeable; the matching allocation sites and the isolated patch comparison support the shared cause.

The Keiro `kiroku-append-only` leg reproduced 16.92 MiB kept-sample live growth and 15.03 MiB large objects on released Kiroku 0.9.0.0. A detached worktree with only a strict evaluation before the TVar write changed the same leg to 4.75 MiB growth at 332 bytes per operation, while large-object bytes stayed around 0.30 MiB after the first block. No Keiro code changed in that comparison. Kiroku now forces the new scalar position before storing it. Its regression test appends 12,000 events with no all-stream queue subscribers and samples large-object bytes after major GC. The test failed on the old code with 7.09 MB of growth and passed with the fix.

The original Keiro worker report is `mori://shinzui/keiro/okf/bug-reports/concepts/BUG-1`. Its execution plan is `mori://shinzui/keiro/plans/297-isolate-and-fix-write-side-worker-heap-retention-under-steady-subscription-load`.

The matched command workload in `mori://shinzui/keiro/plans/298-isolate-and-fix-command-runner-heap-retention-over-long-snapshotted-histories` changed only this Kiroku position update on the original 0.8.0.1 cohort. Over three minutes, the unchanged arm retained 93,130,336 post-major live bytes; the patched arm retained 1,632,328 bytes. All 21,639 and 22,030 commands, respectively, passed their durable correctness checks. The fix is published as [kiroku-store 0.9.0.1](https://hackage.haskell.org/package/kiroku-store-0.9.0.1).
