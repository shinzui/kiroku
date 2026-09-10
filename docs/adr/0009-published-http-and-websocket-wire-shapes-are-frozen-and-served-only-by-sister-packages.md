---
type: Architecture Decision Record
title: Published HTTP and WebSocket wire shapes are frozen and served only by sister packages
description: "Treat every documented kiroku-metrics JSON body, WebSocket frame, and Prometheus metric name as a published contract that only grows additively, with incompatible changes shipping as new paths or frame types, and keep the HTTP and WebSocket surface in sister packages that wrap supported kiroku-store APIs."
generated:
  by: anthropic/claude-fable-5-1
  at: "2026-09-10T03:20:08Z"
docId: ADR-9
status: Accepted
date: 2026-09-10
timestamp: "2026-09-10T03:20:08Z"
---

# ADR-0009: Published HTTP and WebSocket wire shapes are frozen and served only by sister packages

- **Related:** [IR-13](../improvement-requests/record-http-and-websocket-wire-format-stability-in-an-adr.md);
  [IR-12](../improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md);
  [ADR-1](0001-resolve-stream-names-via-lookup-not-recordedevent-field.md);
  [ADR-6](0006-versioned-public-sql-relations-are-owner-published-and-frozen.md);
  [MasterPlan 5](../masterplans/5-metrics-and-event-streaming-http-endpoint-package.md);
  [ExecPlan 87](../plans/87-serve-durable-subscription-checkpoints-over-http.md);
  [ExecPlan 88](../plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md);
  [Metrics, Health, And Event Streaming Over HTTP](../user/metrics.md);
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`;
  `mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md` (artifact-level
  URI pending).

## Context

`kiroku-metrics` 0.1.0.8 serves a running store's operational surface over HTTP and WebSocket:
JSON metrics at `GET /metrics` and `GET /metrics/<subscription>`, Prometheus text at
`GET /metrics/prometheus`, probes at `GET /health/live`, `GET /health/ready`, and `GET /health`,
the live subscription registry at `GET /subscriptions` and `GET /subscriptions/<name>`, a metrics
push channel at `/ws/metrics`, and an event tail at `/ws/events`. Every JSON shape is a
hand-written encoder, chosen in MasterPlan 5 precisely so the wire would be stable and
documentable. The frame envelope and the metrics keys are snake_case; the event object inside an
`event` frame is camelCase (`eventId`, `globalPosition`, ...) because `recordedEventToJSON` was
written as an explicit function in the sister package rather than as a `ToJSON` instance on a
`kiroku-store` type. The `/subscriptions` row codec lives in `kiroku-cli`, shared by the server
encoder and the CLI's remote-worker decoder.

The reasons for that arrangement exist only as MasterPlan 5 Decision Log entries and Haddock
comments. Nothing in the ADR corpus states what a network client may rely on. For database-native
surfaces [ADR-6](0006-versioned-public-sql-relations-are-owner-published-and-frozen.md) already
records that published relations are frozen and versioned; the HTTP layer has no equivalent
record. Meanwhile external clients are being built directly against these shapes: the keiro
runtime UI initiative froze the WebSocket dialect from its side in
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`, its conventions document presumes the same
discipline at the HTTP layer, IR-12 asks for strictly additive WebSocket convergence, and
ExecPlans 87 and 88 add new routes while promising that existing shapes stay unchanged. Each of
these leans on a promise kiroku had not made in a citable form. The changelog for 0.1.0.4 through
0.1.0.8 shows the intended shape of the relationship in practice: five `kiroku-store` releases
were absorbed with no change to any endpoint or frame.

## Decision

### 1. What is published

A wire shape is a published contract once it ships in a Hackage release of a kiroku sister package
and is documented in that package's user guide, today `docs/user/metrics.md`. The guide is the
normative inventory; this record fixes the rule for membership and change, so the inventory can
grow without amending the record. As of `kiroku-metrics` 0.1.0.8 the published contract comprises:

- The JSON bodies of `GET /metrics`, `GET /metrics/<subscription>`, `GET /health/live`,
  `GET /health/ready`, `GET /health`, `GET /subscriptions`, and `GET /subscriptions/<name>`: their
  key names, JSON value types, nesting, and the HTTP status codes each route returns, including
  the `200`/`503` probe verdicts and the `404` responses for an unknown subscription name and an
  unconfigured status provider.
- The legacy error envelope `{"error": "<string>"}` on every route that ships it. The key and its
  string type are frozen. The human-readable text is not a contract and clients must not switch on
  it.
- The Prometheus exposition at `GET /metrics/prometheus`: metric names, metric types, and label
  names.
- The WebSocket paths `/ws/metrics` and `/ws/events`; the client frame inventory `ping`,
  `subscribe_metrics`, `subscribe_events` with its optional `from_position` and `category`
  fields, and `unsubscribe_events`; the server frame inventory `pong`, `snapshot`, `event`,
  `event_stream_started`, `goodbye`, and `error` with their fields; and the identity between the
  `snapshot` frame's `metrics` object and the `GET /metrics` body.
- The event object carried by `event` frames as produced by `recordedEventToJSON`: its eleven
  camelCase keys and their JSON types.
- The documented delivery semantics clients build on: `event` frames arrive in global-position
  order; a `from_position` replay pages history first and then continues live with no duplicate
  at the boundary; a slow client loses the oldest undelivered batches and is told in-band by an
  `error` frame; an event tail creates no persistent subscription and writes no checkpoint.
