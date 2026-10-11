---
id: 94
slug: converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention
title: "Converge the kiroku-metrics WebSocket protocol with the cross-project convention"
kind: exec-plan
created_at: 2026-09-30T22:35:20Z
intention: "intention_01m3t7a7jaeewbf71vqrzk4zd8"
master_plan: "docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T22:35:20Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:06Z
      mode: "update"
      note: "Correct current APIs, integration ownership and bounded observer work; runtime acceptance remains pending."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-11T01:56:04Z
      mode: "implement"
      note: "Implement bounded WebSocket convergence and validate local delivery, lifecycle and publisher behavior"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:06Z
      verdict: "comments"
      note: "Source review corrections applied; SQL promotion and focused performance gates require implementation evidence."
---

# Converge the kiroku-metrics WebSocket protocol with the cross-project convention

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is EP-5 of
[MasterPlan 13, Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md).
It implements the improvement request
[IR-12, Converge the WebSocket protocol with the cross-project convention](../improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md),
canonically `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-12`, filed by the keiro
runtime UI initiative (`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`). Every
commit made under this plan carries three trailers:

```text
MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md
ExecPlan: docs/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md
Intention: intention_01m3t7a7jaeewbf71vqrzk4zd8
```


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store written in Haskell. Its HTTP sister package,
`kiroku-metrics`, serves two WebSocket paths from the same Warp server as its JSON endpoints:
`/ws/metrics` pushes metrics snapshots, and `/ws/events` streams appended events out of the store
in global-position order, optionally replaying history from a chosen position and optionally
filtered to one category. Two browser applications are about to be built against that surface:
the composed keiro runtime UI (which drives kiroku's, shibuya's, pgmq's, and keiro's WebSocket
surfaces with one client core) and, possibly, a standalone Kiroku UI for users who adopt only the
event store. The keiro-ui initiative wrote a structural convention that every WebSocket
inspection endpoint in the stack should fit, and asked kiroku (IR-12) to audit its two paths
against it, close every gap that can be closed additively, document the rest as deviations, and
publish a conformance mapping the client core is built against.

After this plan, three things are true that are not true today.

First, a client that stops caring about metrics can say so: `/ws/metrics` accepts a new
`{"type":"unsubscribe_metrics"}` frame that stops the periodic snapshot push, and
`{"type":"subscribe_metrics"}` restarts it, so the convention's explicit subscribe/unsubscribe
lifecycle holds on both paths while the shipped push-on-connect behaviour stays exactly as it is
for existing clients.

Second, every `error` frame carries a stable machine-readable `code` next to its human `message`,
and the overflow signal the user guide has always promised is actually delivered: a slow
`/ws/events` client that lost batches under the bounded drop-oldest queue receives
`{"type":"error","code":"event_stream_overflowed","message":"..."}` in-band and knows to re-read
from its last position. Today that frame is unreachable (see Context and Orientation), so a browser
tail can silently show a gapped feed as if it were complete.

Third, every `event` frame on `/ws/events` carries the resolved source stream name as a new
optional key `original_stream_name` on the event object, resolved server-side through the public
batch lookup, so a browser that only has the WebSocket can label a live tail with stream names
instead of surrogate integers. The REST browse pages of plan 88 use the same key and the same
encoder, so one client decoder serves both.

Seeing it work is a `websocat` session against any store-backed metrics server:

```text
$ websocat ws://localhost:9091/ws/events
{"type":"subscribe_events"}
{"type":"event_stream_started","from_position":42}
# (append OrderCreated to orders-7 from another shell)
{"type":"event","event":{"eventType":"OrderCreated","globalPosition":43,"originalStreamId":9,"original_stream_name":"orders-7", ...}}
```

and, on the metrics path:

```text
$ websocat ws://localhost:9091/ws/metrics
{"type":"snapshot","metrics":{...}}
{"type":"snapshot","metrics":{...}}
{"type":"unsubscribe_metrics"}
# (silence: no more periodic snapshots)
{"type":"subscribe_metrics"}
{"type":"snapshot","metrics":{...}}
{"type":"snapshot","metrics":{...}}
```

Nothing that is published today changes shape: the frame inventory, every existing field, the
camelCase keys of the event object, the queue capacity and drop-oldest semantics, and the path
dispatch are byte-for-byte what they were, and the existing `Test.WebSocketSpec` passes without a
single edit. The user guide gains a conformance mapping that names, for every element of the
convention, the kiroku frame that realises it or the recorded deviation.


## Progress

- [x] (2026-10-10) Reviewed the integrated design against current source; corrected API and performance hazards. This is planning work, not implementation evidence.
- [x] (2026-10-11) Implement and execute the focused correctness and performance acceptance added by this review.

- [x] (2026-10-11) M1: IR-12 moved from `accepted` to `in_progress` (timestamp advanced, bundle log entry,
      strict validation green).
- [x] (2026-10-11) M1: `kiroku-store`: `Subscriber` gains `subDropped :: TVar Word64`; the `DropOldest` branch
      of `deliverBatchSTM` increments it; new `PublisherSubscription` record and
      `subscribePublisherWith`; `subscribePublisher` kept as a compatibility wrapper; changelog
      bullets under the unreleased heading.
- [x] (2026-10-11) M1: `kiroku-store/test/Test/PublisherDropCounter.hs` proves the counter deterministically
      (cap 1, two batches, counter 1, queue holds the newest batch); registered; store suite
      green; `cabal bench kiroku-store:kiroku-shibuya-overhead` recorded before and after.
- [x] (2026-10-11) M2: `Kiroku.Metrics.WebSocket`: `UnsubscribeMetrics` client frame, `CodedError` server frame
      with the four codes, reuse of plan 88's `recordedEventToJSONResolved`, per-connection
      stream-name cache in the tail, overflow detection from the drop counter,
      `overflowNotice` exported for testing; changelog bullets under `## Unreleased`.
- [x] (2026-10-11) M2: `kiroku-metrics/test/Test/WebSocketConvergenceSpec.hs` (frame shapes pinned,
      unsubscribe/resubscribe on the metrics path, `original_stream_name` on the live and
      category paths, `replay_failed` and `category_read_failed` codes end to end,
      `overflowNotice` cases); registered; whole metrics suite green with `Test.WebSocketSpec`
      untouched.
- [x] (2026-10-11) M3: `docs/user/metrics.md` WebSocket section updated (new frames, the `code` vocabulary,
      the `original_stream_name` key, the conformance mapping table); CAP-17 and the
      capabilities log updated and validated; IR-12 body gains "Implementation Evidence";
      all repository validations green.
- [x] (2026-10-11) M3: ADR distillation pass recorded in Outcomes (no ADR expected; see Decision Log);
      closing provenance revision recorded.


## Surprises & Discoveries

- 2026-10-11 local acceptance: all 654 examples across six suites, ten-step example and Nix builds pass after the fixture barriers. Frozen encoders/dispatch/spec and nonfull/other-policy publisher branches compare byte-identically to `c725aac`. Retained [evidence](../../kiroku-metrics/bench/results/mp13-ep5-websocket-convergence/README.md) includes failures and isolated follow-ups; no remote runs or release acceptance are inferred.

```text
100 events baseline: bare subscribe:  median 9 ms  [8 ms .. 42 ms]  (11609 events/s, 86 μs/event)
100 events isolated after: bare subscribe:  median 13 ms  [6 ms .. 19 ms]  (7643 events/s, 131 μs/event)
1000 events baseline: bare subscribe:  median 17 ms  [16 ms .. 31 ms]  (60544 events/s, 17 μs/event)
1000 events isolated after: bare subscribe:  median 19 ms  [18 ms .. 29 ms]  (52051 events/s, 19 μs/event)
5000 events baseline: bare subscribe:  median 43 ms  [42 ms .. 46 ms]  (117534 events/s, 9 μs/event)
5000 events isolated after: bare subscribe:  median 77 ms  [67 ms .. 188 ms]  (64847 events/s, 15 μs/event)
Same-condition control/candidate pair (original publisher, then counter publisher):
100 events control: bare subscribe:  median 11 ms  [5 ms .. 14 ms]  (9185 events/s, 109 μs/event)
100 events candidate: bare subscribe:  median 11 ms  [9 ms .. 15 ms]  (8960 events/s, 112 μs/event)
1000 events control: bare subscribe:  median 38 ms  [27 ms .. 46 ms]  (26248 events/s, 38 μs/event)
1000 events candidate: bare subscribe:  median 24 ms  [19 ms .. 40 ms]  (41827 events/s, 24 μs/event)
5000 events control: bare subscribe:  median 86 ms  [67 ms .. 274 ms]  (58467 events/s, 17 μs/event)
5000 events candidate: bare subscribe:  median 70 ms  [63 ms .. 98 ms]  (71424 events/s, 14 μs/event)
```

- 2026-10-11: the isolated 5000-event bare row remained adverse (77 ms vs early 43 ms), so one bounded same-condition original-publisher/control-counter check was run, preserving both five-sample cases and restoring candidate source on every normal/error exit. Original publisher now measured 86 ms [67..274], counter publisher 70 ms [63..98]; smaller-case ranges overlap as well. This shows the earlier movement is not attributable to the counter alone, rather than proving zero regression. No additional publisher repeats. The controller finished in under its 12-minute ceiling with exact source restoration verified.
- 2026-10-11: the preliminary tail harness control omitted the old filter/status sample. Retain both preliminary outputs; correct the control to reproduce those existing steps and run one final five-round comparison. Lookup/cache/append-visibility assertions remain unchanged. Interpret local timings descriptively and leave integrated real-socket/publisher observer acceptance with plan 96.

- 2026-10-11: the first final all-suite run retained a second failure in the existing pause/resume fixture (448 store examples, one missing Resumed callback). Event delivery and checkpoint 5 passed. The atomic callback collector from EP-4 remained intact; the fixture still failed to wait for Live before its blocked first event, allowing catch-up to bypass the resume path. Added the same bounded Live barrier to its PauseAndResume and DropSubscription scenarios, retaining every original assertion. No production FSM change.
- 2026-10-11: the first post-counter overhead run and first tail-cost run overlapped the Nix build. Their raw adverse/noisy results are retained but cannot establish runtime neutrality; perform one isolated follow-up, then hand cumulative acceptance to plan 96 without another broad experiment.

