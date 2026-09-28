---
type: Bug Report
title: Partial consumer-group acquisition can strand members
description: >-
  In shibuya-kiroku-adapter 0.5.1.2, cancellation or a later member's
  construction failure can leave earlier subscriptions open; a throwing
  cleanup skips the remaining members and replaces the primary exception.
generated:
  by: openai/codex
  at: "2026-09-28T00:06:38Z"
bugId: BUG-4
status: fixed
severity: degraded
fixedVersion: "0.5.1.3"
resolution: >-
  Version 0.5.1.3 uses a masked ownership ledger that records each acquired
  member before the next interruptible action. On failure it attempts every
  release in reverse order, suppresses release exceptions, and rethrows the
  primary construction exception. The ack-stream bridge also closes its
  subscription-to-monitor ownership window. Current-release PostgreSQL 17
  and 18 scenario runs pass the cancellation and real-store cleanup oracles.
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/kiroku/packages/shibuya-kiroku-adapter
capability: mori://shinzui/kiroku/okf/capabilities/concepts/CAP-19
affectedVersion: "0.5.1.2"
environment: >-
  shibuya-kiroku-adapter 0.5.1.2 with Shibuya core 0.9.0.3 on durable
  PostgreSQL 17 and 18. Eight-member consumer-group construction, 200
  cancellation boundaries, a later member factory error, a throwing cleanup,
  and two real-store arms with one backend-termination fault.
observed: >-
  Only the first throwing cleanup ran, replacing the original construction
  exception; previously acquired subscription threads remained above baseline.
  The revision-two real-store probe issued seven group reads per arm, then no
  additional reads over 35 seconds, but leaked threads could stay blocked on
  the seeded unacknowledged event.
expected: >-
  Every successfully acquired member receives a shutdown attempt after
  cancellation or a later construction error; the original error survives a
  throwing shutdown and subscription workers return to their baseline.
reproduction:
  - Build an eight-member group with a factory that fails while constructing a later member and a release action that throws for the most recently acquired member.
  - Inspect the release log, the propagated exception, and the subscription thread count five seconds after failure.
  - Repeat while cancelling at acquisition boundaries and with real Kiroku subscriptions on PostgreSQL 17 or 18.
  - Version 0.5.1.2 skips releases and replaces the primary exception; version 0.5.1.3 releases every owned member and preserves the primary exception.
workaround: >-
  Upgrade shibuya-kiroku-adapter to 0.5.1.3 or later. For an affected running
  process, terminate the process after a partial group-construction failure
  to close stranded subscription workers.
---

# Partial consumer-group acquisition can strand members

The 0.5.1.3 changelog and `Shibuya.Adapter.Kiroku.Internal` describe the
masked ownership ledger and release behavior. The external scenario
`shibuya/kiroku-adapter/concurrency/group-acquisition-failure-strands-nothing`
in `mori://shinzui/keiro-runtime-kenshou` reproduced the historical defect
in sealed PostgreSQL 18 and 17 revision-two results at
`runs/01a0df01-114c-73b4-9432-80f8615690e8/run-result.json` and
`runs/01a0e426-4b9d-7703-9826-083204494700/run-result.json`
(artifact-level URIs pending). Published 0.5.1.3 passed the same revision on
PostgreSQL 18 and 17 at
`runs/01a0defd-fd74-740c-a48b-06a18c690658/run-result.json` and
`runs/01a0e42a-5b2e-76c0-aa59-8cc80dd6ae40/run-result.json` in that
project (artifact-level URIs pending).

The 35-second flat SQL call count is supporting context, not proof of cleanup:
an open subscription worker may remain blocked on its delivered event. The
thread count, release log and propagated exception establish the regression.
