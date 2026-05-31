---
id: 44
slug: opentelemetry-tracing-of-subscription-worker-state-and-span-attributes-end-to-end-through-the-shibuya-adapter
title: "OpenTelemetry tracing of subscription-worker state and span attributes end to end through the Shibuya adapter"
kind: exec-plan
created_at: 2026-05-30T15:28:11Z
intention: "intention_01kstnhravebaryq7x3e50z6pz"
master_plan: "docs/masterplans/6-subscription-worker-fsm-and-end-to-end-shibuya-integration.md"
---

# OpenTelemetry tracing of subscription-worker state and span attributes end to end through the Shibuya adapter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. A *subscription* is a long-lived worker that reads events in order and feeds them to a handler, remembering its progress in a durable *checkpoint*. MasterPlan 6 (`docs/masterplans/6-subscription-worker-fsm-and-end-to-end-shibuya-integration.md`) gave the subscription worker an explicit finite state machine (FSM): at any instant the worker is in exactly one named *state* — `CatchingUp`, `Live`, `Paused`, `Reconnecting`, `Retrying`, or `Stopped` (defined in `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`). The worker already announces every transition as a structured *operational event* of type `KirokuEvent` (defined in `kiroku-store/src/Kiroku/Store/Observability.hs`), delivered synchronously to an optional callback an operator installs (`eventHandler :: Maybe (KirokuEvent -> IO ())`).

What is missing is **OpenTelemetry tracing**. "OpenTelemetry" (OTel) is a vendor-neutral standard for emitting telemetry; its core tracing concept is the *span* — one timed operation with a name, a start and end time, key/value *attributes* (tags such as `kiroku.subscription.name = "orders"`), and timestamped *span events* (notes inside the span). Spans form a tree (a *trace*) and are viewed as horizontal bars on a timeline in tools like Jaeger or Honeycomb. Today nothing in Kiroku turns the subscription's state changes into spans. The only OTel code that exists is `kiroku-otel`'s `Kiroku.Otel.TraceContext` module, which merely **propagates** W3C trace-context headers in and out of an event's `metadata` JSONB column; it does **not** create spans and it does **not** observe `KirokuEvent`.

After this change, an operator who opts into `kiroku-otel` can install a ready-made `KirokuEvent` handler that turns subscription state into spans. On a trace timeline they will see a subscription catch up, go live, pause under backpressure, reconnect after a database outage, retry a poison event, and dead-letter it — each span tagged with the subscription name, its target (the `$all` stream or a category), the consumer-group member, the checkpoint position, the attempt counter, and batch sizes. Those same identifying attributes will also ride through the Shibuya adapter (`shibuya-kiroku-adapter`) onto Shibuya's own per-message spans, so a single trace can be followed from a Kiroku subscription all the way into Shibuya's processing — the "end-to-end" promised by the MasterPlan's title.

You can see it working by running the new `kiroku-otel` test suite, which feeds synthetic `KirokuEvent` sequences through the handler into an **in-memory span exporter** and asserts on the spans that come out (their names, attributes, and that each transient-state span actually ends). And by running the `shibuya-kiroku-adapter` test that asserts the produced Shibuya `Envelope` now carries the kiroku identity attributes.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 — `kiroku-otel`: new `Kiroku.Otel.Subscription` module turning `KirokuEvent` into spans (episode + per-batch model, attribute set); unit tests against the in-memory exporter. Add `hs-opentelemetry-sdk` + in-memory exporter as **test** dependencies. (Done 2026-05-30: `subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())` with an `MVar`-keyed open-span model; `kiroku-otel-test` **13 examples, 0 failures** — catchup/fetch, pause/resume, reconnect-with-attempt-event, retry→dead-letter, immediate dead-letter, consumer-group isolation, no-leak-on-stop. SDK + in-memory exporter pinned from the same git tag as the api — see Surprises.)
  - [x] M1 follow-up (2026-05-31): the internal `OpenState` open-span record violated the project record-pattern convention (`haskell-jitsurei/core/record-patterns.md`) on two counts — its fields carried the type-name `os` prefix (`osCatchup`/`osReconnect`/`osPause`/`osRetries`), which "No Field Prefixes" forbids, and it had no deriving clause. Renamed the fields to `catchup`/`reconnect`/`pause`/`retries` (prefix-free, relying on `DuplicateRecordFields`) and added `deriving stock (Generic)` plus the `GHC.Generics (Generic)` import. Fields were already strict. `cabal test kiroku-otel` still **13 examples, 0 failures**.
- [x] M2 — `shibuya-kiroku-adapter`: populate `Envelope.attributes` with kiroku identity (subscription name, consumer-group member, event type, global position), threaded from the adapter config; adapter test asserts the attributes are present. (Done 2026-05-30: added `KirokuEnvelopeAttrs {subscriptionName, member}` in `Convert.hs`; `toEnvelope`/`toIngestedAck` take it and build a `kiroku.*` attribute map; `kirokuAdapter` derives the name + member from `subName`/`cg` so both the single and consumer-group paths are covered automatically. `hs-opentelemetry-api` added to the adapter library + test. `shibuya-kiroku-adapter-test` **20 examples, 0 failures** incl. two new attribute assertions — non-grouped omits the member key, grouped carries `kiroku.consumer_group.member`. No `shibuya-core` change.)
  - [x] M2 follow-up (2026-05-31): `KirokuEnvelopeAttrs` was introduced without a deriving clause, violating the project record-pattern convention (`haskell-jitsurei/core/record-patterns.md` → "Explicit Deriving Strategies": every record derives via an explicit `deriving stock` strategy, and field names carry **no** type-name prefix). Added `deriving stock (Generic, Eq, Show)` and the `GHC.Generics (Generic)` import; the record's fields (`subscriptionName`, `member`) were already prefix-free and strict, matching the doc and the sibling `KirokuAdapterConfig`/`KirokuConsumerGroupConfig` records. The siblings derive only `Generic` because their `selector :: Maybe (RecordedEvent -> Bool)` field blocks `Eq`/`Show`; `KirokuEnvelopeAttrs` has no function field, so it takes the full `(Generic, Eq, Show)` the doc prescribes. `cabal build shibuya-kiroku-adapter` compiles clean (library + test suite).
