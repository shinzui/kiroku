---
type: Improvement Request
title: Retry publisher pool errors before the safety poll
description: >-
  Retry a failed EventPublisher database read on a short, bounded backoff while backlog is
  pending, rather than waiting only for the next notification or 30-second safety poll; a
  recovered connection should not add multiple safety-poll periods to subscription recovery.
generated:
  by: openai/gpt-6
  at: "2026-09-25T06:38:48Z"
timestamp: "2026-09-25T06:38:48Z"
requestId: IR-16
status: proposed
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-09-25T06:41:08Z"
    document_timestamp: "2026-09-25T06:38:48Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-6
    effort: unspecified
    context: >-
      Compared the released capability and guide claims with the sealed PostgreSQL 17 and 18
      runs and the diagnostic publisher-error timeline. At-least-once delivery held; the
      sixty-second recovery target is a kenshou expectation, so the proposal is an improvement
      request rather than a bug report.
---

# Retry publisher pool errors before the safety poll

## Why this is a request

`mori://shinzui/kiroku/okf/capabilities/concepts/CAP-11` and `mori://shinzui/kiroku/okf/capabilities/concepts/CAP-12` promise at-least-once delivery and recovery from transient live database errors. The subscription guide in `mori://shinzui/kiroku` at project-relative path `docs/user/subscriptions.md` describes a 30-second safety poll for missed notifications; an artifact-level URI for this guide is pending. It does not promise that a call affected by a TCP blackhole returns within 60 seconds. Kiroku eventually delivered every event in the experiment below, so this is a request for a shorter recovery delay, not a report of a broken at-least-once guarantee.

The released EventPublisher handles a `Pool.UsageError` by emitting `KirokuEventPublisherPoolError` and returning to its wait loop. It attempts the read again on the next notifier tick or the next 30-second safety poll. That behavior matches the documented implementation, but a connection reset can leave several successive attempts failing after forwarding has resumed. In a store with no new appends, each such failure adds another safety-poll period while native `$all` subscribers and consumer-group members remain behind the publisher's cursor.

## Reproduction and evidence

The `mori://shinzui/keiro-runtime-kenshou` scenario `kiroku/subscription/concurrency/network-partition` used Hackage `kiroku-store` 0.8.0.1 (source SHA-256 `c56c8fa889e07fe7f075c3233976695699e406b185020b8b86f93de3969d6373`), PostgreSQL 18.6 with `fsync=on`, `kiroku.conn.keepalives=true`, pool size 10, no statement timeout, and tracing and metrics off. Its invocation was:

```bash
cabal run -v0 kenshou -- run kiroku/subscription/concurrency/network-partition --out runs --dim pg.version=18
```

The first sealed run is `01a0d740-6724-7713-8cba-84b6648d97c8` (seed `7245215569709266`); the diagnostic revision is `01a0d746-a273-7019-92b6-0f84e8d27c22` (seed `8776287720363782`). Their results and per-subscriber control logs are under project-relative `runs/<run-id>/` in `mori://shinzui/keiro-runtime-kenshou`; artifact-level run URIs are pending. PostgreSQL 17.11 run `01a0d743-6b2e-75df-a22d-a1c254fbffb0` (seed `8424663067930253`) reproduced the same delivery split.

The proxy blackholed traffic for twenty seconds, restored forwarding at `06:35:51.753Z`, and reset active sockets. The diagnostic run recorded publisher pool errors at `06:35:56.690Z`, `06:36:26.691Z`, and twice at `06:36:51.8Z`; native `$all` delivery of position 101 resumed at `06:37:22.547Z`, about 91 seconds after forwarding returned. At the 60-second observation, category delivery had reached all 300 distinct positions but native `$all` and the group were still at the 100-position baseline. All three eventually covered positions 1–320 and their durable checkpoints reached 320. The category's separate replay is tracked by `mori://shinzui/kiroku/plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size`.

## Requested change

1. After a publisher pool error, retry while an undelivered global head may exist using a bounded backoff shorter than the 30-second idle safety poll. Keep the ordinary idle path quiescent and avoid a busy loop during a sustained outage.
2. Keep the cursor and at-least-once replay behavior intact. A failed read must not advance `lastPublished`, and a reconnect must not let consumer-group members outrun the publisher's confirmed head.
3. Emit enough timing in publisher recovery observations to distinguish a blocked database call from repeated returned pool errors and from waiting for the next retry.

Acceptance should replay the proxy blackhole on PostgreSQL 17 and 18 with no new appends after forwarding returns, demonstrate that a returned transient pool error schedules a retry promptly rather than waiting a full safety-poll period, and prove eventual complete delivery, order, and durable checkpoint progress. The implementation should retain the existing 30-second idle safety poll and measure its effect on the publisher's quiet-state database-call rate.
