---
id: 35
slug: kiroku-metrics-and-event-stream-user-guide-and-runnable-example
title: "Kiroku Metrics And Event-Stream User Guide And Runnable Example"
kind: exec-plan
created_at: 2026-05-20T04:16:54Z
intention: "intention_01ks1saptfe6j8e98dvce7mvgf"
master_plan: "docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md"
---

# Kiroku Metrics And Event-Stream User Guide And Runnable Example

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is the fourth and final child plan under the MasterPlan
`docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md`. It
**hard-depends on EP-2**
(`docs/plans/33-http-json-prometheus-and-health-endpoints-for-kiroku-metrics.md`)
and **soft-depends on EP-3**
(`docs/plans/34-websocket-endpoint-for-live-metrics-and-event-streaming-out-of-the-store.md`).
The HTTP-endpoint half can be written and demonstrated as soon as EP-2 is
Complete; the WebSocket/event-streaming half of the guide and example should be
filled in once EP-3 is Complete (if EP-3 lands first, do both together).


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. EP-1 through EP-3 added the
`kiroku-metrics` package: an in-process collector, HTTP JSON/Prometheus/health
endpoints, and a WebSocket that pushes live metrics and streams events out of the
store. What is missing is the thing that makes all of it usable by someone who is
not the author: a focused, self-contained **user guide** and a **runnable example
program** that proves the guide is correct.

After this plan, a developer can:

- Open `docs/user/metrics.md`, follow it start to finish, and stand up the metrics
  server against their own `KirokuStore` — including the one non-obvious wiring
  step (constructing the collector and installing its callbacks on
  `ConnectionSettings` *before* `withStore`), the full list of endpoints with
  example request/response transcripts, the exact Prometheus metric names, the
  WebSocket message protocol for both the metrics and event channels, the
  deployment assumption (no built-in auth/TLS — run behind an internal network or
  a sidecar), and the documented limitations (per-subscription lag is an upper
  bound; the event tail is at-least-once / live-from-now unless `fromPosition` is
  given).
- Run a single command — `cabal run kiroku-metrics-example` — that boots an
  ephemeral PostgreSQL instance, opens a store with the collector wired in, starts
  the server, appends a handful of events, and then *checks its own endpoints*
  (HTTP GETs and a WebSocket round-trip), printing a transcript and exiting
  non-zero if any check fails. Because the example verifies itself, running it is a
  test that the documented behavior actually holds.

You can *see it working* by reading the rendered Markdown (links resolve, code
fences are tagged) and by running the example and observing its transcript and
exit code.


## Progress

- [ ] M1: `docs/user/metrics.md` written (overview, wiring, every HTTP endpoint with transcripts, Prometheus metric reference, deployment assumption, limitations); linked from `docs/user/README.md` and cross-linked from `docs/user/observability.md`.
- [ ] M2: WebSocket section of the guide (metrics channel + event channel protocol, `RecordedEvent` wire shape, `websocat` transcripts) — fill once EP-3 is done.
- [ ] M3: `executable kiroku-metrics-example` added to `kiroku-metrics.cabal`: a self-verifying runnable demo; `cabal run kiroku-metrics-example` exits 0 and prints the documented transcript.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Make the example **self-verifying** (it performs HTTP/WebSocket checks
  against its own server and exits non-zero on failure) rather than a passive
  demo.
  Rationale: The ExecPlan spec requires a *tested* example so the docs are
  demonstrably correct. A self-checking executable is the simplest way to keep the
  guide honest: if an endpoint regresses, `cabal run kiroku-metrics-example` fails
  in CI, no separate harness needed.
  Date: 2026-05-19

- Decision: Ship the example as an `executable` stanza in `kiroku-metrics.cabal`
  (not a separate package), with `ephemeral-pg` as an example-only dependency.
  Rationale: Keeps the library dependency-light (no `ephemeral-pg` in the
  library), mirrors how `shibuya` ships `shibuya-example`, and avoids creating a
  fifth Cabal package for a demo.
  Date: 2026-05-19


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What exists to document (from EP-1 / EP-2 / EP-3)

- Package `kiroku-metrics` (directory `kiroku-metrics/`). Umbrella import
  `import Kiroku.Metrics` brings in: the collector
  (`KirokuMetrics`, `newKirokuMetrics`, `metricsEventHandler`,
  `metricsObservationHandler`, `snapshotMetrics`), the snapshot types
  (`MetricsSnapshot` and sub-records), the server (`MetricsServerConfig`,
  `defaultConfig`, `MetricsServer`, `startMetricsServer`,
  `startMetricsServerWithStore`, `withMetricsServerWithStore`, `stopMetricsServer`),
  the health types (`DependencyCheck`, `DependencyStatus`, `postgresPing`), and the
  WebSocket protocol (`ClientMessage`, `ServerMessage`, `recordedEventToJSON`).