- Enumerated string vocabularies such as subscription phases, stop reasons, and Prometheus label
  values: every shipped member keeps its spelling and meaning.

Not published, and free to change between releases: the default port and every
`MetricsServerConfig` field (those are Haskell API under the PVP), push timing and intervals,
key order and whitespace inside a JSON document, the text of WebSocket upgrade rejections, the
`Show`-rendered detail inside an `error` frame's `message`, and any route or frame that is
unreleased or undocumented.

### 2. How a published shape may change

This is the HTTP-layer analogue of ADR-6.

- A published field is never removed, renamed, or re-typed. A frame's `type` name and meaning
  never change. A route's path and method never change.
- Additive change is allowed without a new path or frame: a new optional field on an existing
  object, a new server frame type, a new route, a new Prometheus metric or label, and a new member
  of an enumerated vocabulary. A new required client field is not additive, because a client
  sending yesterday's frame must keep working.
- An incompatible change ships as a new path or a new frame type. The old one stays available for
  its documented compatibility window and is retired only in a major version with a changelog
  entry and a guide update.
- New keys are snake_case everywhere, including on the camelCase event object. The event object's
  casing is frozen as shipped and is not precedent for anything new.
- Servers ignore client frames they do not understand, as `kiroku-metrics` already does. Clients
  must ignore unknown server frames, unknown fields, and unknown vocabulary members.
- A change to a published encoder updates the user guide in the same change, and a new surface
  ships with a test that pins its key set, as ExecPlans 87 and 88 already require.

### 3. Who serves the surface

- `kiroku-store` owns no wire format. It gains no web dependency (`wai`, `warp`, `websockets`,
  `http-types`, or their kin), and its exported types are not wire contracts; a published shape is
  defined by the serving package's encoder and guide, never by a library type's structure.
- The HTTP and WebSocket surface lives in sister packages, today `kiroku-metrics`, which depend on
  `kiroku-store` and never the reverse. A sister package wraps supported public APIs only: the
  `eventHandler` and `observationHandler` callback seams, the public reads on the store handle,
  the `Store` effect, `subscribePublisher`, and `subscriptionStates`. It issues no SQL against
  Kiroku-owned tables; its one query is the `SELECT 1` dependency ping through the store's pool.
- When a serving package needs a read the library does not offer, the read is added to
  `kiroku-store` as a public API first, as ADR-1's stream-name lookup and ExecPlan 88's browse
  primitives do, and the endpoint wraps it.
- A codec shared between a server and a client in this repository has one definition that both
  sides import, as `SubscriptionStatusRow` in `kiroku-cli` does for `GET /subscriptions`; the
  freeze in section 2 applies to that definition.
- `kiroku-store` keeps evolving under the PVP. A sister package absorbs library changes without
  altering the wire, and a release that only tracks a library bump says so in its changelog.

## Consequences

**Positive**

- External clients, including the keiro runtime UI, the CLI's remote-worker mode, and Prometheus
  dashboards, can cite this record as the authority for what will not change beneath them.
- IR-12's additive convergence and the new routes in ExecPlans 87 and 88 have a rule to follow
  and a criterion for when a shape becomes published.
- `kiroku-store` can change its Haskell API and storage freely; the wire contract is insulated
  behind the sister package, and the reverse dependency direction stays impossible.
- The mixed casing of the event object is recorded as a deliberate, closed decision rather than a
  latent cleanup task that would break every shipped client.

**Negative**

- Every shipped field is permanent. A field exposed by accident costs a new path to undo, so
  implementers must weigh each key before it ships.
- The casing inconsistency between the envelope and the event object is now permanent by policy.
- The legacy string error envelope persists on the original routes beside any structured envelope
  a newer route adopts, so a client that spans both must handle both.
- A new vocabulary member can still surprise a client that matches exhaustively; the record places
  that burden on clients rather than forbidding kiroku from ever adding a phase or reason.
- The shared `SubscriptionStatusRow` codec ties `kiroku-metrics` to a `kiroku-cli` dependency,
  which constrains how those packages can be split or released.

## Alternatives Considered

- **Prefix the whole surface with `/v1` now and version by prefix.** Rejected because the shipped
  paths already have consumers, so introducing the prefix is itself the breaking change this
  record forbids; per-surface new paths give the same outcome without a flag day, as ADR-6's
  `_v2` relations do.
- **Rename the event object's camelCase keys to snake_case for consistency.** Rejected because
  it breaks every shipped client, and the keiro runtime UI initiative has already frozen the
  dialect from its side.
- **Add a `ToJSON RecordedEvent` instance to `kiroku-store` and let the library own the wire.**
  Rejected because a library type would become a wire contract, coupling every PVP change to a
  compatibility question, and because the store keeps its types module instance-light.
- **Serve the endpoints from `kiroku-store` behind a cabal flag.** Rejected because it pulls the
  web closure into every consumer's build and blurs which package stands behind the wire.
- **Negotiate a protocol version on the WebSocket.** Rejected because the additive rule makes
  negotiation unnecessary and IR-12 rules it out of scope.
- **Leave the contract in MasterPlan 5's Decision Log and the user guide.** Rejected because plans
  are historical narrative without a stable citable handle; that gap is what IR-13 names.
