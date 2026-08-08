---
title: "Causation and correlation graph queries"
type: Capability
description: "Walk the causation graph forward and backward from a seed event, and gather every event sharing a correlation id, using dedicated partial indexes."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-5
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Causation
requires:
  - CAP-4
evidence:
  - kind: test
    resource: kiroku-store/test/Test/Causation.hs
    proves: findCausationDescendants/findCausationAncestors/findByCorrelation return the expected sets in the documented order against a real store.
  - kind: guide
    resource: docs/user/causation-correlation.md
    proves: How to populate causation/correlation ids and traverse the graph.
---

# Causation and correlation graph queries

Given a seed event, `findCausationDescendants` and `findCausationAncestors` walk the
`causation_id` chain forward and backward; `findByCorrelation` returns every event sharing a
`correlation_id`. All three read the same `RecordedEvent` shape produced by the
[read surface](reading-events.md) and are backed by the partial indexes
`ix_events_causation_id` / `ix_events_correlation_id`, so cost scales as O(depth · log n).

## Usage

```haskell
descendants <- findCausationDescendants seedEventId
related      <- findByCorrelation correlationUuid
```

## Limits

- These queries only surface events that were appended carrying the relevant `causation_id` /
  `correlation_id` in their metadata; they cannot reconstruct relationships for events that never
  recorded those ids.
- Results honor `StoreSettings.decodeHook`, on parity with the other read paths.