- [x] M3 — docs, CHANGELOGs, an end-to-end example/test, and correct MasterPlan 6's inaccurate "`kiroku-otel` already adapts `KirokuEvent`" statement. (Done 2026-05-30: module Haddock covers the span model, export-on-end limitation, and batch-processor requirement; `docs/user/opentelemetry.md` gains a "Tracing Subscription State" section with the span table, attribute keys, and the end-to-end Shibuya path; `docs/user/observability.md` and `docs/user/shibuya-adapter.md` cross-link it. CHANGELOGs updated for both packages. End-to-end demonstration is M1's synthetic in-memory-exporter coverage + M2's adapter attribute test + documented wiring rather than a DB-backed `kiroku-otel` test — see Decision Log. MasterPlan 6's Vision & Scope already quotes and refutes the inaccurate "already adapts `KirokuEvent`" claim (corrected when EP-5 was added).)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **A span is only exported when it ends — verified against `hs-opentelemetry` source.** This is the single most important constraint shaping the design, so it is recorded here up front. In `hs-opentelemetry-api`, `endSpan` (in `OpenTelemetry/Trace/Core.hs`, ~line 990) is what sets the end timestamp and then calls `tracerProviderOnEnd ... imm` (line 1018), which fans out to each processor's `spanProcessorOnEnd` (lines 1225–1226). The `SpanProcessor` record (in `OpenTelemetry/Internal/Trace/Types.hs:117`) has both `spanProcessorOnStart` and `spanProcessorOnEnd`, but the batch/OTLP exporters export from `onEnd`; there is **no partial/snapshot export** of an in-flight span. Consequence: a single span held open for the worker's whole lifetime would be **invisible** in the backend until the worker stops, and would be **lost entirely on a crash**. Therefore this plan does **not** model the worker lifetime as one span; it uses short, promptly-ending spans (see Plan of Work). Source read at `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project` via `mori`.

- **`kiroku-otel` does not currently "adapt `KirokuEvent`".** MasterPlan 6 (line 39, as written before this plan) states "the `kiroku-otel` package already adapts `KirokuEvent` and will pick up new constructors without core changes." That is inaccurate: `kiroku-otel` contains only `Kiroku.Otel.TraceContext` (W3C header propagation). There is no `KirokuEvent`→OTel bridge anywhere. This plan creates it. (M3 corrects the MasterPlan sentence.)

- **The project resolves `hs-opentelemetry-api` 0.3.0.0 (git-pinned), not 0.4 — the API differs (M1, 2026-05-30).** The `mori`-registered checkout at `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project` is on the 0.4 branch (commit `b98ef86`, version `0.4.0.0`), but `cabal.project` pins `hs-opentelemetry-api` from GitHub at tag `adc464b0a45e56a983fa1441be6e432b50c29e0e`, which is **0.3.0.0** (confirmed in `dist-newstyle/cache/plan.json` and the unpacked source under `dist-newstyle/src/hs-opente_*/api`). The 0.4 `newEvent`/`newEventWith` helpers (`@since 0.4.1.0`) do **not** exist in 0.3.0.0, so the module constructs `NewEvent {..}` records directly via `addEvent`. Read the real 0.3.0.0 source for the exact signatures rather than the `mori` checkout.
- **`addAttributes` is a left-biased union; updating an attribute requires the singular `addAttribute` (M1).** `OpenTelemetry.Attributes.addAttributes` does `H.union existing new`, so the existing value wins and a re-set is silently dropped — fatal for refreshing a checkpoint or attempt counter on an open span. The module therefore sets all attributes through a `setAttrs` helper built on the singular `addAttribute` (an `insert`, which overrides). Evidence: `OpenTelemetry/Attributes.hs` `addAttributes` (`H.union attributeMap ...`) vs `addAttribute` (`H.insert k ...`).
- **`hs-opentelemetry-sdk` + `hs-opentelemetry-exporter-in-memory` are pinned from the same git tag as the api (M1).** Because the api is a git `source-repository-package` at a specific commit (for GHC 9.12 support), the SDK and in-memory exporter must come from the **same** tag so they link against the matching 0.3.0.0 internal modules. Two `source-repository-package` stanzas (subdirs `sdk` and `exporters/in-memory`, tag `adc464b…`) were added to `cabal.project`; the solver picked `hs-opentelemetry-sdk-0.1.0.1`. They are test-only deps in `kiroku-otel.cabal`; the library still depends only on `hs-opentelemetry-api`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Model subscription state as **short per-episode spans plus short per-batch work spans**, never as one worker-lifetime span.
  Rationale: Verified in `hs-opentelemetry` that spans export only on `endSpan` (see Surprises). A lifetime span would not be observable on a live worker and would be lost on crash. Per-episode spans (`CatchingUp`, `Reconnecting`, `Retrying`, `Paused`) open on entry and end on exit, so a *completed* episode shows its real duration; per-batch spans during `Live` open and close per fetch, so they export continuously and give live visibility. The honest limitation — an *in-progress* (unresolved) episode does not appear until it ends — is served instead by the existing `currentState` handle accessor and the `KirokuEvent` log stream, and ultimately by a state-gauge *metric*, which stays deferred.
  Date: 2026-05-30.