- HTTP endpoints (EP-2): `GET /metrics`, `GET /metrics/<subscription>`,
  `GET /metrics/prometheus`, `GET /health/live`, `GET /health/ready`, `GET /health`.
  Default port `9091`.
- WebSocket endpoints (EP-3): `ws://host:9091/ws/metrics` (snapshot + periodic
  push + ping/pong) and `ws://host:9091/ws/events` (live event tail, optional
  `fromPosition` replay and `category` filter). The exact JSON message shapes are
  defined in EP-3's `Kiroku.Metrics.WebSocket` (Integration Point IP-4); copy them
  verbatim into the guide so the doc is the authoritative wire reference.
- Prometheus metric names (EP-2's `Kiroku.Metrics.Prometheus`): list every metric
  name and its meaning. Treat EP-2's emitted set as authoritative; the guide is the
  human-facing index of it.

### The wiring subtlety to teach (the one non-obvious step)

`newKirokuMetrics` needs the `KirokuStore` (to read the global position and
subscriber count at snapshot time), but the collector's callbacks must be on
`ConnectionSettings` *before* `withStore` opens the store. EP-1's tests resolved
this; the canonical pattern (which the example uses and the guide documents) is:

```haskell
import Control.Lens ((&), (.~))
import Kiroku.Store
import Kiroku.Metrics

main :: IO ()
main = do
  -- 1. Create the collector. (If newKirokuMetrics needs the store, use the
  --    IORef-backed pattern EP-1 documented; otherwise pass the store after open.)
  --    The guide shows whichever final shape EP-1 settled on — read EP-1's
  --    Decision Log for the exact constructor ordering and reproduce it here.
  metrics <- {- construct collector -} undefined
  let settings =
        defaultConnectionSettings connStr
          & #eventHandler       .~ Just (metricsEventHandler metrics Nothing)
          & #observationHandler .~ Just (metricsObservationHandler metrics Nothing)
  withStore settings $ \store ->
    withMetricsServerWithStore defaultConfig metrics store [postgresPing store] $ \srv -> do
      putStrLn ("metrics server on port " <> show (serverPort srv))
      {- append events; the endpoints now reflect them -}
```

> When implementing this plan, open EP-1's finished `Kiroku.Metrics.Collector` and
> reproduce its *actual* constructor signature and ordering in both the guide and
> the example; do not invent an API. If EP-1 chose the `IORef (Maybe KirokuStore)`
> pattern, show it; if EP-1 made `newKirokuMetrics` deferrable, show that. The
> guide must compile against the real surface.

### The existing user-docs layout

`docs/user/` holds the user guides. `docs/user/README.md` is the index that links
each guide. `docs/user/observability.md` documents the in-process `eventHandler`/
`observationHandler` callbacks — the *raw* signals the new metrics package
aggregates — so it must cross-link to the new guide ("to expose these as an HTTP
endpoint, see Metrics"). Match the tone and structure of the existing guides
(e.g. `docs/user/subscriptions.md`, `docs/user/observability.md`): prose-first,
fenced code blocks with language tags, a "See Also" footer.


## Plan of Work

Three milestones. M1 can start after EP-2; M2 after EP-3; M3 after both (the
example exercises HTTP from EP-2 and WebSocket from EP-3).

### Milestone M1 — The HTTP half of the user guide

Scope: write `docs/user/metrics.md` covering everything that exists after EP-2,
and wire it into the docs index and the observability guide. At the end a reader
can stand up the server and hit every HTTP endpoint.

Sections to write:

1. **Overview** — what the package is (a sister package, like `kiroku-otel`), what
   it exposes, and the deployment assumption: *no built-in authentication or TLS;
   bind to an internal interface or run behind a sidecar/ingress that terminates
   them.*
2. **Wiring the collector** — the before-`withStore` pattern above, with a
   complete compiling snippet. Explain that the callbacks compose with an existing
   logger via the `Maybe (… -> IO ())` passthrough argument, and the
   fast-callback constraint (the collector's updates are non-blocking STM).
3. **Starting the server** — `defaultConfig` (document every field and its
   default, including `port = 9091`, `readinessMaxLag`, the `ws*` fields),
   `withMetricsServer`/`withMetricsServerWithStore`, and `stopMetricsServer`.
4. **HTTP endpoints** — one subsection per endpoint with a `curl` request and a
   representative JSON/text response in a fenced block:
   - `GET /metrics` (full snapshot; annotate each field group: `store`,
     `counters`, `subscriptions`, and explain `lag`).
   - `GET /metrics/<subscription>` (per-subscription; 404 when unknown).
   - `GET /metrics/prometheus` (and a **Prometheus metric reference** table:
     metric name, type, labels, meaning — one row per metric EP-2 emits).
   - `GET /health/live`, `GET /health/ready`, `GET /health` (semantics, the
     200/503 contract, how `readinessMaxLag` and dependency checks drive
     readiness, and how to add your own `DependencyCheck`).
5. **Interpreting the metrics** — the throughput interpretation
   (`kiroku_events_appended_total` is the gap-free global position == high water
   mark; rate via Prometheus `rate()`), and the **lag limitation**: per-subscription
   position updates only at lifecycle events (`Started`/`CaughtUp`/`Stopped`), so
   `lag` is an upper bound — a quietly-caught-up subscription shows its last
   lifecycle position. Reference the Marten/EventStoreDB lineage briefly (lag as
   the readiness signal) and the MasterPlan for the rationale.
6. **See Also** — links to `observability.md` (the raw callbacks),
   `subscriptions.md`, and (added in M2) the WebSocket section.

Then edit `docs/user/README.md` to add a link to `metrics.md`, and edit
`docs/user/observability.md`'s "Forwarding To Logs And Metrics" / "See Also" area
to cross-link the new guide.

Acceptance M1: the guide exists, all internal links resolve (`docs/user/*.md`
targets exist), all code fences carry a language tag, and the `curl` transcripts
match what a reader gets from a server started per the guide.

### Milestone M2 — The WebSocket half of the guide

Scope: extend `docs/user/metrics.md` with the WebSocket protocol, once EP-3 is
Complete. At the end a reader can connect with `websocat` and understand every
message.

Add a **WebSocket** section documenting, verbatim from EP-3's `Kiroku.Metrics.WebSocket`:

- The two paths `/ws/metrics` and `/ws/events`.
- The client→server messages (`ping`, `subscribe_metrics`, `subscribe_events`
  with optional `fromPosition`/`category`, `unsubscribe_events`) with JSON
  examples.
- The server→client messages (`pong`, `snapshot`, `event`,
  `event_stream_started`, `goodbye`, `error`) with JSON examples.
- The **`RecordedEvent` wire shape** produced by `recordedEventToJSON` — a
  field-by-field table (name, JSON type, meaning), matching EP-3's encoder exactly.
- The semantics: live-from-now by default, at-least-once, `DropOldest` backpressure
  (a slow client loses oldest events, never stalls the store), `fromPosition`
  replay (history then live, no duplicate boundary event), `category` filter
  (SQL-filtered).
- A `websocat` transcript: connect to `/ws/events`, send `subscribe_events`,
  append from another shell, observe the event message.

Acceptance M2: the WebSocket section matches EP-3's actual message types
(cross-checked against `Kiroku.Metrics.WebSocket`), with tagged code fences.

### Milestone M3 — The runnable, self-verifying example

Scope: add an `executable kiroku-metrics-example` to `kiroku-metrics.cabal` that
demonstrates and self-checks the whole stack. At the end `cabal run
kiroku-metrics-example` runs green and prints a transcript the guide can quote.

Cabal stanza (in `kiroku-metrics/kiroku-metrics.cabal`):

```cabal
executable kiroku-metrics-example
  import:         common
  main-is:        Main.hs
  hs-source-dirs: example
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , aeson
    , base            >=4.18 && <5
    , bytestring
    , ephemeral-pg    >=0.2
    , http-client     >=0.7
    , kiroku-metrics
    , kiroku-store
    , text
    , websockets      >=0.13
```

`example/Main.hs` flow (self-verifying — print a step, do it, assert, `exitFailure`
on any mismatch):

1. `EphemeralPg.withCached $ \db -> ...` to get a connection string.
2. Construct the collector (reproduce EP-1's actual ordering), build
   `ConnectionSettings` with the collector callbacks, `withStore`, and
   `withMetricsServerWithStore defaultConfig metrics store [postgresPing store]`.
   Use `port = 0` or a fixed high port; capture/echo the actual port.
3. Append, say, 3 events to `orders-1` via `runStoreIO`/`appendToStream`.
4. HTTP checks (via `http-client`): GET `/metrics` → 200 and `store.globalPosition
   >= 3`; GET `/metrics/prometheus` → 200 and body contains
   `kiroku_events_appended_total`; GET `/health/live` → 200; GET `/health/ready` →
   200.
5. WebSocket check (via `Network.WebSockets.runClient`): connect to `/ws/events`,
   send `{"type":"subscribe_events"}`, append one more event, assert an
   `{"type":"event",...}` message arrives (with a timeout).
6. Print `"kiroku-metrics-example: all checks passed"` and exit 0; on any failed
   assertion print what failed and `System.Exit.exitFailure`.

> Optionally, register the example in CI by also invoking it from the test-suite
> (a single `hspec` case that shells out with `readProcessWithExitCode "cabal"
> ["run","-v0","kiroku-metrics-example"] ""` and asserts exit 0 + the success
> line). This is optional because running the executable directly already serves
> as the test; record which you did.

Acceptance M3:

```bash
cabal run kiroku-metrics-example
```

prints the step transcript ending in `all checks passed` and exits 0. Quote the
transcript in the guide's "Try it" section.


## Concrete Steps

Run from the repository root inside `nix develop`.

1. M1: write `docs/user/metrics.md`; edit `docs/user/README.md` and
   `docs/user/observability.md` to link it. Verify links and fences:

   ```bash
   # every relative link target under docs/user resolves:
   grep -oE '\]\(([a-zA-Z0-9_-]+\.md)\)' docs/user/metrics.md
   # then confirm each named file exists in docs/user/
   ```

   Start a server per the guide and confirm the transcripts:

   ```bash
   curl -s localhost:9091/metrics | jq .store.globalPosition
   curl -s localhost:9091/metrics/prometheus | head
   curl -s -o /dev/null -w '%{http_code}\n' localhost:9091/health/ready
   ```

2. M2 (after EP-3): add the WebSocket section; cross-check message names against
   `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`. Confirm with `websocat`:

   ```bash
   websocat ws://localhost:9091/ws/events     # send {"type":"subscribe_events"}
   ```

3. M3: add the `executable` stanza and `example/Main.hs`; then:

   ```bash
   cabal build kiroku-metrics
   cabal run kiroku-metrics-example
   ```

   Expected tail:

   ```text
   [1/6] ephemeral postgres ready
   [2/6] store + collector + metrics server on port 54xxx
   [3/6] appended 3 events
   [4/6] HTTP /metrics globalPosition=3  /prometheus OK  /health/live 200  /health/ready 200
   [5/6] WebSocket /ws/events received event eventType=OrderCreated
   [6/6] kiroku-metrics-example: all checks passed
   ```

4. Commit per milestone with all three trailers:

   ```text
   docs(kiroku-metrics): user guide and runnable example

   MasterPlan: docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md
   ExecPlan: docs/plans/35-kiroku-metrics-and-event-stream-user-guide-and-runnable-example.md
   Intention: intention_01ks1saptfe6j8e98dvce7mvgf
   ```


## Validation and Acceptance

Complete when:

1. `docs/user/metrics.md` exists, is linked from `docs/user/README.md`, and is
   cross-linked from `docs/user/observability.md`; all internal links resolve and
   all code fences are language-tagged (repo formatting/pre-commit checks pass —
   `nix flake check` / the treefmt hook).
2. The guide documents: wiring, every HTTP endpoint with a transcript, the full
   Prometheus metric reference, every WebSocket message and the `RecordedEvent`
   wire shape, the no-auth deployment assumption, and the lag limitation.
3. `cabal build kiroku-metrics` builds the example executable; `cabal run
   kiroku-metrics-example` exits 0 and prints the documented success transcript.
4. The guide's transcripts match the example's/`curl`'s real output (no
   aspirational output). If you changed an endpoint shape while writing the guide,
   the change is reflected in the owning plan (EP-2/EP-3) and its tests.


## Idempotence and Recovery

Writing/rewriting the Markdown and the example is safe to repeat. The example uses
an ephemeral database and an OS-assigned (or fixed high) port, so repeated runs do
not collide or leave state. If the example's WebSocket check is flaky under load,
increase its receive timeout rather than removing the assertion. If a doc link
check fails, the target file name is wrong — fix the link, do not delete the
check.


## Interfaces and Dependencies

New artifacts:

- `docs/user/metrics.md` — the user guide.
- Edits to `docs/user/README.md` and `docs/user/observability.md` — index link and
  cross-link.
- `executable kiroku-metrics-example` in `kiroku-metrics/kiroku-metrics.cabal`,
  source `kiroku-metrics/example/Main.hs` — self-verifying runnable demo.

Dependencies consumed (all delivered by EP-1/EP-2/EP-3, plus `kiroku-store`):
`Kiroku.Metrics` umbrella (collector, server lifecycle including
`withMetricsServerWithStore`, config, health `postgresPing`, WebSocket protocol +
`recordedEventToJSON`); `Kiroku.Store` (`withStore`,
`defaultConnectionSettings`, `appendToStream`/`runStoreIO`, `StreamName`,
`AnyVersion`, `EventData`). Example-only libraries: `ephemeral-pg`, `http-client`,
`websockets`, `aeson`, `bytestring`, `text`.

This plan changes no Haskell library code in `kiroku-store` or in the
`kiroku-metrics` library; it only adds documentation and an example executable. If
writing the guide reveals a missing or wrong endpoint behavior, fix it in the
owning plan (EP-2 or EP-3) and its tests, then document the corrected behavior
here.
