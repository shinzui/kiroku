---
title: "Link an existing event into another stream"
type: Capability
description: "Add an existing event to a second stream by its event id, sharing the underlying event row through a stream-event junction rather than copying the payload."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-10
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Link
requires:
  - CAP-3
evidence:
  - kind: test
    resource: kiroku-store/test/Test/Properties.hs
    proves: Link preconditions — already-linked (EventAlreadyLinked), missing source event (LinkSourceEventMissing), and reserved-name rejection — behave as typed errors.
  - kind: guide
    resource: docs/user/linking.md
    proves: The linkToStream API and its junction-table model.
---

# Link an existing event into another stream

`linkToStream` adds already-[appended](append-with-optimistic-concurrency.md) events to a second
stream by event id, sharing the underlying `events` row through a `stream_events` junction row
instead of copying the payload. Link failures are typed (`EventAlreadyLinked`,
`LinkSourceEventMissing`).

## Usage

```haskell
linkToStream (StreamName "projection-inbox") [eventId1, eventId2]
```

## Limits

- **This capability is provisional and its evidence is weaker than the rest of the catalog.** The
  module header marks `linkToStream` provisional with *zero known consumers* (audited 2026-06-11:
  no usage in the downstream `keiro` consumer). It is the only public feature requiring the
  `stream_events` junction-table layout, which a future global-position migration may replace, so
  it may be **removed or redesigned**. It is exercised only through the shared property test above;
  there is no dedicated link test suite.
- Prefer designing around it unless you specifically need to share one event row across streams.