- Decision: Keep `kiroku-store` free of any `hs-opentelemetry` dependency; the tracer is an opt-in `KirokuEvent -> IO ()` handler in `kiroku-otel`.
  Rationale: Preserves the existing package boundary (the core store never depends on OTel; `kiroku-otel` is the opt-in OTel package). The `eventHandler` callback already carries every transition needed; turning it into spans needs no core change. This is also why the work is *additive* and needs no change to the FSM.
  Date: 2026-05-30.

- Decision: Take the work end-to-end by populating Shibuya's `Envelope.attributes` in the adapter (not only native-subscription spans).
  Rationale: User direction. Shibuya's runner already merges `envelope.attributes` into its per-message span (`shibuya-core/src/Shibuya/Runner/Supervised.hs:397-398`), so populating that field makes the kiroku identity visible on the Shibuya side of a trace with no `shibuya-core` change. Matches the MasterPlan's "end-to-end Shibuya integration" title.
  Date: 2026-05-30.

- Decision: Traces and span attributes only; OTel **metrics** remain deferred.
  Rationale: The user's request was specifically to "reflect the subscription state in traces and capture important attributes." Metric emission (e.g. a current-state gauge, per-state counters) stays deferred consistent with MasterPlan 5's project-wide OTel-metrics deferral.
  Date: 2026-05-30.

- Decision (M1/M2 follow-up): All records introduced by this plan follow the project record-pattern convention in `haskell-jitsurei/core/record-patterns.md`.
  Rationale: The convention is binding for this codebase — records use **no type-name field prefixes** (rely on `DuplicateRecordFields`), **strict fields** (`!`), and an **explicit `deriving stock (...)` strategy** (never a bare `deriving` or an omitted clause). Two records introduced here had drifted from it and were corrected: (1) `KirokuEnvelopeAttrs` (`shibuya-kiroku-adapter`) had no deriving clause → `deriving stock (Generic, Eq, Show)` (full stock set, since it has no function field, unlike the sibling `KirokuAdapterConfig`/`KirokuConsumerGroupConfig` whose `selector` blocks `Eq`/`Show`); (2) `OpenState` (`kiroku-otel`) both carried `os`-prefixed fields and lacked a deriving clause → fields renamed to `catchup`/`reconnect`/`pause`/`retries` and `deriving stock (Generic)` added (`Span` has no `Eq`/`Show`, so `Generic` is the maximal stock set). Full `#label`/lens access (the doc's other half) is **not** adopted in either package because both deliberately avoid the `generic-lens`/`lens` dependency (`kiroku-otel` exists to stay light; the adapter library only carries them in its test stanza); the prefix-free + strict + explicit-deriving rules are honored without them. Recorded here so the convention is applied up front on any future record this plan touches, not retrofitted.
  Date: 2026-05-31.

- Decision (M3): Demonstrate the feature with M1's synthetic-`KirokuEvent` in-memory-exporter coverage plus the M2 adapter attribute test and the documented wiring snippet, rather than standing up a **DB-backed** subscription in `kiroku-otel`'s test suite.
  Rationale: The plan's M3 explicitly permits this alternative when a DB-backed subscription in `kiroku-otel` "is too heavy." `kiroku-otel` is deliberately a light, pure package whose only library dependency is `hs-opentelemetry-api`; its test suite has no Postgres harness. A real subscription would require pulling `kiroku-test-support` + `ephemeral-pg` + `hasql` into the package just to re-prove that the worker emits the lifecycle `KirokuEvent`s — which is EP-1–EP-4's responsibility and is already covered by `kiroku-store-test`. The marginal value is low and the infra cost is high. M1 drives the handler with the exact constructors the real worker emits (the in-memory exporter only ever receives *ended* spans, so each assertion also proves the episode closed), and M2 proves the adapter attributes on a real `RecordedEvent`. The end-to-end wiring is documented in `docs/user/opentelemetry.md` (§ Tracing Subscription State) and the module Haddock.
  Date: 2026-05-30.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

All three milestones are complete (2026-05-30). The feature matches the Purpose: an
operator who opts into `kiroku-otel` can install a ready-made `KirokuEvent` handler
that turns the subscription FSM into OpenTelemetry spans, and those identity
attributes ride through the Shibuya adapter onto Shibuya's per-message spans.

- **Native tracer (M1).** `Kiroku.Otel.Subscription.subscriptionTraceHandler ::
  Tracer -> IO (KirokuEvent -> IO ())` builds an `eventHandler` that mirrors the FSM
  in spans: per-episode `catchup`/`paused`/`reconnecting`/`retrying`, per-batch
  `fetch`, standalone `dead_letter`/`db_error`, all `kiroku.*`-tagged and keyed by
  `(subscription name, member)` in a thread-safe `MVar`. The library still depends
  only on `hs-opentelemetry-api`; `kiroku-store` is untouched. `kiroku-otel-test`:
  **13 examples, 0 failures** against an in-memory exporter — and because the
  exporter only receives *ended* spans, each "span appears" assertion also proves
  the episode closed (the property the export-on-end constraint demanded).
- **End-to-end attributes (M2).** `shibuya-kiroku-adapter` now fills the
  previously-empty `Envelope.attributes` with `kiroku.subscription.name`,
  `kiroku.event.type`, `kiroku.event.global_position`, and (for groups)
  `kiroku.consumer_group.member`, threaded from the adapter config via the new
  `KirokuEnvelopeAttrs`. Keys match the native spans. No `shibuya-core` change.
  `shibuya-kiroku-adapter-test`: **20 examples, 0 failures**.
- **Docs & correction (M3).** Module Haddock + `docs/user/opentelemetry.md` (new
  "Tracing Subscription State" section) document the span model, the export-on-end
  limitation, the batch-processor requirement, and the end-to-end Shibuya path;
  `observability.md` / `shibuya-adapter.md` cross-link it. CHANGELOGs updated.
  MasterPlan 6 no longer asserts the false "`kiroku-otel` already adapts
  `KirokuEvent`" claim.

**Gaps / accepted limitations.** (1) An *in-progress* episode is not visible in the
backend until it ends (export-on-end); real-time state is served by the
`currentState` accessor / `KirokuEvent` log, and ultimately by a deferred
state-gauge metric. (2) OTel *metrics* remain deferred (MasterPlan 5). (3) The
end-to-end proof rests on synthetic-event + adapter-attribute tests plus documented
wiring rather than a DB-backed `kiroku-otel` test, to keep that package light — see
the Decision Log.

**Lessons.** The project pins `hs-opentelemetry-api` 0.3.0.0 from git, not the 0.4
`mori` checkout — always read the *resolved* source. `OpenTelemetry.Attributes.addAttributes`
is a left-biased union, so attribute *updates* must go through the singular
`addAttribute`. The SDK and in-memory exporter had to be pinned from the same git
tag as the api for the test build to link.


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it in full before editing.

**Repository layout relevant to this plan.** The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Three packages matter here:

- `kiroku-store` — the event store and subscription runtime. You will *read* from it but not change it. Key files: `kiroku-store/src/Kiroku/Store/Observability.hs` (the `KirokuEvent` type), `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs` (the `SubscriptionState` type and `SubscriptionStopReason`/`DeadLetterReason`), `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` (`SubscriptionName`, `SubscriptionConfigM`, the `currentState` accessor), `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` (where events are emitted), and `kiroku-store/src/Kiroku/Store/Types.hs` (`GlobalPosition`, `RecordedEvent`, `EventType`).
- `kiroku-otel` — the opt-in OpenTelemetry package. You will *add a module* here. Existing file: `kiroku-otel/src/Kiroku/Otel/TraceContext.hs`. Cabal file: `kiroku-otel/kiroku-otel.cabal`. It already depends on `hs-opentelemetry-api >=0.3 && <0.4` and `hs-opentelemetry-propagator-w3c`.
- `shibuya-kiroku-adapter` — bridges a Kiroku subscription into the Shibuya queue-processing framework. You will *edit* it. Key files: `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` (the adapter config records `KirokuAdapterConfig` and `KirokuConsumerGroupConfig`, and the `kirokuAdapter` / `kirokuConsumerGroupProcessors` entry points) and `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` (the `RecordedEvent → Envelope` conversion).

The Shibuya framework itself lives outside this repository at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; the relevant type `Envelope` is in `shibuya-core/src/Shibuya/Core/Types.hs` and the per-message span is created in `shibuya-core/src/Shibuya/Runner/Supervised.hs`. **No `shibuya-core` change is in scope** — the adapter only fills a field that already exists.

**Build and test commands.** This is a Haskell project built with Cabal under a Nix shell. From the repository root:

```bash
cabal build kiroku-otel
cabal test kiroku-otel
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter
```

If a command fails with a missing-tool error, prefix it with the project's dev shell (look for a `flake.nix` or a `justfile` in the root and follow the existing convention used by the other packages' CI). Do not search `/nix/store`.

