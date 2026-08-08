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
    proves: End-to-end against a real ephemeral PostgreSQL and the real pinned shibuya-core — event-to-envelope conversion, ack decisions driving Kiroku checkpointing, consumer-group completeness/disjointness, and clean-shutdown/crash-propagation termination.
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

## Usage

```haskell
adapter <- kirokuAdapter store (defaultKirokuAdapterConfig "orders" AllStreams)
```

## Limits

- This is an integration package: what it *provides* is the adapter and its conversion, proven here
  end-to-end. Any end-to-end guarantee across the boundary also depends on `shibuya-core` (pinned
  `>=0.8 && <0.9`), which is a separate project — see its own capabilities for what the framework
  provides.
- The package's `Known Limitations` (0.4.0.0) record that `shibuya-core` still needs upstream fixes
  for finalize-on-exception in its supervised processor and for propagating ingester stream
  failures; the adapter-side guard (`guardKirokuHandlerWith`) is defensive and stays correct after
  those land.
- Ack decisions became load-bearing in `0.2.0.0`; in `0.1.0.0` `AckRetry`/`AckDeadLetter` were
  no-ops. Consumer-group presentation and filter forwarding arrived in `0.2.0.0`.
- `Envelope` carries no raw broker headers (`headers = Nothing`); Kiroku events have none.
