---
title: "Shibuya queue-framework adapter"
type: Capability
description: "A published adapter package that presents a Kiroku subscription (or a whole consumer group) as a Shibuya pull-based Adapter, mapping ack decisions onto Kiroku's per-event retry, dead-letter, and checkpoint semantics."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-19
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-kiroku-adapter
interface:
  - Shibuya.Adapter.Kiroku
  - Shibuya.Adapter.Kiroku.Convert
requires:
  - CAP-11
  - CAP-12
  - CAP-13
evidence:
  - kind: test
    resource: shibuya-kiroku-adapter/test/Main.hs
    proves: End-to-end against a real ephemeral PostgreSQL and the exact candidate core — event-to-envelope conversion; retry, halt, duplicate-finalization, and checkpoint-replay semantics; existing/missing checkpoint policies; exception-safe consumer-group acquisition; and leak-free clean, cancelled, and crashed termination.
  - kind: benchmark
    resource: kiroku-store/bench/ShibuyaOverhead.hs
    proves: Measures the adapter's per-event overhead over a direct subscription.
---

# Shibuya queue-framework adapter

This repository publishes `shibuya-kiroku-adapter`, a package that wraps a Kiroku
[subscription](live-subscriptions.md) into a Shibuya `Adapter`. `kirokuAdapter` /
`defaultKirokuAdapterConfig` build a single adapter; `kirokuConsumerGroupProcessors` presents a
whole [consumer group](partitioned-consumer-groups.md) as one `PartitionedInOrder` unit of `N`
`QueueProcessor`s. It bridges through the ack-coupled `subscriptionAckStream` so Shibuya
`AckDecision`s drive Kiroku's [per-event retry/dead-letter](resilient-delivery.md) and
checkpointing, and it forwards event-type filters and selectors.

Consumer-group construction keeps every successfully created member in a masked
ownership ledger until the complete processor list is returned. Cancellation or
a later factory failure therefore attempts every acquired member's shutdown in
reverse order, and a throwing shutdown cannot replace the primary construction
failure. The underlying ack-stream bridge applies the same rule while handing a
single subscription to its monitor; its idempotent cancel action waits until no
subscription worker or monitor remains.

## Usage

```haskell
adapter <- kirokuAdapter store (defaultKirokuAdapterConfig "orders" AllStreams)
```

## Limits

- This is an integration package: what it *provides* is the adapter and its conversion, proven here
  end-to-end. Any cross-boundary guarantee also depends on
  `mori://shinzui/shibuya/packages/shibuya-core`. The currently committed range is
  `>=0.9 && <0.10`; the coordinated candidate is selected with a temporary Cabal project, and the
  final release bound is intentionally deferred to the release-candidate certification.
- The candidate Shibuya supervised runner converts synchronous handler exceptions to immediate
  `AckRetry` and always invokes the finalizer. `guardKirokuHandlerWith` remains the adapter's way to
  choose a different exception disposition; asynchronous cancellation is never converted into an
  acknowledgement.
- Ack decisions became load-bearing in `0.2.0.0`; in `0.1.0.0` `AckRetry`/`AckDeadLetter` were
  no-ops. Consumer-group presentation and filter forwarding arrived in `0.2.0.0`.
- `Envelope` carries no raw broker headers (`headers = Nothing`); Kiroku events have none.