- 2026-10-11: first full store run reported 448 examples, one failure in the pre-existing F6 overflow-restart fixture. It started its blocked first handler before observing Live, permitting catch-up to consume the range the restart expected to replay. Added a bounded currentState/Live barrier before the first append; production DropSubscription and worker behavior stay unchanged. Retain the adverse log and run focused plus full checks after the fixture fix.

- 2026-10-11 baseline: build and 77 metrics tests passed. The prescribed Shibuya benchmark failed before sampling because it opened an unmigrated ephemeral database (`42P01`, missing streams). Added the existing migration helper to benchmark setup only; retain the failed log and rerun before publisher edits.

- 2026-10-10 source review: Publisher queues now contain DecodedBatch. The proposed name Map grew for the lifetime of the tail, and notices followed survivors, allowing loss of the client's safe recovery cursor. Separate counter/encoder tests did not prove delivery ordering. No runtime acceptance is inferred from this finding.

- Planning (2026-09-30): the overflow `error` frame documented in `docs/user/metrics.md`
  ("a slow client loses the oldest undelivered batches and is told in-band by an `error` frame")
  and enumerated as a published delivery semantic in
  [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
  is never emitted. `broadcastLoop` in `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` sends it
  only when the subscriber's status is `Overflowed`, but `deliverBatchSTM` in
  `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` sets `Overflowed` only under
  `DropSubscription`; under `DropOldest`, the policy the WebSocket uses, it silently discards the
  oldest queued batch (`tryReadTBQueue` then `writeTBQueue`) and leaves the status `Active`. The
  module's own comment admits it: "Defensively surfaces an `Overflowed` status (not set under
  `DropOldest`, but handled)". This plan closes that gap with a drop counter in the publisher
  (Milestone 1) rather than documenting a deviation, because both the convention and ADR-9
  already promise the signal.
- Planning (2026-09-30): IR-12's candidate gap "idle-connection server pings may not run on both
  paths" is wrong against source. `handleMetrics` and `handleEvents` both wrap their bodies in
  `WS.withPingThread conn 30 (pure ())`, which sends a WebSocket ping every 30 seconds on every
  connection. The conformance mapping records server idle pings as met with the 30-second
  precedent the convention names.


## Decision Log

- Decision (2026-10-11): use an opaque per-tail cache and injectable production delivery helper plus one scoped linked-worker slot for both channels. The old event-tail acquisition also had an async registration gap; share the masked acquisition/finalization fix rather than retaining it. Frame writers and lookup callbacks are serialized by the tail. No append statement or default publisher delivery branch changes.
- Decision (2026-10-11): the convention mapping explicitly records complete periodic metrics snapshots as a retained deviation from state deltas. The source convention at `mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md` (artifact URI pending), requires update deltas; additive lifecycle repair does not change the frozen snapshot dialect. Mori now resolves `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`.

- Decision (2026-10-10): the reviewed Context and Plan of Work supersede incompatible September choices on dependencies, routes, decoding, method handling, bounds and performance. Implementation remains pending; durable constraints are in ADR-15.
  Rationale: the released APIs changed and the original sketches contained correctness and shared-resource hazards.

