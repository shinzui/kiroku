---
type: Improvement Request
title: Expose the lifetime member guard in the Shibuya adapter
description: >-
  After consumerGroupGuard holds exclusive ownership for a subscription worker's lifetime,
  expose it as an opt-in KirokuAdapterConfig setting so services using the Shibuya adapter
  can reject a duplicate (subscription name, member) process before it repeats handler work.
generated:
  by: openai-codex/gpt-6-sol
  at: "2026-09-27T17:34:20Z"
timestamp: "2026-10-10T16:10:46Z"
requestId: IR-17
status: accepted
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-10-10T16:10:46Z"
    document_timestamp: "2026-10-10T16:10:46Z"
    scope: authoring-metadata
    outcome: comments
    provider: openai
    model: gpt-6.1-sol
    context: >-
      Checked the required title, description, request identity, lifecycle, origin and
      timestamp metadata against the bundle profile. This is an authoring-metadata
      review only; source claims, implementation acceptance and release evidence were
      not reviewed here.
---

# Expose the lifetime member guard in the Shibuya adapter

## Status

Accepted by kiroku on 2026-09-30. Implementation is planned by
[ExecPlan 92, Expose the lifetime member guard in the Shibuya adapter](../plans/92-expose-the-lifetime-member-guard-in-the-shibuya-adapter.md)
(`mori://shinzui/kiroku/plans/92-expose-the-lifetime-member-guard-in-the-shibuya-adapter`), which adds the opt-in
`consumerGroupGuard` field to `KirokuAdapterConfig` and `KirokuConsumerGroupConfig` (default
`False`), forwards it to the store, proves both the guard-on and guard-off arms with two-store
tests on PostgreSQL 17 and 18, documents the option, and releases the adapter after confirmation.
It depends on
[ExecPlan 93, Hold the consumer-group member guard for the worker's lifetime](../plans/93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime.md)
(`mori://shinzui/kiroku/plans/93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime`), which delivers the
lifetime-held store guard requested by
[IR-15](hold-the-consumer-group-member-guard-for-the-workers-lifetime.md). Status moves to
`completed` only after release evidence exists.

## Why this is a request

Kiroku consumer groups require one active process per `(subscription name, member)` for exclusive work. Duplicate processes may repeat effects under the documented at-least-once model; this is not event loss. The `shibuya-kiroku-adapter` constructs its subscription from `defaultSubscriptionConfig` and leaves `consumerGroupGuard = False`. `KirokuAdapterConfig` exposes the group but no guard setting, so an adapter user cannot opt into member-conflict rejection through that public configuration.

The decision in `mori://shinzui/kiroku/plans/30-consumer-group-effect-api-and-shibuya-adapter-integration` deliberately omitted the adapter option because the original store guard was only a transaction-scoped startup probe. Exposing that probe as if it enforced lifetime ownership would overpromise. `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-15` requests the necessary lifetime-held store guard. This request is the dependent adapter surface after that behavior is available; it does not duplicate IR-15's store implementation.

## Reproduction and evidence

The `mori://shinzui/keiro-runtime-kenshou` scenario `shibuya/kiroku-adapter/concurrency/two-processes-one-member` starts two adapter worker processes with the same subscription name and member 0, appends 40 events, and records one durable effect before each handler returns `AckOk`. With Hackage `shibuya-kiroku-adapter` 0.5.1.2 and 0.5.1.3, both PostgreSQL 17 and 18 runs passed their at-least-once contract checks but each produced 80 effects: all 40 positions were handled by each process, and the checkpoint reached 40 without regression. The four sealed run IDs are `01a0de4e-a98f-7685-a754-7e2af923f04f`, `01a0de4e-f36d-74b5-bf33-8b52ab8a9573`, `01a0de50-71be-7233-b052-0e758e894d38`, and `01a0de50-ae7c-73f4-9883-86755d8f160c`. Their result files are in `mori://shinzui/keiro-runtime-kenshou` at project-relative `runs/<run-id>/run-result.json`; artifact-level run URIs are pending. The local finding is at project-relative `docs/findings/16-shibuya-kiroku-same-member-duplicate-work.md` in the same project; its artifact-level URI is pending.

For the released 0.5.1.2 PostgreSQL 18 arm, the reproducible invocation is:

```bash
cabal run -v0 kenshou -- run shibuya/kiroku-adapter/concurrency/two-processes-one-member --out runs --dim pg.version=18 --dim pg.durability=durable
```

That arm used seed `3761633945954261`, tracing and metrics off, PostgreSQL 18.6 with `fsync=on`, and the Hackage adapter source digest `e7dcd2560bec0e196bc2687df360486358f75eeb2859b06061abb76914974949`. Its full cohort identity is in the sealed run result. Hackage currently lists 0.5.1.5 and the matching upstream release tag exists; the 0.5.1.5 source still lacks a guard field on `KirokuAdapterConfig`, but this two-process scenario has not been rerun against that release.

## Requested change

1. Complete the lifetime-held store guard in `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-15` first. Keep the high-level option absent until its enabled behavior can actually exclude a concurrently running member.
2. Add an opt-in field to `KirokuAdapterConfig` and pass it to the store subscription configuration. Keep the default `False` so existing adapter deployments retain their current behavior.
3. Document the exact rejection behavior, the scope of `(subscription name, member)`, and what happens after a holder exits or crashes. Do not imply automatic group membership or exactly-once effects.

## Acceptance

With the option enabled, start two adapter consumers in separate processes for one subscription member. The second must fail startup with the store's member-conflict error while the first is active; after the first exits or is killed, a replacement must start and drain the remaining backlog. With the option disabled, the existing at-least-once two-process reproduction must remain possible and the default adapter configuration must be unchanged. Run both arms on PostgreSQL 17 and 18 and verify no event loss or checkpoint regression.