**What `KirokuEvent` already gives you (read `kiroku-store/src/Kiroku/Store/Observability.hs`).** The relevant constructors and the data each carries:

```haskell
data KirokuEvent
    = KirokuEventSubscriptionStarted      !SubscriptionName !GlobalPosition !SubscriptionGroupContext
    | KirokuEventSubscriptionCaughtUp     !SubscriptionName !GlobalPosition !SubscriptionGroupContext
    | KirokuEventSubscriptionStopped      !SubscriptionName !GlobalPosition !SubscriptionStopReason !SubscriptionGroupContext
    | KirokuEventSubscriptionPaused       !SubscriptionName !GlobalPosition !SubscriptionGroupContext
    | KirokuEventSubscriptionResumed      !SubscriptionName !GlobalPosition !SubscriptionGroupContext
    | KirokuEventSubscriptionReconnecting !SubscriptionName !Int !SubscriptionGroupContext            -- Int = attempt count from 1
    | KirokuEventSubscriptionFetched      !SubscriptionName !Int !SubscriptionGroupContext            -- Int = row count of one live fetch
    | KirokuEventSubscriptionRetrying     !SubscriptionName !GlobalPosition !Int !SubscriptionGroupContext  -- Int = redelivery attempt from 1
    | KirokuEventSubscriptionDeadLettered !SubscriptionName !GlobalPosition !DeadLetterReason !SubscriptionGroupContext
    | KirokuEventSubscriptionDbError      !SubscriptionName !SubscriptionDbPhase !UsageError !SubscriptionGroupContext
    -- ... (notifier/publisher/hard-delete constructors not relevant here)
```

`SubscriptionGroupContext` (same module) is either `NonGroup` or `GroupMember !Int32 !Int32` (member index, group size). `SubscriptionName` is a newtype in `Subscription/Types.hs`; `GlobalPosition` is a newtype `Int64` in `Store/Types.hs`. `SubscriptionStopReason` and `DeadLetterReason` are in `Subscription/Fsm.hs` and are re-exported from `Observability`.