- Decision: Every change is additive at the wire and, where possible, at the Haskell API. No
  published frame, field, path, status, or documented semantic is renamed, removed, re-typed, or
  given a new meaning; `dispatchPath`, `recordedEventToJSON`, `wsEventQueueCap`, `DropOldest`,
  and the existing `Test.WebSocketSpec` are untouched.
  Rationale: [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
  freezes the shipped surface and allows only additive growth; IR-12's Boundaries section makes
  any breaking change unacceptable; `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2` freezes the
  dialect from the client side. The existing spec passing unmodified is IR-12's first acceptance
  item and the cheapest proof that nothing shipped moved.
  Date: 2026-09-30

- Decision: Error codes are carried by a new `ServerMessage` constructor
  `CodedError !Text !Text` (code, message) encoding to `{"type":"error","code":c,"message":m}`;
  the existing `ErrorMsg !Text` constructor and its encoding stay exactly as they are, and the
  four places that build error frames today switch to `CodedError` with the codes
  `replay_failed`, `category_read_failed`, `live_decode_failed`, and `event_stream_overflowed`.
  Rationale: Adding a constructor is additive for Haskell callers that only construct or encode
  frames (pattern matches on `ServerMessage` in this repository are the `ToJSON` instance alone),
  and it keeps `toJSON (ErrorMsg m)` byte-identical by construction rather than by a `Maybe`
  field that must be threaded correctly. A client that ignores `code` sees exactly yesterday's
  frame; a client that switches on it no longer depends on message text, which ADR-9 says is not
  a contract.
  Date: 2026-09-30

- Decision: The unreachable overflow signal is fixed, not documented as a deviation. The
  publisher counts dropped batches per subscriber in a new `subDropped :: TVar Word64` field on
  `Subscriber`, incremented inside the existing `DropOldest` branch of `deliverBatchSTM`; a new
  `subscribePublisherWith` returns a `PublisherSubscription` record that exposes the counter, and
  `subscribePublisher` becomes a wrapper that returns the same triple it returns today. The
  WebSocket tail samples the counter with dequeue before every delivered batch and emits one `event_stream_overflowed`
  error per observed increase.
  Rationale: The convention (area 5) requires overflow to be signalled in-band, ADR-9 lists that
  signal among the published delivery semantics, and the user guide has promised it since the
  package shipped; recording "we never send it" would document a defect. The counter is exact
  where a global-position gap heuristic is not (a hard delete can also produce a gap, and category
  tails never overflow because they are SQL-driven). The ordinary delivery path (`not full`) is
  untouched, so the per-batch hot path of the publisher gains no work; the increment runs only
  when a batch is already being dropped. `Subscriber (..)` is exported with its fields, so the new
  field is a PVP-major change to `kiroku-store`, which the cohort release (plan 96) already
  carries for plans 88 and 89.
  Date: 2026-09-30

- Decision: `/ws/metrics` gains `unsubscribe_metrics`, which cancels the periodic push loop, and
  `subscribe_metrics` additionally restarts that loop when it is stopped while keeping its shipped
  meaning of "send a snapshot now". Push-on-connect stays.
  Rationale: The convention wants a connection to watch nothing until it subscribes; the shipped
  dialect pushes on connect and that behaviour is frozen. Accepting an unsubscribe frame and
  letting subscribe restart the loop gives a convention-shaped lifecycle to new clients without
  changing what an old client experiences. The push loop already runs in its own thread, so the
  change is a `TVar (Maybe (Async ()))` in the same shape `handleEvents` uses for its tail.
  Date: 2026-09-30

- Decision: `event` frames gain the optional key `original_stream_name` on the event object,
  resolved with the public `lookupStreamNames` through a per-connection `Map StreamId StreamName`
  cache, one batched lookup per delivered batch covering only ids the connection has not seen.
  The encoder is `recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value`
  in `Kiroku.Metrics.WebSocket`, owned by plan 88; this plan introduces it only if plan 88 has not
  landed, with exactly that name, type, and module.
  Rationale: [ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md)
  keeps the name off `RecordedEvent` because carrying it on every `$all` read row measured about
  13% on `$all` pages, and it names the batch lookup as the intended resolution path. A transient
  WebSocket watcher is not a subscription worker and not an append; the lookup runs on the tail
  path only, and the cache means a stable set of streams costs one round trip per new stream, not
  per batch. The keiro-ui conventions require a new key on the frozen camelCase event object to
  be snake_case, and plan 88's Decision Log already fixed the key name so REST items and WebSocket
  frames share one decoder. `null` is emitted when an id cannot be resolved (the stream was hard
  deleted between publish and lookup) rather than dropping the event.
  Date: 2026-09-30

- Decision: Snapshot-then-delta on `/ws/events` is a documented deviation, not additively
  closed. The `event_stream_started` acknowledgement, which carries the `from_position` the
  tail starts from, is recorded as the frame that plays the snapshot role.
  Rationale: An append-only feed has no current state to snapshot; the convention itself
  distinguishes state surfaces (`update` after `snapshot`) from log-tail surfaces (`event`
  frames), and the acknowledgement already gives the client the one fact a snapshot would give
  it, the position from which the feed is complete.
  Date: 2026-09-30

- Decision: Nothing in this plan changes `dispatchPath`, hard-codes an absolute URL, or assumes
  the application is mounted at the root of a host.
  Rationale: keiro will mount the exported `kiroku-metrics` WAI application behind a path prefix
  (`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`), and the composed deployment
  is the keiro-ui initiative's primary target; the WebSocket dispatch on `WS.requestPath` is
  keiro's to rewrite, not ours to assume.
  Date: 2026-09-30

- Decision: No version bump and no release in this plan. Changelog bullets go under
  `## Unreleased` in `kiroku-metrics/CHANGELOG.md` and under the unreleased heading of
  `kiroku-store/CHANGELOG.md`; MasterPlan 13's release plan
  (`docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md`)
  assigns `kiroku-metrics` 0.3.0.0 and `kiroku-store` 0.11.0.0 for the whole cohort and moves
  IR-12 to `completed`.
  Rationale: Four sibling plans change the same two packages in the same window; one cohort
  release with one version set is what the keiro-ui initiative pins against, and publishing is
  irreversible and requires the user's explicit confirmation.
  Date: 2026-09-30

- Decision: No new ADR is planned. The distillation pass at the end decides whether the
  conformance mapping needs a record beyond the user guide.
  Rationale: ADR-9 §1 names `docs/user/metrics.md` as the normative inventory of the published
  surface and fixes the rule for how it may grow; a conformance table is an application of that
  rule, and the drop counter is a library detail rather than a boundary decision.
  Date: 2026-09-30


## Outcomes & Retrospective

2026-10-11: Complete locally. Publisher DropOldest loss is observable through
`subscribePublisherWith` without changing the legacy wrapper or ordinary delivery
branch. WebSocket tails send the loss notice before survivors, share a bounded
4096-name FIFO across replay/live/category delivery, preserve typed decode failures,
and provide four sanitized error codes. Metrics stop/resume and both channels'
workers have masked registration and joined cleanup. The original WebSocketSpec,
frozen encoder and path dispatch are unchanged.

All 654 examples (448 store, 98 metrics, 22 CLI, 17 OTel, 24 migrations, 45 adapter),
the ten-step self-checking example, both Nix package builds, formatting and bundle
validation pass. Nix builds disable tests; the runtime evidence comes from Cabal.
New implementation/test/harness code builds without new warnings; unrelated
pre-existing warnings appear in retained broader logs. The prescribed benchmark
needed migration setup; two existing backpressure fixtures needed Live barriers
because their blocked handlers could run during catch-up. Every original
behavioral assertion remains. Failed logs are retained rather than hidden.

[Local evidence](../../kiroku-metrics/bench/results/mp13-ep5-websocket-convergence/README.md)
records five-round publisher and faithful frozen-tail checks, lookup counts, retained cache sizes,
serialization/append timings and exact visibility of 7,500 concurrent appends.
The first timing runs overlapped Nix; their adverse samples are retained as
confounded, with an isolated follow-up and one bounded original-publisher/control-counter pair to investigate the remaining adverse row. Local timings are descriptive, not a
statistical zero-slowdown verdict. Plan 96 must still assess cumulative original-control
PG18 appends with real HTTP/tail/inventory observers and the retained index cost.
IR-12 stays in_progress, changelogs stay Unreleased, and no package is published.

ADR distillation: no new record. ADR-9 already makes the guide normative, and
ADR-15 already fixes bounded lookup/cache, typed failures, exact loss ordering
and shared-resource acceptance. The conformance table applies those decisions;
push-on-connect, full metrics snapshots and event-stream acknowledgement remain
explicit frozen-dialect deviations. Provenance is recorded once for this session.


## Context and Orientation

### Review baseline and acceptance boundaries (2026-10-10)

This plan is reviewed against `f1a0209`. Hackage preferred-version JSON and upstream tags
both identify `kiroku-store-0.10.0.0` and `kiroku-metrics-0.2.0.0` as already released.
The inspection forecast is now store 0.11.0.0 / metrics 0.3.0.0, not a reservation;
plan 96 must re-query releases and compute every dependent's version from its actual diff.
September source-version observations are historical, not current API authority.

[ADR-15](../adr/0015-inspection-observers-preserve-wire-contracts-and-bound-shared-work.md)
requires compatibility and bounded shared work. [ADR-12](../adr/0012-decode-failures-are-per-event-outcomes-with-independent-subscription-dispositions.md)
requires typed decode failures and the no-hook fast path. Re-read the named implementation
before coding: public reads use `decodeReadEvents`; publisher queues carry `DecodedBatch`,
not `Vector RecordedEvent`. Successful hooks return `Right`; a typed failure must never
turn into partial successful data. New HTTP store failures use sanitized messages:
`ConnectionError` gives 503 with the route's unavailable code, `EventDecodeFailed` gives
500 `event_decode_failed`, and other store errors give 500 `store_error`.
Never expose `show err`, connection strings or payloads; never catch asynchronous cancellation
as an expected store failure. Existing published error bodies remain unchanged.

All new read paths support GET and HEAD, returning identical status and headers with no HEAD
body. Other methods give 405 `method_not_allowed` and `Allow: GET, HEAD`. Implement this
in the WAI apps themselves, not only by relying on Warp. Query numbers are parsed from ASCII
digits into `Integer`, range-checked, and only then narrowed; reject signed/empty/overflowing
values and duplicate recognized parameters with 400 `invalid_query_parameter`.
Decode UTF-8 totally. Ignore unknown parameters as documented. Limits cap the page before
over-fetching one row, and integer narrowing must not wrap. Clients handling Int64 JSON fields
must use lossless integer parsing rather than silently rounding positions above 2^53.

No new append SQL, index, lock, checkpoint write, pool checkout, or per-event publisher work
is justified by a read-only label. New DB reads contend for shared resources. Use existing
correctness tests, structural invariants and a focused affected-path check per child.
Plan 96 owns the cumulative original-control comparison on PostgreSQL 18; the existing
pipeline-versus-sequential ratio and historical Shibuya catch-up results do not prove this
cohort neutral. Before any remote run, report cases, trial count, warmup, measurement and
setup/recovery time, uncertainty target and stopping conditions within a single 60-minute
ceiling. Preserve samples and lease cleanup; do not silently weaken a gate, repeat until
favorable, or expand to a full matrix. Reproducible append regressions block acceptance;
unmeasured or noisy evidence is explicitly pending or inconclusive.

### Terms used in this plan

A **WebSocket** is a long-lived two-way connection that starts as an HTTP request carrying
`Upgrade: websocket` and then exchanges **frames** in both directions on the same socket. In
`kiroku-metrics` every frame is a JSON object with a required `type` key naming the frame kind.
A **client frame** goes from the browser to the server; a **server frame** goes the other way.
An **event tail** is a server-side loop that forwards every newly appended event to one
connection. The **global position** is the monotonically increasing sequence number of an event
in the store-wide `$all` log; **replay** means paging history from a chosen global position before
switching to live delivery. A **fan-in read** is any read that returns events from many streams;
such events carry only the surrogate integer `originalStreamId`, never a stream name (ADR-1).
The **publisher** (`EventPublisher`) is the one thread per `KirokuStore` that reads newly
appended events and pushes them, as batches (`Vector RecordedEvent`), into one bounded STM queue
per registered subscriber; the WebSocket tail is one such subscriber. **Drop-oldest** is the
overflow policy the tail uses: when a subscriber's queue is full the publisher discards the oldest
queued batch to make room for the newest. A **WAI `Application`** is the standard Haskell value a
web server such as Warp runs; `kiroku-metrics` composes its HTTP router and its WebSocket handler
into one with `websocketsOr`. **PVP** is the Haskell Package Versioning Policy: a change to an
exported datatype's definition is a major bump; an addition is a minor bump.

### The WebSocket surface as it exists

Everything below is under `kiroku-metrics/`, version 0.2.0.0 at the 2026-10-10 review. The
package's `common` stanza enables `DuplicateRecordFields`, `OverloadedRecordDot`,
`OverloadedStrings`, `RecordWildCards`, `LambdaCase`, `DerivingStrategies`, and `DeriveAnyClass`,
and builds with `-Wall -Werror=incomplete-patterns`. The library depends on `aeson`, `async`,
`base`, `bytestring`, `containers`, `hasql`, `hasql-pool`, `http-types`, `kiroku-cli`,
`kiroku-store`, `stm`, `text`, `time`, `uuid`, `vector`, `wai`, `wai-websockets`, `warp`, and
`websockets`; nothing this plan needs is missing.

`src/Kiroku/Metrics/WebSocket.hs` owns the protocol and the handlers. Its export list is
`ClientMessage (..)`, `ServerMessage (..)`, `recordedEventToJSON`, `WebSocketState (..)`,
`newWebSocketState`, and `websocketApp`. The protocol types are:

```haskell
data ClientMessage
    = Ping
    | SubscribeMetrics
    | SubscribeEvents !(Maybe Int64) !(Maybe Text)   -- from_position, category
    | UnsubscribeEvents
    deriving stock (Eq, Show)

data ServerMessage
    = Pong
    | Snapshot !MetricsSnapshot
    | Event !Value
    | EventStreamStarted !Int64
    | Goodbye
    | ErrorMsg !Text
    deriving stock (Eq, Show)
```

`FromJSON ClientMessage` dispatches on the `type` string (`ping`, `subscribe_metrics`,
`subscribe_events` with optional `from_position` and `category`, `unsubscribe_events`) and
`fail`s on any other type; `recvMsg` turns a failed decode into `Nothing`, and both receive
loops ignore `Nothing`, which is how the server ignores unknown client frames. `ToJSON
ServerMessage` produces `{"type":"pong"}`, `{"type":"snapshot","metrics":…}`,
`{"type":"event","event":…}`, `{"type":"event_stream_started","from_position":N}`,
`{"type":"goodbye"}`, and `{"type":"error","message":"…"}`.

`recordedEventToJSON :: RecordedEvent -> Value` builds the event object with eleven camelCase
keys: `eventId`, `eventType`, `streamVersion`, `globalPosition`, `originalStreamId` (an integer
surrogate), `originalVersion`, `payload`, `metadata`, `causationId`, `correlationId`,
`createdAt`. That casing is frozen by ADR-9; a key added later must be snake_case.

`websocketApp cfg m store st` dispatches on `WS.requestPath (WS.pendingRequest pending)` through
`dispatchPath`, which strips a query string and matches exactly `/ws/metrics` or `/ws/events`,
rejecting anything else; it also enforces the `wsMaxConnections` bound through `WebSocketState`.

`handleMetrics cfg m pending` accepts the connection, wraps the body in
`WS.withPingThread conn 30 (pure ())` (a WebSocket-level ping every 30 seconds), sends one
`Snapshot`, starts `metricsPushLoop` in an `async` (linked with `link` so a crash propagates),
and runs `metricsReceiveLoop`, which answers `Ping` with `Pong` and `SubscribeMetrics` with a
fresh `Snapshot`. `finally` cancels the push thread and sends `Goodbye`. There is no way to stop
the periodic push short of disconnecting.

`handleEvents cfg store pending` accepts, wraps in the same ping thread, and keeps a
`TVar (Maybe (Async ()))` for the current tail: `SubscribeEvents from cat` stops any running tail
and starts `eventTail`, `UnsubscribeEvents` stops it, `Ping` answers `Pong`; `finally` stops the
tail and sends `Goodbye`. `eventTail` has three shapes. With a category it sends
`EventStreamStarted start` and runs `categoryLoop`, a database-driven loop over `readCategory`
gated on the publisher position (no broadcast queue is involved, so it can never overflow). Without
a category it subscribes to the publisher with
`subscribePublisher store.publisher cfg.wsEventQueueCap DropOldest`, reads the attach position,
sends `EventStreamStarted`, optionally replays history with `replayHistory` (paging
`readAllForward` up to the attach position and returning the highest covered position, or
`Nothing` after sending `ErrorMsg "replay error: …"`), and then runs `broadcastLoop conn queue
statusVar keep`, which forever reads a batch from the queue, sends the kept events, and, if the
status `TVar` reads `Overflowed`, sends `ErrorMsg "event stream overflowed; some events dropped"`.
`sendEvents` maps `recordedEventToJSON` over a batch and sends one `Event` frame per event.
`categoryLoop` sends `ErrorMsg "category read error: …"` and stops on a read failure.

The four current error sites gain replay_failed, category_read_failed,
event_stream_overflowed and live_decode_failed respectively. The live path resolves
DecodedBatch and terminates on an applicable typed decode failure; preserve that behavior
while adding its code and sanitizing the human-readable detail.

### Why the overflow frame never fires today

`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` exports `EventPublisher (..)`,
`Subscriber (..)`, `SubscriberStatus (..)`, `startPublisher`, `stopPublisher`,
`subscribePublisher`, and `publisherPosition`. The registered subscriber is:

```haskell
data Subscriber = Subscriber
    { subQueue :: !(TBQueue DecodedBatch)
    , subStatus :: !(TVar SubscriberStatus)
    , subPolicy :: !OverflowPolicy
    }

data SubscriberStatus = Active | Paused | Overflowed
```

and `subscribePublisher :: EventPublisher -> Natural -> OverflowPolicy -> STM (TBQueue DecodedBatch, TVar SubscriberStatus, IO ())` creates one, registers it in
`subscribers :: TVar (IntMap Subscriber)` under a fresh id, and returns the queue, the status
variable, and an `unsubscribe` action. The publisher loop delivers each batch to every
subscriber through `deliverBatchSTM`:

```haskell
    deliverBatchSTM events sub = do
        full <- isFullTBQueue (subQueue sub)
        if not full
            then do
                status <- readTVar (subStatus sub)
                case status of
                    Paused -> writeTVar (subStatus sub) Active
                    Active -> pure ()
                    Overflowed -> pure ()
                writeTBQueue (subQueue sub) events
            else case subPolicy sub of
                PauseAndResume -> writeTVar (subStatus sub) Paused
                DropSubscription -> writeTVar (subStatus sub) Overflowed
                DropOldest -> do
                    _ <- tryReadTBQueue (subQueue sub)
                    writeTBQueue (subQueue sub) events
```

`Overflowed` is written only under `DropSubscription`. The WebSocket subscribes with
`DropOldest`, so its status never leaves `Active`, and the `broadcastLoop` check can never fire.
The other caller of `subscribePublisher` is the subscription worker
(`kiroku-store/src/Kiroku/Store/Subscription.hs`, around line 138), which uses the policy the
subscription configured; it must keep working unchanged, which is why `subscribePublisher` stays
as a wrapper.

The publisher loop is a measured path under
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md): MasterPlan 12 assigns
`cabal bench kiroku-store:kiroku-shibuya-overhead` to plans that touch it, and its
bare-subscribe layer is exactly the publisher-fed `$all` path. This plan touches only the
already-full branch, but it runs the benchmark before and after so the claim is evidence, not
assertion.