A crucial property stated in the `Observability` module Haddock: **the callback runs synchronously on the emit-site thread** (the worker loop), and "slow callbacks therefore stall those loops." Opening and ending spans is cheap and in-memory — the *export* is what may block, and the OTel SDK's **batch span processor** does export on a background thread — so the handler is safe as long as it is configured with a batching processor (documented in M3). The Haddock also guarantees the constructor set is **additive**: new events are added, never changed, so a handler that pattern-matches exhaustively will surface any future constructor as a `-Wincomplete-patterns` warning, not a silent miss.

**Why an event→span *state machine* is needed.** A span that represents an *episode* (for example, a pause) must be opened on one `KirokuEvent` (`KirokuEventSubscriptionPaused`) and ended on a later, different one (`KirokuEventSubscriptionResumed`). The `KirokuEvent` stream is flat, so the handler must hold the open `Span` between the two events, keyed by the subscription and member it belongs to. The new module is exactly this: a small, testable correlator that mirrors the FSM transitions visible in the event stream and owns the open spans.

**How Shibuya consumes envelope attributes (read but do not change `shibuya-core/src/Shibuya/Runner/Supervised.hs`).** When Shibuya processes a message it opens a per-message span and merges the envelope's attributes into it:

```haskell
let frameworkAttrs = HashMap.fromList [ (attrMessagingSystem, ...), (attrMessagingMessageId, ...) , ... ]
                      <> case ingested.envelope.partition of
                           Just p  -> [(attrShibuyaPartition, toAttribute p)]
                           Nothing -> []
    mergedAttrs = HashMap.union ingested.envelope.attributes frameworkAttrs   -- left-biased: adapter keys win
addAttributes traceSpan mergedAttrs
```

`Envelope.attributes :: HashMap Text Attribute` (where `Attribute` comes from `OpenTelemetry.Attributes`). The adapter currently sets `attributes = HashMap.empty` (in `Convert.hs:132`). Populating it is all that is required for the kiroku identity to appear on Shibuya's span; the left-biased union means our keys take precedence over framework defaults if they ever collide (they will not, because we use a `kiroku.*` prefix).


## Plan of Work

The work is three milestones. M1 is the heart (the native tracer); M2 carries the identity attributes end-to-end into Shibuya; M3 documents and proves it and fixes the MasterPlan inaccuracy. M1 and M2 are independent and may be done in either order, but M3 depends on both.


### Milestone 1 — the `KirokuEvent` → span tracer in `kiroku-otel`

**Scope.** Add one new module, `kiroku-otel/src/Kiroku/Otel/Subscription.hs`, exporting a factory that builds a `KirokuEvent -> IO ()` handler from an OTel `Tracer`. The handler turns subscription state into spans using the model decided in the Decision Log. Add a test suite that drives it through the in-memory exporter.

**What exists at the end.** An operator can write, in their application wiring:

```haskell
import Kiroku.Otel.Subscription (subscriptionTraceHandler)
-- tracer :: OpenTelemetry.Trace.Core.Tracer   (obtained from the app's TracerProvider)
handler <- subscriptionTraceHandler tracer
-- install as the subscription eventHandler:
--   connectionSettings { eventHandler = Just handler }   (or the per-subscription field)
```

and thereafter every subscription emits spans.

**The span model to implement** (this is the concrete behavior; implement exactly this and record any deviation in the Decision Log):

- **State key.** Every subscription event identifies its origin by `(SubscriptionName, member)` where `member` is `Nothing` for `NonGroup` and `Just m` for `GroupMember m _`. All open-span bookkeeping is keyed by this pair so two consumer-group members never collide.

- **Catch-up episode span.** On `KirokuEventSubscriptionStarted name pos grp`, open a span named `kiroku.subscription.catchup` for that key, set the baseline attributes (below), and store it. On `KirokuEventSubscriptionCaughtUp name pos grp`, end that span (set `kiroku.checkpoint.global_position` to the caught-up position first) — this is the initial catch-up, which now shows its real duration. If a `Started` arrives while a catch-up span is already open for the key (a re-catch-up after reconnect/resume), end the previous one first defensively.

- **Live work spans.** On `KirokuEventSubscriptionFetched name rows grp`, open and immediately end a short span named `kiroku.subscription.fetch` with `kiroku.batch.rows = rows` and `kiroku.subscription.state = "live"` plus the baseline attributes. (These export continuously while the worker is `Live`, giving live visibility. There is intentionally no long-lived `Live` span.)

- **Pause episode span.** On `KirokuEventSubscriptionPaused`, open `kiroku.subscription.paused`. On `KirokuEventSubscriptionResumed`, end it. If a resume arrives with no open pause span for the key, ignore it (do not crash).

- **Reconnect episode span.** On `KirokuEventSubscriptionReconnecting name attempt grp`: if `attempt == 1` (or no reconnect span is open for the key), open `kiroku.subscription.reconnecting` and set `kiroku.subscription.attempt = attempt`; for `attempt > 1`, add a span event `reconnect.attempt` with the attempt number to the already-open span and update the attribute. End the reconnect span on the next `KirokuEventSubscriptionCaughtUp` for the key (a successful re-catch-up) — note this means a `CaughtUp` ends *either* a catch-up span *or* a reconnect span; handle whichever is open.

- **Retry episode span.** On `KirokuEventSubscriptionRetrying name pos attempt grp`: key the retry span by `(SubscriptionName, member, pos)` because retries are per poison event. On `attempt == 1` open `kiroku.subscription.retrying` with `kiroku.event.global_position = pos`; on later attempts add a `retry.attempt` span event. End the retry span when either a `KirokuEventSubscriptionDeadLettered` for the same `pos` arrives (set `kiroku.dead_letter.reason`, mark the span status/event as dead-lettered, end it) **or** the next `KirokuEventSubscriptionFetched`/`CaughtUp` for the key arrives (the worker moved on, i.e. the retry eventually succeeded — end it as ok). Keep the retry-span map small by ending stale entries on `Stopped`.

- **Dead-letter span event.** `KirokuEventSubscriptionDeadLettered` that does *not* match an open retry span (a handler that dead-letters immediately, no retry) is recorded as a short standalone span `kiroku.subscription.dead_letter` with `kiroku.dead_letter.reason` and `kiroku.event.global_position`.

- **DB error.** `KirokuEventSubscriptionDbError` adds a span event `kiroku.db_error` (with the phase) to whatever episode span is currently open for the key, or a short standalone span if none is open.

- **Stop.** On `KirokuEventSubscriptionStopped name pos reason grp`, end every span still open for the key (catch-up, pause, reconnect, any retry spans), setting `kiroku.subscription.stop_reason` on the most relevant one, then drop the key from all maps. This guarantees no span is leaked when a worker stops.

**Baseline attribute set** (set on every span; use a `kiroku.` prefix to avoid collisions with Shibuya/framework keys):

- `kiroku.subscription.name` — from `SubscriptionName`.
- `kiroku.consumer_group.member` and `kiroku.consumer_group.size` — from `SubscriptionGroupContext` when `GroupMember m size`; omitted for `NonGroup`.
- `kiroku.checkpoint.global_position` — the `GlobalPosition` carried by the event (when present).
- `kiroku.subscription.state` — a stable lowercase string for the state the span represents (`"catchup"`, `"live"`, `"paused"`, `"reconnecting"`, `"retrying"`).
- `kiroku.subscription.attempt` — the attempt counter for reconnect/retry spans.

The handler must keep its open-span maps in a single mutable cell (an `IORef` of a record of `Map`s, or an `MVar`); access is from the worker thread (synchronous callback) but a consumer-group runs one worker per member on separate threads, so use a thread-safe cell (`MVar`/`atomicModifyIORef'`) and key by member to avoid cross-member interference. Document this in the module Haddock.

**Span creation API.** Use `OpenTelemetry.Trace.Core` from `hs-opentelemetry-api`: `createSpan :: Tracer -> Context -> Text -> SpanArguments -> IO Span`, `endSpan :: Span -> Maybe Timestamp -> IO ()`, `addAttribute`/`addAttributes`, `addEvent` with `newEvent`/`mkEvent`. Obtain a no-parent `Context` from `OpenTelemetry.Context` (empty context) — these spans are roots correlated by attributes, not nesting, per the Decision Log. **Before coding, confirm the exact signatures against the pinned `hs-opentelemetry-api` 0.3.x** (the cabal bound is `>=0.3 && <0.4`); the names above are stable across 0.x but verify arity. Read the installed API source via `mori registry show hs-opentelemetry --full` and the package path it prints.

**Tests (the proof).** Add a test suite (or extend the existing `kiroku-otel/test/Main.hs`) that:

1. Builds an in-memory exporter and a `TracerProvider` from it. Add `hs-opentelemetry-sdk` and `hs-opentelemetry-exporter-in-memory` to the **test** stanza of `kiroku-otel/kiroku-otel.cabal` (not the library — the library still depends only on the API). Confirm the in-memory exporter's module name and the function that drains collected spans by reading its source via `mori`.
2. Feeds a synthetic `KirokuEvent` sequence through `subscriptionTraceHandler tracer` and force-flushes the provider, then asserts on the exported spans. At minimum:
   - **Catch-up then live:** `Started → CaughtUp → Fetched(rows=3)` yields one `kiroku.subscription.catchup` span (ended) and one `kiroku.subscription.fetch` span with `kiroku.batch.rows = 3`.
   - **Pause/resume:** `Paused → Resumed` yields one `kiroku.subscription.paused` span that **is ended** (assert it appears in the exported set — proving the episode closed and is observable).
   - **Reconnect:** `Reconnecting(1) → Reconnecting(2) → CaughtUp` yields one `kiroku.subscription.reconnecting` span with a `reconnect.attempt` span event and `kiroku.subscription.attempt = 2`.
   - **Retry then dead-letter:** `Retrying(pos=42, attempt=1) → Retrying(pos=42, attempt=2) → DeadLettered(pos=42, reason)` yields one `kiroku.subscription.retrying` span (ended) carrying `kiroku.event.global_position = 42` and the dead-letter reason.
   - **Consumer-group isolation:** interleaved events for `GroupMember 0 2` and `GroupMember 1 2` produce separate spans each tagged with the right `kiroku.consumer_group.member`.
   - **No leak on stop:** an open pause span followed by `Stopped` is ended (present in the exported set).

**Acceptance.** `cabal test kiroku-otel` passes with the new assertions. Because the in-memory exporter only ever receives **ended** spans, every assertion that a span "appears" is also a proof that the episode closed — which is precisely the property the Decision Log requires.


### Milestone 2 — carry kiroku identity attributes through the Shibuya adapter

**Scope.** Populate `Envelope.attributes` in `shibuya-kiroku-adapter` so the kiroku identity appears on Shibuya's per-message span. The attributes are `kiroku.subscription.name`, `kiroku.consumer_group.member` (for grouped subscriptions), `kiroku.event.type`, and `kiroku.event.global_position`.