### The library reads the tail will use

`kiroku-store/src/Kiroku/Store/Read.hs` exports
`lookupStreamNames :: (HasCallStack, Store :> es) => [StreamId] -> Eff es (Map StreamId StreamName)`,
which resolves a batch of surrogate ids in one round trip and short-circuits an empty list without
touching the database. `StreamId` is a newtype over `Int64`, `StreamName` over `Text`, both in
`kiroku-store/src/Kiroku/Store/Types.hs`, both with `Ord` instances (so they key a `Map`). The
WebSocket module already runs effect programs with `runStoreIO store (…)`, which returns
`IO (Either StoreError a)`.

### Tests and how they boot a server

`kiroku-metrics/test/Main.hs` wraps `hspec` in `withSharedMigratedPostgres` and lists
`CollectorSpec`, `IntegrationSpec`, `ServerSpec`, `WebSocketSpec`, and `SubscriptionsSpec`; the
cabal `test-suite` stanza lists the same modules under `other-modules` and depends on `aeson`,
`async`, `containers`, `generic-lens`, `hasql`, `hasql-pool`, `hspec`, `http-client`,
`http-types`, `kiroku-cli`, `kiroku-metrics`, `kiroku-store`, `kiroku-test-support`, `lens`,
`scientific`, `stm`, `text`, `uuid`, `warp`, and `websockets`.

`kiroku-metrics/test/Test/WebSocketSpec.hs` is the pattern to copy. Each example runs inside
`withMigratedTestDatabase $ \connStr -> …`, builds the collector with
`newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)` over a
`TVar (Maybe KirokuStore)`, opens the store with the metrics handlers installed on
`defaultConnectionSettings connStr` (`& #eventHandler .~ Just (metricsEventHandler km Nothing)`),
starts `startMetricsServerWithStore (defaultConfig{port = 0}) km store []`, sleeps
`threadDelay 300_000`, and drives the socket with `WS.runClient "127.0.0.1" port "/ws/events"`
inside `timeout 15_000_000`. Its private helpers, which the new spec copies rather than imports,
are `sendJSON`, `recvValue`, `waitForType conn "event"`, `readEventType`, `readEventPosition`,
`look`, `globalPositionOf`, `readPosition`, `readSubscribers`, `waitForSubscriberCount`,
`waitForPublisherPosition`, `appendStoreEvents store stream n` (appends `n` events of type
`E1`..`En` with `NoStream`), and `requireJust`. Its fourth example shows how to force a replay
failure deterministically: `Pool.use store.pool (Session.script "ALTER TABLE events RENAME TO
events_hidden")` before the client subscribes with `from_position`.

The store suite lives in `kiroku-store/test/`; `Test/Helpers.hs` exports `withTestStore` (a
bracket that opens a `KirokuStore` on a fresh migrated database), `makeEvent`, `waitForPublisher`,
and `waitWithTimeout`; `kiroku-store/test/Main.hs` and the `kiroku-store-test` stanza register
each spec module. `Test/PublisherIdleAdvance.hs` and `Test/PublisherRestartNoRebroadcast.hs` are
existing publisher-level specs.

### Documentation and knowledge bundles touched

`docs/user/metrics.md` is the package user guide. Its "The WebSocket protocol" section has the
two-path description, "Client → server" and "Server → client" tables, "The `RecordedEvent` wire
shape" table, "Semantics", and a `websocat` transcript; "Wire-format stability" cites ADR-9. This
plan edits only the WebSocket section and the "See Also" list.

`docs/capabilities/operational-http-endpoints.md` is capability `CAP-17` in the profile-governed
`capabilities` OKF bundle (validated by `just capabilities-validate`); its `description`,
`evidence`, and body must mention the converged protocol, and `docs/capabilities/log.md` receives
a dated `**Update**` entry. Do not change `generated.at`, `since`, or `capabilityId`.

`docs/improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md`
is IR-12 in the `improvement-requests` OKF bundle governed by
`mori/improvement-requests-profile.dhall`. MasterPlan 13 moved it to `accepted` with its Status
section citing this plan. Every status change advances `timestamp`, adds a dated entry to
`docs/improvement-requests/log.md`, and passes the strict validation in Concrete Steps (the
validator prints "missing profile-recommended field: reviews" lines for machine-authored
requests; those are advisory and pre-existing).

### Coordinating with the sibling plans of MasterPlan 13

Plan 88 (`docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md`,
EP-3) owns the enriched event encoder `recordedEventToJSONResolved :: Map StreamId StreamName ->
RecordedEvent -> Value` in `Kiroku.Metrics.WebSocket`, which is `recordedEventToJSON` plus the
key `original_stream_name` (the resolved name as a JSON string, or `null`). Before Milestone 2,
run:

```bash
grep -n "recordedEventToJSONResolved" kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs
```

Plan 88 is a hard prerequisite. Verify its completed encoder and reuse it; if absent,
do not start this plan by creating a second owner. Plan 87 owns lifecycle/mount changes
in Server.hs and plan 90 owns CORS; coordinate shared docs and tests without weakening
their gates.

The two changelogs are shared. `kiroku-metrics/CHANGELOG.md` has (or will have, from whichever
sibling lands first) a `## Unreleased` section; add this plan's bullets there under
`### New Features`. `kiroku-store/CHANGELOG.md` has, from plans 88 or 89, an unreleased heading;
add this plan's bullets there under `### Breaking Changes` (the `Subscriber` field) and
`### New Features` (`subscribePublisherWith`); if neither sibling has landed, create the
`## Unreleased` heading yourself. Plan 96 dates and numbers both.

### Relevant architecture decisions

Local ADRs read for this plan (the others were scanned by heading and are not relevant):