**The threading problem and its solution.** `Convert.toEnvelope :: RecordedEvent -> Envelope RecordedEvent` (in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`) sees only the `RecordedEvent`, from which it can derive `kiroku.event.type` (the `eventType` field) and `kiroku.event.global_position` (the `globalPosition` field). But the **subscription name** and **consumer-group member** are not on the event — they are known only at the adapter-config level. So:

- Add a small attribute-source value and thread it from `kirokuAdapter` (which knows the subscription name from `KirokuAdapterConfig`) and from `kirokuConsumerGroupProcessors` (which knows the name and assigns each per-member processor its member index — see EP-42's `ProcessorId "<name>-member-<m>"` construction in `Shibuya/Adapter/Kiroku.hs`) into the conversion. Define the record per the project record-pattern convention (`haskell-jitsurei/core/record-patterns.md`): **no type-name field prefixes**, strict fields, and an **explicit `deriving stock` strategy** — matching the sibling `KirokuAdapterConfig`/`KirokuConsumerGroupConfig` records in the same package:

    ```haskell
    data KirokuEnvelopeAttrs = KirokuEnvelopeAttrs
        { subscriptionName :: !Text
        , member :: !(Maybe Int)
        }
        deriving stock (Generic, Eq, Show)
    ```
- Change `toEnvelope` (and/or `toIngestedAck`, which calls it) to accept this value and build the `attributes` HashMap: always set `kiroku.subscription.name`, `kiroku.event.type`, `kiroku.event.global_position`; set `kiroku.consumer_group.member` only when `member` is `Just`. Use `OpenTelemetry.Attributes.toAttribute` to build each `Attribute` value (the same `Attribute` type Shibuya's `Envelope.attributes` uses).

This composes with the existing W3C trace-context propagation already done in `toEnvelope` (`traceContext = metadataTraceContext meta`) — that sets the span's *parent*; the new attributes are *tags* on the child span Shibuya creates. No `Convert.hs` ack-handle logic changes; no `shibuya-core` change.

Note `shibuya-kiroku-adapter` will need `hs-opentelemetry-api` available (it already transitively links Shibuya, which uses it; confirm the adapter's cabal exposes `OpenTelemetry.Attributes` and add the dependency to the adapter library stanza if missing).

**Tests (the proof).** In `shibuya-kiroku-adapter-test`, add an assertion that the `Envelope` produced for a `RecordedEvent` (via the single-adapter path and via a consumer-group member) has `attributes` containing `kiroku.subscription.name`, `kiroku.event.type`, `kiroku.event.global_position`, and — for the group case — `kiroku.consumer_group.member` with the right member index. The existing adapter tests already build `RecordedEvent`s and exercise both paths; extend one of them rather than standing up a new harness.

**Acceptance.** `cabal test shibuya-kiroku-adapter` passes; the new assertions show a non-empty `attributes` map with the four keys.


### Milestone 3 — documentation, end-to-end example, CHANGELOGs, and MasterPlan correction

**Scope.** Make the feature discoverable and prove it end-to-end, and fix the MasterPlan inaccuracy.

- **`kiroku-otel` docs.** Add module Haddock to `Kiroku.Otel.Subscription` explaining the span model, the export-on-end constraint (why there is no lifetime span and what the limitation is for live debugging), and the requirement to use a **batch span processor** so the synchronous callback never blocks the worker on export. Add a short usage snippet to the package README if one exists.
- **Architecture/user docs.** The subscription observability is described in the repo's arch/user docs (search `docs/` for the file updated by EP-1's M4, which added the FSM observability section). Add a subsection on OTel tracing: the span names, the attribute keys, and the end-to-end Shibuya path. Keep it consistent with the `kiroku.*` attribute names used in code.
- **End-to-end example/test.** Add a test (in `kiroku-otel` or a small integration test) that runs a *real* subscription against a test database with `subscriptionTraceHandler` installed and an in-memory exporter, drives a scenario that pauses or reconnects, and asserts the corresponding span appears. If standing up a DB-backed subscription in `kiroku-otel`'s suite is too heavy, instead document the wiring in the example snippet and rely on M1's synthetic-event coverage plus a note; record that choice in the Decision Log.
- **CHANGELOGs.** Add entries to `kiroku-otel/CHANGELOG.md` and `shibuya-kiroku-adapter/CHANGELOG.md`.
- **MasterPlan correction.** Edit MasterPlan 6's Vision & Scope sentence that claims "the `kiroku-otel` package already adapts `KirokuEvent`" (the MasterPlan update accompanying this plan does this; if any residual inaccurate wording remains, fix it). Ensure the MasterPlan's Exec-Plan Registry row for this plan and its Progress entries are accurate.

**Acceptance.** Docs build/read cleanly; CHANGELOGs updated; the end-to-end test (or the documented-and-justified alternative) is in place; MasterPlan no longer asserts the false statement.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless stated otherwise.

1. Locate the pinned OTel API and the in-memory exporter source so you code against the real signatures:

    ```bash
    mori registry show hs-opentelemetry --full
    ```

    Read the printed package paths for `hs-opentelemetry-api` (functions `createSpan`, `endSpan`, `addAttribute`, `addAttributes`, `addEvent`, `newEvent`/`mkEvent`; module `OpenTelemetry.Attributes` for `toAttribute`) and `hs-opentelemetry-exporter-in-memory` / `hs-opentelemetry-sdk` (how to build a provider over an in-memory exporter and drain collected spans). Do **not** search `/nix/store`.

2. M1: create `kiroku-otel/src/Kiroku/Otel/Subscription.hs`; add the module to `kiroku-otel/kiroku-otel.cabal`'s `exposed-modules`; add `hs-opentelemetry-sdk` and `hs-opentelemetry-exporter-in-memory` to the **test** stanza only. Build and test:

    ```bash
    cabal build kiroku-otel
    cabal test kiroku-otel
    ```

    Expected: the new suite reports `0 failures` with the assertions from M1.

3. M2: edit `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` and `.../Kiroku.hs` to thread the identity and populate `Envelope.attributes`; extend `shibuya-kiroku-adapter-test`. Build and test:

    ```bash
    cabal build shibuya-kiroku-adapter
    cabal test shibuya-kiroku-adapter
    ```

    Expected: `0 failures`, new attribute assertions pass.

4. M3: update docs and CHANGELOGs, add the end-to-end example/test, and verify the whole set builds:

    ```bash
    cabal build all
    cabal test kiroku-otel shibuya-kiroku-adapter
    ```

Update this section with the actual transcripts as you go.


## Validation and Acceptance

The feature is accepted when:

- `cabal test kiroku-otel` proves, via the in-memory exporter, that each subscription state produces the expected span with the expected `kiroku.*` attributes, and that every transient-state episode span (`paused`, `reconnecting`, `retrying`, `catchup`) **ends** (it can only appear in the in-memory exporter if it ended). This is the direct, observable demonstration that "subscription state is reflected in traces."
- `cabal test shibuya-kiroku-adapter` proves the produced Shibuya `Envelope` carries `kiroku.subscription.name`, `kiroku.event.type`, `kiroku.event.global_position`, and (for groups) `kiroku.consumer_group.member` — demonstrating the attributes travel end-to-end into Shibuya's per-message span.
- The docs describe the span names, attribute keys, the batch-processor requirement, and the honest live-debugging limitation; CHANGELOGs are updated; MasterPlan 6 no longer claims `kiroku-otel` already adapts `KirokuEvent`.


## Idempotence and Recovery

All edits are additive: a new module in `kiroku-otel`, additional test dependencies in a test stanza, new fields/arguments threaded through the adapter, and new test cases. Re-running the build/test commands is safe and repeatable. No database migration and no schema change are involved (the tracer is entirely in-memory, worker-thread-side). If the OTel API signatures differ from those assumed here, adjust the calls (the model is unchanged) and record the difference in Surprises & Discoveries. If threading the identity through the adapter proves to touch more call sites than expected, prefer adding an optional parameter with a no-attribute default so partially-applied edits still compile and tests stay green between steps.


## Interfaces and Dependencies

- **New, `kiroku-otel`:** module `Kiroku.Otel.Subscription` exporting at least `subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())` (the factory; it allocates the open-span state cell and returns the handler). It may also export the attribute-key constants. Library depends only on `hs-opentelemetry-api` (unchanged) plus `kiroku-store` (for the `KirokuEvent` type, already a dependency — confirm; add if missing). Test stanza adds `hs-opentelemetry-sdk` and `hs-opentelemetry-exporter-in-memory`.
- **Read-only, `kiroku-store`:** `Kiroku.Store.Observability` (`KirokuEvent`, `SubscriptionGroupContext`, `SubscriptionDbPhase`, `SubscriptionStopReason`, `DeadLetterReason`), `Kiroku.Store.Subscription.Types` (`SubscriptionName`), `Kiroku.Store.Types` (`GlobalPosition`, `RecordedEvent`, `EventType`). No change.
- **Edited, `shibuya-kiroku-adapter`:** `Shibuya.Adapter.Kiroku.Convert` (`toEnvelope`/`toIngestedAck` gain an identity parameter and populate `Envelope.attributes`) and `Shibuya.Adapter.Kiroku` (`kirokuAdapter`/`kirokuConsumerGroupProcessors` pass subscription name and member index in). Uses `OpenTelemetry.Attributes` (`Attribute`, `toAttribute`) — the same `Attribute` type as `shibuya-core`'s `Envelope.attributes :: HashMap Text Attribute`. No `shibuya-core` change.
- **External, unchanged:** `shibuya-core/src/Shibuya/Runner/Supervised.hs` already merges `envelope.attributes` into its per-message span (lines 397–398); we only fill the field.


## Revision Notes

- **2026-05-31** — Brought both records introduced by this plan into line with the project record-pattern convention (`haskell-jitsurei/core/record-patterns.md`):
  - `KirokuEnvelopeAttrs` (M2, `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`) had been added without any deriving clause; gave it `deriving stock (Generic, Eq, Show)` and added the `GHC.Generics (Generic)` import. Its fields (`subscriptionName`, `member`) were already prefix-free and strict.
  - `OpenState` (M1, `kiroku-otel/src/Kiroku/Otel/Subscription.hs`) — the internal open-span state record — carried type-name-prefixed fields (`osCatchup`/`osReconnect`/`osPause`/`osRetries`) and had no deriving clause. Renamed the fields to `catchup`/`reconnect`/`pause`/`retries` and added `deriving stock (Generic)` + the `GHC.Generics (Generic)` import.

  Full `#label`/lens access (the doc's other half) was not adopted, because neither package depends on `generic-lens`/`lens` by design. Updated the M1 and M2 Progress entries, the M2 Plan-of-Work record example, and the Decision Log. Both suites stay green: `cabal test kiroku-otel` (13 examples, 0 failures) and `cabal build shibuya-kiroku-adapter` (library + test compile clean).