- [ADR-9, Published HTTP and WebSocket wire shapes are frozen and served only by sister packages](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
  (`mori://shinzui/kiroku/okf/adrs/concepts/ADR-9`): the paths, the client and server frame
  inventories, the event object's eleven camelCase keys, and the documented delivery semantics
  (including the in-band overflow error) are published; a field is never removed or re-typed; a
  new optional field, a new frame type, and a new documented behaviour are additive; new keys are
  snake_case even on the camelCase event object; `error` message text is not a contract; servers
  ignore unknown client frames and clients must ignore unknown server frames and fields; a change
  to a published encoder updates the user guide in the same change and a new surface ships with a
  test that pins its key set. Every change in this plan is one of the additive kinds, and
  Milestone 2's spec pins the key sets.
- [ADR-1, Resolve stream names via lookup, not a RecordedEvent field](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md):
  `RecordedEvent` carries only `originalStreamId` because a name on every `$all` row cost about
  13%; `lookupStreamNames` is the intended batch resolution. The tail resolves names that way,
  cached per connection.
- [ADR-5, Three-tier performance regression gates](../adr/0005-three-tier-performance-regression-gates.md):
  structural checks and controlled workloads are authoritative. The publisher change is off the
  not-full delivery path; the overhead benchmark is run before and after as evidence.

Cross-repository decisions, cited by the canonical handles the keiro-ui bundle publishes:

- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`: the WebSocket convention is the structural
  superset both shipped dialects fit; shipped dialects are frozen and converge only additively.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`: push is a hint, poll is truth; a client that
  misses frames recovers by re-reading, which is what the overflow code tells it to do.
- The conventions document, `mori://shinzui/keiro-ui`,
  `docs/architecture/inspection-api-conventions.md` (artifact-level URI pending; on this machine
  `/Users/shinzui/Keikaku/bokuno/keiro-ui/docs/architecture/inspection-api-conventions.md`).
  Area 5 lists the ten elements the conformance mapping must cover: typed `type`-tagged frames;
  explicit subscribe and unsubscribe; `ping`/`pong`; `from_position` replay cursors where the
  domain has them; an initial `snapshot` after subscribe; incremental `update` or `event` frames;
  servers ping idle connections (30-second precedent); in-band `error` frames including overflow;
  `goodbye` before server-initiated close; bounded drop-oldest queues with overflow signalled
  in-band.
- `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`: keiro will mount this package's
  WAI application behind a path prefix, so nothing here may assume an absolute mount path.

`mori path` may report the keiro-ui handles as not found because registry observation lags fresh
commits (plans 69, 87, and 90 recorded the same); per repository policy the canonical URIs are
retained.

### The audit, settled

Against the ten convention elements, the shipped surface stands as follows; the conformance table
in Milestone 3 restates this for users.

Typed `type`-tagged frames: met on both paths. Explicit subscribe/unsubscribe: met on
`/ws/events` (`subscribe_events`/`unsubscribe_events`); a documented deviation on `/ws/metrics`
(push on connect, `subscribe_metrics` only requests a snapshot), additively closed by
`unsubscribe_metrics` and the restart semantics of `subscribe_metrics`. `ping`/`pong`: met on
both paths. Replay cursors: met (`from_position`). Initial `snapshot` after subscribe: met on
`/ws/metrics` (the connect snapshot, and one per `subscribe_metrics`); a documented deviation on
`/ws/events`, where `event_stream_started` plays the role. Incremental frames: met (`snapshot`
pushes on the metrics path, `event` on the events path). Server idle pings: met on both paths
(30 seconds, `withPingThread`); IR-12's suspicion to the contrary is corrected. In-band `error`
frames: met in shape, but the overflow instance is unreachable; additively closed by the drop
counter and the `event_stream_overflowed` code. `goodbye` before server-initiated close: met on
both paths. Bounded drop-oldest queues: met (`wsEventQueueCap`, `DropOldest`).


## Plan of Work

### Current API and performance obligations

Plan 88 is a hard dependency and the sole owner of recordedEventToJSONResolved; reuse it.
The released queue element is DecodedBatch. Import it from the actual Settings module and
update every signature and fixture without converting the shared queue back to vectors.
No-hook delivery retains one UnchangedBatch wrapper per shared batch and no per-event
wrapper or copy; hook-enabled TransformedBatch preserves Undecodable outcomes.
The drop counter adds one cell per subscription but no increment on successful nonfull
delivery. Do not claim this constructor addition source-compatible for all users.

In addition to the existing focused publisher check, compare actual tail delivery using
warm names and a bounded batch of distinct names. Record lookup count, retained cache size,
tail latency and append contention for the cumulative gate. The Shibuya catch-up benchmark
does not exercise the new WebSocket resolver; it cannot establish that enrichment is free.
Do not launch a broad remote experiment for this child.

### Milestone 1: count dropped batches in the publisher

Scope: make the overflow signal observable at the library level. At the end, `kiroku-store`
exposes a per-subscriber dropped-batch counter through an additive subscription function, the
existing function and the subscription worker are unchanged in behaviour, a deterministic store
test proves the counter, and the overhead benchmark shows the not-full path did not move. Nothing
in `kiroku-metrics` changes yet.

First move IR-12 from `accepted` to `in_progress`: in
`docs/improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md`
set `status: in_progress`, advance `timestamp` to the current UTC time, and under `## Status`
change the acceptance paragraph (which links this plan) to say implementation is under way. Add a
dated `**Implementation**` entry to `docs/improvement-requests/log.md` and run the strict bundle
validation from Concrete Steps.

In `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`:

Add `Data.Word (Word64)` to the imports and a fourth field to `Subscriber`, with Haddock:

```haskell
data Subscriber = Subscriber
    { subQueue :: !(TBQueue DecodedBatch)
    , subStatus :: !(TVar SubscriberStatus)
    , subPolicy :: !OverflowPolicy
    , subDropped :: !(TVar Word64)
    -- ^ Batches discarded from 'subQueue' under 'DropOldest' because the queue
    -- was full. Never reset; a consumer compares successive reads. Stays zero
    -- under the other policies.
    }
```

Define the record a caller receives and the new subscription function, keeping the old one as a
wrapper so `Kiroku.Store.Subscription` and any external caller compile and behave as before:

```haskell
-- | What 'subscribePublisherWith' hands back: the bounded queue the publisher
-- fills, the status the publisher writes, the dropped-batch counter it
-- increments under 'DropOldest', and the action that deregisters the
-- subscriber (idempotent).
data PublisherSubscription = PublisherSubscription
    { subscriptionQueue :: !(TBQueue DecodedBatch)
    , subscriptionStatus :: !(TVar SubscriberStatus)
    , subscriptionDropped :: !(TVar Word64)
    , unsubscribe :: !(IO ())
    }

subscribePublisherWith ::
    EventPublisher ->
    -- | Queue capacity (number of batches)
    Natural ->
    OverflowPolicy ->
    STM PublisherSubscription

-- | The original interface: the queue, the status, and the unsubscribe action.
-- Equivalent to 'subscribePublisherWith' with the counter discarded.
subscribePublisher ::
    EventPublisher -> Natural -> OverflowPolicy ->
    STM (TBQueue DecodedBatch, TVar SubscriberStatus, IO ())
subscribePublisher pub cap policy = do
    s <- subscribePublisherWith pub cap policy
    pure (subscriptionQueue s, subscriptionStatus s, unsubscribe s)
```

Move the body of today's `subscribePublisher` into `subscribePublisherWith`, adding
`dropped <- newTVar 0` and `subDropped = dropped` to the `Subscriber` it builds, and returning
the record. Export `PublisherSubscription (..)` and `subscribePublisherWith` from the module
(after `subscribePublisher` in the export list). In `deliverBatchSTM`, change only the
`DropOldest` branch:

```haskell
                DropOldest -> do
                    _ <- tryReadTBQueue (subQueue sub)
                    modifyTVar' (subDropped sub) (+ 1)
                    writeTBQueue (subQueue sub) events
```

The `not full` branch, `PauseAndResume`, and `DropSubscription` are not touched. Update the
module header's description of overflow handling (it currently says `DropOldest` "drops the
oldest batch"; add "and counts the drop in `subDropped`") and the `Subscriber` Haddock. Check
whether `Kiroku.Store` or `Kiroku.Store.Subscription` re-export `subscribePublisher` (at planning
time `Kiroku.Store.Subscription` imports it qualified as `Pub.subscribePublisher` and does not
re-export it, so nothing else changes); if a re-export exists, add the new names beside it.

Search the repository for any other construction of `Subscriber` or exhaustive pattern on it
(`grep -rn "Subscriber{" --include='*.hs' kiroku-store kiroku-metrics shibuya-kiroku-adapter
kiroku-otel kiroku-cli`); the constructor is built only inside `subscribePublisherWith`, and the
`-Wall -Werror=incomplete-patterns` build will report any exhaustive record pattern elsewhere.

**Store test.** Create `kiroku-store/test/Test/PublisherDropCounter.hs` with
`spec :: Spec`, `describe "publisher drop counter"`, using `withTestStore` from `Test.Helpers`.
One example with three assertions:

1. Subscribe with `atomically (subscribePublisherWith store.publisher 1 DropOldest)` (capacity
   one batch) and never read the queue. Append one event to stream `drop-a` and wait for the
   publisher position to reach 1 (`waitForPublisher` or an STM wait on `publisherPosition`), then
   append one event to stream `drop-b` and wait for position 2. Each append wakes the publisher
   through the notifier, so the two events arrive as two separate batches, and the second
   delivery finds the queue full. Wait (STM, with a `registerDelay` timeout of five seconds) until
   `readTVar (subscriptionDropped s)` is `1`; assert it, and assert `readTVar (subscriptionStatus s)`
   is still `Active`.
2. Drain the queue with `tryReadTBQueue`: exactly one batch is present and its single event's
   `globalPosition` is `GlobalPosition 2` (the newest batch survived; the oldest was dropped).
3. Subscribe a second subscriber with `subscribePublisher store.publisher 1 DropOldest` (the
   wrapper), repeat the two appends on fresh streams, and assert the wrapper's queue behaves as
   before (one batch present after the second append) so the compatibility path is exercised;
   then call both `unsubscribe` actions twice and assert `IntMap.size <$> readTVar (subscribers
   store.publisher)` returns to its starting value (idempotent deregistration, unchanged).

If the two events ever arrive in one batch (the publisher woke once for both), the test would see
a count of zero; avoid that by waiting for the publisher position between appends as described,
and if it still happens record the observation in Surprises & Discoveries and add a
`threadDelay 100_000` between the appends. Register the module in `kiroku-store/test/Main.hs`
and in the `other-modules` of the `kiroku-store-test` stanza in `kiroku-store/kiroku-store.cabal`.

**Changelog.** Under the unreleased heading of `kiroku-store/CHANGELOG.md` (create
`## Unreleased` if no sibling plan has), add under `### Breaking Changes`: "`Subscriber` gains a
`subDropped :: TVar Word64` field counting batches discarded under `DropOldest`; code that
constructs or exhaustively matches the record must add it." Under `### New Features`:
"`subscribePublisherWith` returns a `PublisherSubscription` record exposing the dropped-batch
counter; `subscribePublisher` is unchanged and remains the triple-returning form."

**Benchmark evidence.** Before editing, run
`cabal bench kiroku-store:kiroku-shibuya-overhead` and keep the output; after the edit run it
again and paste both bare-subscribe rows into Surprises & Discoveries. The not-full path is
untouched, so the rows should agree within noise; a movement beyond noise means the edit landed on
the wrong branch and must be revisited before Milestone 2.

Acceptance for Milestone 1: `cabal build all` is warning-free (the store, the metrics package,
and the adapter all compile against the widened record),
`cabal test kiroku-store-test --test-options='--match "publisher drop counter"'` passes, the
whole store suite is green, and the two benchmark transcripts are recorded.

### Milestone 2: the additive protocol changes in `kiroku-metrics`

Scope: implement the three additive changes in `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`
and prove them with a new spec while the existing spec stays untouched. At the end, a server
started by `startMetricsServerWithStore` honours `unsubscribe_metrics`, sends coded errors, sends
the overflow error when batches were dropped, and labels every tailed event with its stream name.

**Protocol types.** Add one constructor to each protocol type:

```haskell
data ClientMessage
    = Ping
    | SubscribeMetrics
    | SubscribeEvents !(Maybe Int64) !(Maybe Text)
    | UnsubscribeEvents
    | -- | (Metrics channel) stop the periodic snapshot push; @subscribe_metrics@ restarts it.
      UnsubscribeMetrics
    deriving stock (Eq, Show)

data ServerMessage
    = ...
    | ErrorMsg !Text
    | -- | A non-fatal error with a stable machine-readable @code@ beside the @message@.
      CodedError !Text !Text
    deriving stock (Eq, Show)
```

Extend `FromJSON ClientMessage` with `"unsubscribe_metrics" -> pure UnsubscribeMetrics` and
`ToJSON ServerMessage` with:

```haskell
    toJSON (CodedError code msg) =
        object ["type" .= ("error" :: Text), "code" .= code, "message" .= msg]
```

Every other `toJSON` equation is untouched. Define the four codes as named constants next to
the instance so the tests and the guide use one spelling:

```haskell
-- | @code@ values carried by 'CodedError' frames. Published once shipped (ADR-9).
errorCodeReplayFailed, errorCodeCategoryReadFailed, errorCodeEventStreamOverflowed, errorCodeLiveDecodeFailed :: Text
errorCodeReplayFailed = "replay_failed"
errorCodeCategoryReadFailed = "category_read_failed"
errorCodeEventStreamOverflowed = "event_stream_overflowed"
errorCodeLiveDecodeFailed = "live_decode_failed"
```

Export all four constants. Change replay, category, overflow and live-decode error sites.
Use fixed sanitized messages retaining the "replay error" and "category read error" phrases
required by existing assertions, but no Show-rendered database or decode details. Preserve
the terminal behavior of replay/category/live typed failures.

**Metrics channel lifecycle.** Track the single push worker so unsubscribe cancels and joins
it and subscribe resumes it after sending a fresh snapshot. Keep the immediate snapshot on
connect and existing ping behavior. Do not leave an async acquisition gap: install the
cleanup scope before the initial start, mask async creation/registration, restore the worker's
body to normal masking state, and register the handle before unmasking. Propagate unexpected
worker failure to the connection owner. Cancel and join on disconnect and every exception;
a best-effort goodbye must not prevent cleanup. Test repeated subscribe/unsubscribe creates
at most one worker and cancellation during startup leaves none. A naked async/link/writeTVar
sequence outside the cleanup scope is not acceptable.

**Resolved event encoder and the name cache.** Reuse plan 88's
`recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value`.
It adds only original_stream_name to recordedEventToJSON, as a string or null.
This plan changes its call sites, not its ownership or contract.

Use a per-tail bounded FIFO cache: a Map from StreamId to StreamName plus a Sequence
of inserted IDs. The capacity is 4096 names; no duplicate IDs in the sequence. Build distinct
wanted IDs with Set, subtract cached IDs, and issue at most one lookupStreamNames call for
that batch (none for empty input or all hits). Retain only successfully found names. Merge
the found names with hits for encoding this entire batch, then evict oldest entries until
both stored structures are within capacity. Do not encode using the evicted map: names found
for the current batch must still be present in the temporary result even if that batch
exceeds capacity. Discard that result after sending. Missing names stay null; typed lookup
errors use the existing fallback, while asynchronous cancellation propagates.

Allocate once for the active tail, thread it through replay, broadcast and category paths,
and discard on unsubscribe, resubscribe or disconnect. IDs are immutable identity; an evicted
name may be fetched again. No lifetime-once lookup promise or unbounded Map is made.
Do not run lookups in publisher STM or for all subscribers in the shared publisher.

**Overflow detection.** Atomically sample the counter with dequeue and notify before survivors:

```haskell
{- | Compare the dropped-batch counter with the value seen at the previous
check; when it grew, the frame to send. Exported so the decision is unit-testable
without forcing a real overflow.
-}
overflowNotice :: Word64 -> Word64 -> Maybe ServerMessage
overflowNotice previous current
    | current /= previous =
        Just $
            CodedError
                errorCodeEventStreamOverflowed
                ( "event stream overflowed; "
                    <> T.pack (show (current - previous))
                    <> " undelivered batch(es) dropped since the last notice; re-read from your last position"
                )
    | otherwise = Nothing
```

In the no-category tail use subscribePublisherWith and retain the current DecodedBatch
resolver from WebSocket.hs: UnchangedBatch filters original events without wrapper rebuilding;
TransformedBatch filters via decodedEventRecorded and fails on an applicable Undecodable.
Replace its existing live ErrorMsg with CodedError errorCodeLiveDecodeFailed, a fixed
sanitized message, and the same terminal behavior. Do not send raw failed events, partial
successful vectors or continue past the typed failure. Replay and category typed errors also
retain their current terminal behavior and gain the corresponding coded error.

For each delivery, atomically dequeue the batch and read both subscriptionStatus and
subscriptionDropped in the same STM transaction. Compare with the previous count, initially
zero. Send the overflow notice BEFORE resolving/sending that batch's surviving events.
Only then update the seen count and continue the loop. Retain the defensive Overflowed
status handling without emitting a duplicate notice for the same sampled drop.
Word64 subtraction is modulo 2^64; use inequality rather than greater-than so a single
wraparound still reports the correct delta. Test the wrap boundary.

A UI must retain its pre-notice last contiguous cursor, mark subsequent live events as hints,
and recover by re-reading from that saved cursor. A notice after the survivor batch lets a
client advance past the gap and is incorrect. The queue/counter snapshot ensures drops that
occur after dequeue are notified before the later batch they affect.

**Changelog.** In `kiroku-metrics/CHANGELOG.md` under `## Unreleased`, `### New Features`: the
`unsubscribe_metrics` client frame and the resume semantics of `subscribe_metrics`; the `code`
field on `error` frames with the four codes; the `original_stream_name` key on `event` frames;
and the now-delivered overflow notice (name the previous unreachability plainly, so a reader
understands why a client may start seeing a frame it never saw before). The encoder export belongs to plan 88's changelog; avoid duplicate bullets.

**Tests.** Create `kiroku-metrics/test/Test/WebSocketConvergenceSpec.hs`, register it in
`kiroku-metrics/test/Main.hs` (import and call `WebSocketConvergenceSpec.spec`) and in the
test-suite `other-modules`. Copy the private helpers from `WebSocketSpec.hs` (`sendJSON`,
`recvValue`, `waitForType`, `readEventType`, `look`, `readPosition`, `readSubscribers`,
`waitForPublisherPosition`, `appendStoreEvents`, `requireJust`) and add `readEventField conn key`
that reads until an `event` frame and returns `look ["event", key]`. Write:

Under `describe "Kiroku.Metrics.WebSocket (frames)"`, database-free:

1. Pre-existing server frames are byte-identical: assert `toJSON` of `Pong`, `Goodbye`,
   `EventStreamStarted 7`, `ErrorMsg "x"`, and `Event (object ["k" .= (1 :: Int)])` equals the
   literal `object`s `{"type":"pong"}`, `{"type":"goodbye"}`,
   `{"type":"event_stream_started","from_position":7}`, `{"type":"error","message":"x"}`, and
   `{"type":"event","event":{"k":1}}` (for `Snapshot`, assert `look ["type"]` is `"snapshot"`
   and `look ["metrics"]` is present, using a snapshot taken from a fresh `newKirokuMetrics`).
2. `toJSON (CodedError "replay_failed" "boom")` equals
   `{"type":"error","code":"replay_failed","message":"boom"}`, and the four constants spell
   `replay_failed`, `category_read_failed`, `event_stream_overflowed`, `live_decode_failed`.
3. `eitherDecode "{\"type\":\"unsubscribe_metrics\"}"` is `Right UnsubscribeMetrics`, and every
   previously accepted client frame still decodes to its constructor.
4. `recordedEventToJSONResolved` adds exactly one key: build a `RecordedEvent` by hand
   (`originalStreamId = StreamId 9`), assert the resolved object's key set is the eleven
   camelCase keys plus `original_stream_name`, that the value is `"orders-7"` when the map has
   `StreamId 9 ↦ StreamName "orders-7"`, and `Null` when the map is empty; assert that removing
   the key yields exactly `recordedEventToJSON` of the same event.
5. `overflowNotice 0 0` and `overflowNotice 3 3` are `Nothing`; `overflowNotice 0 2` is
   `Just (CodedError "event_stream_overflowed" msg)` with `"2"` in `msg`; `overflowNotice 2 5`
   mentions `"3"`.

Under `describe "Kiroku.Metrics.WebSocket (convergence, real server)"`, each booting a server as
`WebSocketSpec` does but with `serverCfg = defaultConfig{port = 0, wsPushIntervalUs = 200_000}`:

6. Unsubscribe stops the push and subscribe resumes it: connect to `/ws/metrics`, receive the
   connect `snapshot`, then receive one more (proves periodic push), send
   `{"type":"unsubscribe_metrics"}`, drain any frame that arrives within 300 ms (a push may be
   in flight), then assert `timeout 700_000 (WS.receiveData conn)` is `Nothing` (no snapshot in
   more than three intervals); send `{"type":"subscribe_metrics"}` and assert a `snapshot`
   arrives within one second and a second one within 700 ms (periodic push resumed); send
   `{"type":"ping"}` and assert `pong`.
7. `original_stream_name` on the live path: subscribe to `/ws/events` with no options, append
   two events to `conv-live-1` and one to `conv-live-2`, and assert the three `event` frames
   carry `original_stream_name` `"conv-live-1"`, `"conv-live-1"`, `"conv-live-2"` in that order.
8. `original_stream_name` on the replay and category paths: append two events to `convcat-1`
   before connecting; subscribe with `from_position` 0 and assert both replayed frames name
   `convcat-1`; then, on a new connection, subscribe with `category` `"convcat"`, append one
   event to `convcat-2`, and assert the frame names `convcat-2`.
9. `replay_failed` end to end: repeat the fourth `WebSocketSpec` example (rename `events`
   before subscribing with `from_position`) and assert the `error` frame's `code` is
   `replay_failed` and its `message` still contains `replay error`.
10. `category_read_failed` end to end: append a matching event and wait for the published
    position, then make the read fail before starting a fresh category subscription with
    from_position 0. Alternatively use an injected failing store-read runner in the production
    category loop. Assert the actual coded frame and termination. The fixture category is
    `convcat` for `convcat-1`, because categoryName splits at the first dash. Never append
    to a renamed events table or replace this test with grep if a timing race occurs.
11. Existing frames still flow: after all of the above, `waitForSubscriberCount store 0` holds
    (tails deregister), proving the drop-counter subscription's `unsubscribe` is wired into the
    `finally` as before.

Add a deterministic integrated delivery test with a gated frame writer passed to the
production broadcast helper. Stop its first send, publish enough independently observed
batches to overflow a capacity-one queue, then release the writer. Assert the actual captured
coded notice precedes the first survivor and that replay from the last pre-notice cursor
recovers every dropped event exactly once after deduplication. Separate counter and encoder
tests alone do not prove wiring/order. No socket-buffer timing assumption is needed.
Also test no notice on an unchanged counter, both DecodedBatch constructors, terminal typed
failure, a warm-cache batch with zero lookups, a cold batch with one lookup, and more than
4096 distinct IDs with bounded retained state and correct current-batch names.

Acceptance for Milestone 2: `cabal test kiroku-metrics-test` passes in full, with
`kiroku-metrics/test/Test/WebSocketSpec.hs` unchanged (`git diff --stat -- kiroku-metrics/test/Test/WebSocketSpec.hs`
prints nothing), and `nix fmt` is a no-op.

### Milestone 3: documentation, capability, request evidence, and distillation

Scope: make the converged protocol discoverable and give the keiro-ui client core the mapping it
is built against. At the end, a reader of `docs/user/metrics.md` can see every new frame with
example JSON and every convention element with its kiroku realisation, and every repository
validation passes.

In `docs/user/metrics.md`, inside "The WebSocket protocol":

- In "Client → server", add the row
  `{"type":"unsubscribe_metrics"}` | metrics | Stop the periodic snapshot push; `subscribe_metrics` resumes it.
  and extend the `subscribe_metrics` row: "Request a fresh snapshot now, and resume the periodic
  push if it was stopped."
- In "Server → client", replace the `error` row with
  `{"type":"error","code":"…","message":"…"}` | A non-fatal error. `code` is a stable machine-readable value (table below); `message` is human text and may change.
  and add a short "Error codes" table: `replay_failed` (history replay hit a store error; the tail
  ended, resubscribe), `category_read_failed` (a category page read failed; the tail ended,
  resubscribe), `event_stream_overflowed` (this client fell behind and the oldest undelivered
  batches were dropped; re-read from your last position through the REST browse API or
  resubscribe with `from_position`). Note that frames produced before this version carried no
  `code`.
- In "The `RecordedEvent` wire shape", add the row `original_stream_name` | string or `null` |
  The source stream's name, resolved server-side from `originalStreamId`; `null` if the stream
  cannot be resolved. Keep the note that the camelCase keys are frozen and that this key, being
  new, is snake_case; say that the same object is served by the REST browse endpoints.
- In "Semantics", extend the `DropOldest` bullet: the server counts dropped batches per
  connection and sends `error` with `code` `event_stream_overflowed` before the affected survivor
  batch; state that the signal is delivered from this version on (earlier versions documented it
  but never sent it), and that a category tail cannot overflow because it is read from the
  database rather than the broadcast.
- Add a subsection "Conformance with the cross-project WebSocket convention" with two
  sentences of framing (the keiro runtime UI initiative's convention, cited as
  `mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`, artifact-level
  URI pending, and `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`; kiroku's shipped dialect
  is frozen per ADR-9 and converges only additively) and one table with the columns
  Convention element | `/ws/metrics` | `/ws/events` | Status, covering: typed `type`-tagged
  frames (met, met); explicit subscribe/unsubscribe (`subscribe_metrics`/`unsubscribe_metrics`,
  additively closed, push-on-connect retained; `subscribe_events`/`unsubscribe_events`, met);
  `ping`/`pong` (met, met); replay cursor (not applicable; `from_position`, met); initial
  `snapshot` after subscribe (met, sent on connect and on `subscribe_metrics`; documented
  deviation, `event_stream_started` plays the role); incremental frames (`snapshot`, met;
  `event`, met); server idle pings (met, 30 s; met, 30 s); in-band `error` with overflow
  signalling (not applicable; met, `event_stream_overflowed`, additively closed); `goodbye`
  before server close (met, met); bounded drop-oldest queue (not applicable; met,
  `wsEventQueueCap`). Add a closing sentence that "additively closed" means an old client
  observes no change.
- Update the `websocat` transcript to show `original_stream_name` in the `event` line.
- In "See Also", add the conventions document and keiro-ui ADR-2 as cross-repository
  references.

Update `docs/capabilities/operational-http-endpoints.md` (CAP-17): extend `description` and the
body to say the WebSocket surface conforms to the cross-project inspection convention with an
explicit metrics-channel lifecycle, coded error frames, delivered overflow signalling, and
resolved stream names on tailed events; add an `evidence` entry for
`kiroku-metrics/test/Test/WebSocketConvergenceSpec.hs` and one for
`kiroku-store/test/Test/PublisherDropCounter.hs`; add a dated `**Update**: CAP-17 …` entry to
`docs/capabilities/log.md`. Run `just capabilities-validate`.

Update IR-12's body (status stays `in_progress`): add an "Implementation Evidence" section
listing the audit outcome per element, the three additive changes with their frames, the
corrected idle-ping finding, the overflow finding and its fix, the test files, and the guide
section; advance `timestamp`; add a log entry; validate.

Finalize the `## Unreleased` changelog bullets. Then perform the distillation pass: reread the
Decision Log and Surprises & Discoveries and decide whether anything is durable project context
beyond what ADR-9 already records. The expected outcome is no new ADR, because ADR-9 §1 makes the
guide the normative inventory and the conformance table is an application of its rules; if the
implementer concludes that the "documented deviation" category or the drop counter's semantics
deserve a record, allocate one with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`,
write it, add the bundle log entry, and run `just adr-validate`. Record the decision in Outcomes
& Retrospective either way, write the retrospective, and record the closing provenance revision
(`--mode implement`) on this plan.

Acceptance for Milestone 3: `nix fmt` is a no-op, `cabal build all` and `cabal test all` pass,
`nix build .#kiroku-metrics` and `nix build .#kiroku-store` succeed, `just capabilities-validate`
and the strict improvement-request validation pass, `git diff --check` is clean, and the guide's
conformance table lists all ten convention elements with a status for each path.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` inside the Nix dev
shell (`nix develop`, or the direnv-loaded shell from `.envrc`).

Baseline first:

```bash
git status --short --branch
cabal build all
cabal test kiroku-metrics-test
cabal bench kiroku-store:kiroku-shibuya-overhead
```

Expected: a clean tree on `master`, the metrics suite green, and a benchmark table whose
bare-subscribe rows you copy into this plan before editing anything. If the baseline fails, stop
and record it.

Milestone 1 edits and checks:

```bash
# edit docs/improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md  (status: in_progress, timestamp, Status paragraph)
# edit docs/improvement-requests/log.md                                                            (dated Implementation entry)
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
# edit kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs   (subDropped, PublisherSubscription, subscribePublisherWith, DropOldest branch)
# write kiroku-store/test/Test/PublisherDropCounter.hs
# edit kiroku-store/test/Main.hs                                       (+ PublisherDropCounter.spec)
# edit kiroku-store/kiroku-store.cabal                                 (+ test other-modules)
# edit kiroku-store/CHANGELOG.md                                       (unreleased bullets)
grep -rn "Subscriber{" --include='*.hs' kiroku-store kiroku-metrics shibuya-kiroku-adapter kiroku-otel kiroku-cli
nix fmt
cabal build all
cabal test kiroku-store-test --test-options='--match "publisher drop counter"'
cabal test kiroku-store-test
cabal bench kiroku-store:kiroku-shibuya-overhead
```

Expected tail of the focused run:

```text
publisher drop counter
  counts one dropped batch under DropOldest, keeps the newest batch, and leaves the wrapper unchanged [✔]

Finished in 2.1 seconds
1 example, 0 failures
```

Commit:

```text
feat(store): count batches dropped under DropOldest per publisher subscriber

Add subDropped to Subscriber, increment it on the DropOldest branch only,
and expose it through subscribePublisherWith; subscribePublisher is unchanged.

MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md
ExecPlan: docs/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md
Intention: intention_01m3t7a7jaeewbf71vqrzk4zd8
```

Milestone 2 edits and checks:

```bash
grep -n "recordedEventToJSONResolved" kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs   # verifies the hard prerequisite
# edit kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs   (UnsubscribeMetrics, CodedError, codes, handleMetrics, encoder, cache, overflowNotice, broadcastLoop)
# edit kiroku-metrics/CHANGELOG.md                       (## Unreleased / ### New Features)
# write kiroku-metrics/test/Test/WebSocketConvergenceSpec.hs
# edit kiroku-metrics/test/Main.hs                       (+ WebSocketConvergenceSpec.spec)
# edit kiroku-metrics/kiroku-metrics.cabal               (+ test other-modules)
nix fmt
cabal build kiroku-metrics
cabal test kiroku-metrics-test --test-options='--match "Kiroku.Metrics.WebSocket ("'
cabal test kiroku-metrics-test
git diff --stat -- kiroku-metrics/test/Test/WebSocketSpec.hs
```

Expected focused tail (the exact example titles are yours to word; the counts are the point):

```text
Kiroku.Metrics.WebSocket (frames)
  keeps every pre-existing server frame byte-identical [✔]
  encodes coded error frames and spells the four codes [✔]
  decodes unsubscribe_metrics and every existing client frame [✔]
  adds exactly original_stream_name to the resolved event object [✔]
  emits an overflow notice only when the drop counter grew [✔]
Kiroku.Metrics.WebSocket (convergence, real server)
  stops the periodic push on unsubscribe_metrics and resumes it on subscribe_metrics [✔]
  labels live-tail events with original_stream_name [✔]
  labels replayed and category-tail events with original_stream_name [✔]
  codes a replay failure as replay_failed [✔]
  codes a category read failure as category_read_failed [✔]
  deregisters every tail on disconnect [✔]
Kiroku.Metrics.WebSocket (endpoints)
  ... (the four pre-existing examples, unchanged) ...

15 examples, 0 failures
```

and an empty `git diff --stat` for the old spec. Commit as
`feat(kiroku-metrics): converge the WebSocket protocol additively with the inspection convention`
with the three trailers.

Milestone 3 edits and checks:

```bash
# edit docs/user/metrics.md                                   (WebSocket section, conformance table, See Also)
# edit docs/capabilities/operational-http-endpoints.md, docs/capabilities/log.md
# edit docs/improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md, docs/improvement-requests/log.md
# edit kiroku-metrics/CHANGELOG.md, kiroku-store/CHANGELOG.md   (final wording)
just capabilities-validate
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
nix fmt
cabal build all
cabal test all
nix build .#kiroku-metrics
nix build .#kiroku-store
git diff --check
```

Expected: every command exits zero (the improvement-request validator's "missing
profile-recommended field: reviews" lines are advisory). Commit as
`docs(kiroku-metrics): document the converged WebSocket protocol and its conformance mapping`
with the three trailers, then record the closing provenance revision:

```bash
bun agents/skills/exec-plan/record-provenance.ts revision \
  --plan docs/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md \
  --model <your-model-id> --harness claude-code --mode implement \
  --note "IR-12 implemented: drop counter, coded errors, unsubscribe_metrics, original_stream_name, conformance mapping"
```


## Validation and Acceptance

The reviewed API, lifecycle and performance obligations in Context and Plan of Work are
mandatory in addition to the route-specific cases below. Historical transcripts are examples,
not evidence that the new tests have run; update counts from actual output at implementation.

The plan is accepted when every item below is observed, mapped to IR-12's acceptance list:

1. A client written against the shipped protocol operates unchanged: `Test.WebSocketSpec` passes
   with no edits, and the frame-pinning example proves `toJSON` of every pre-existing server
   frame is byte-identical (IR-12 acceptance 1).
2. Every change is additive: `git diff` of `WebSocket.hs` shows new constructors, new functions,
   and edited handler bodies, but no removed or renamed constructor, no changed `toJSON`
   equation for an existing constructor, no change to `dispatchPath`, and no change to
   `recordedEventToJSON`'s key list (IR-12 acceptance 2).
3. The conformance mapping in `docs/user/metrics.md` lists all ten convention elements, each
   marked met, additively closed, or documented deviation, naming the kiroku frame(s)
   (IR-12 acceptance 3).
4. The new frames and fields use snake_case (`unsubscribe_metrics`, `code`,
   `original_stream_name`) and are documented with example JSON (IR-12 acceptance 4).
5. Against a running store-backed server: `unsubscribe_metrics` silences periodic snapshots and
   `subscribe_metrics` resumes them; every `event` frame on a live, replayed, and category tail
   carries the correct `original_stream_name`; a replay failure yields `code` `replay_failed`
   and a category read failure yields `code` `category_read_failed`.
6. At the library level, a `DropOldest` subscriber with capacity one that receives two batches
   without reading shows `subscriptionDropped` equal to one with status still `Active`, and
   `overflowNotice` turns that increase into the `event_stream_overflowed` frame.
7. The overhead benchmark's bare-subscribe rows before and after Milestone 1 agree within noise
   and are recorded in Surprises & Discoveries.
8. CAP-17, IR-12 (`in_progress` with evidence), both changelogs, and the guide are updated and
   every bundle validates; no version has been bumped and nothing has been published.


## Idempotence and Recovery

Every change is additive source code, tests, documentation, and changelog text; there is no
migration and no destructive operation. Re-running any build, test, benchmark, or validation
command is safe. Tests use a fresh migrated database per example and OS-assigned ports, so reruns
cannot collide. The `ALTER TABLE events RENAME` used to force read failures happens inside a
throwaway test database.

If `cabal build all` fails after Milestone 1 with an incomplete-patterns or missing-field error
in another package, that package constructs or exhaustively matches `Subscriber`; add the
`subDropped` field there and record it in Surprises & Discoveries. If the drop-counter test sees
a count of zero, the two appends were published as one batch; wait on the publisher position
between them as the milestone describes, and if needed add a short delay. If example 6 is flaky
on a loaded machine, lengthen the silent window and the resume timeouts proportionally
(the intervals are chosen at 200 ms so the test stays under two seconds; the ratios matter, not
the absolute values) and record the change.

If a milestone is interrupted, the tree still builds after each commit because each commit is
scoped to compile on its own (the store change before its metrics consumer). To roll back, revert
the milestone's commits in reverse order; nothing outside the repository observes the change until
plan 96 releases, which this plan does not do. IR-12 must stay `in_progress` until plan 96 has
release evidence; never set `completed` from a local build.


## Interfaces and Dependencies

At the end of Milestone 1, `kiroku-store` (`Kiroku.Store.Subscription.EventPublisher`) exposes:

```haskell
data Subscriber = Subscriber
    { subQueue :: !(TBQueue DecodedBatch)
    , subStatus :: !(TVar SubscriberStatus)
    , subPolicy :: !OverflowPolicy
    , subDropped :: !(TVar Word64)          -- new
    }

data PublisherSubscription = PublisherSubscription   -- new
    { subscriptionQueue :: !(TBQueue DecodedBatch)
    , subscriptionStatus :: !(TVar SubscriberStatus)
    , subscriptionDropped :: !(TVar Word64)
    , unsubscribe :: !(IO ())
    }

subscribePublisherWith :: EventPublisher -> Natural -> OverflowPolicy -> STM PublisherSubscription   -- new
subscribePublisher :: EventPublisher -> Natural -> OverflowPolicy
                   -> STM (TBQueue DecodedBatch, TVar SubscriberStatus, IO ())            -- unchanged
```

with the semantics that `subDropped` increments by one for each batch discarded under
`DropOldest` and never changes under `PauseAndResume` or `DropSubscription`. This is a PVP-major
change (record definition), absorbed by the cohort's `kiroku-store` 0.11.0.0 in plan 96.

At the end of Milestone 2, `kiroku-metrics` (`Kiroku.Metrics.WebSocket`) exposes, in addition to
today's exports:

```haskell
data ClientMessage = ... | UnsubscribeMetrics
data ServerMessage = ... | CodedError !Text !Text
errorCodeReplayFailed, errorCodeCategoryReadFailed, errorCodeEventStreamOverflowed, errorCodeLiveDecodeFailed :: Text
recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value   -- owned by prerequisite plan 88; reused here
overflowNotice :: Word64 -> Word64 -> Maybe ServerMessage
```

Wire contract owned by this plan (published once shipped, per ADR-9):

```json
{"type":"unsubscribe_metrics"}
{"type":"error","code":"replay_failed","message":"replay error: ..."}
{"type":"error","code":"category_read_failed","message":"category read error: ..."}
{"type":"error","code":"live_decode_failed","message":"live event decoding failed"}
{"type":"error","code":"event_stream_overflowed","message":"event stream overflowed; N undelivered batch(es) dropped ..."}
{"type":"event","event":{"eventId":"...","eventType":"...","streamVersion":1,"globalPosition":43,"originalStreamId":9,"originalVersion":1,"payload":{},"metadata":null,"causationId":null,"correlationId":null,"createdAt":"...","original_stream_name":"orders-7"}}
```

The `message` texts are not contract; the `code` values and the `original_stream_name` key are.

Dependencies: no new library dependency in either package. `Data.Word`, `Data.Map.Strict`,
`Data.Set`, `Data.Sequence`, and `Data.Aeson.KeyMap` come from `base`, `containers`, and `aeson`, all already
present. The only runtime service is PostgreSQL with the existing Kiroku migrations. Locate
dependency sources through `mori registry show <project> --full` (for example `haskell/aeson`,
`haskell/stm`, `haskell/containers`) when behaviour is uncertain; for `websockets`, which is not in
the corpus, unpack the exact version from `dist-newstyle/cache/plan.json` out of
`~/.cabal/packages`; do not inspect `/nix/store`.

Dependency direction is unchanged: `kiroku-metrics` depends on `kiroku-cli` and `kiroku-store`;
nothing depends on `kiroku-metrics`. Sibling plans this plan coordinates with, by path: plan 88
(`docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md`) for the
shared encoder, and plan 96
(`docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md`) for
the release that completes IR-12.


## API and performance review revision (2026-10-10)

Reviewed against repository HEAD `f1a0209` and the released typed-decoding implementation. Corrected integration contracts and made focused performance evidence a completion gate. Existing authorship history is preserved; this revision records no implemented milestone or accepted performance result. The active requirements above supersede incompatible September design decisions, not published wire contracts.

Revision (2026-10-11): implemented all three milestones, retained local evidence and fixture failures, documented the ten-element mapping, and kept cumulative performance/publication pending with plan 96.
