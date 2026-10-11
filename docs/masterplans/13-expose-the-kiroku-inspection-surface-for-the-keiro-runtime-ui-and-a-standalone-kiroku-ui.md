---
id: 13
slug: expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui
title: "Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI"
kind: master-plan
created_at: 2026-09-30T22:35:14Z
intention: "intention_01m3t7a7jaeewbf71vqrzk4zd8"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T22:35:14Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:06Z
      mode: "update"
      note: "Correct current APIs, integration ownership and bounded observer work; runtime acceptance remains pending."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T15:58:37Z
      mode: "implement"
      note: "Coordinate EP-1 implementation and validation"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T17:30:29Z
      mode: "implement"
      note: "Coordinate EP-2 implementation and validation"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T18:08:46Z
      mode: "implement"
      note: "Coordinate EP-3 SQL promotion and implementation"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:06Z
      verdict: "comments"
      note: "Source review corrections applied; SQL promotion and focused performance gates require implementation evidence."
---

# Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Kiroku is a PostgreSQL-backed event store written in Haskell. Its HTTP and WebSocket surface
lives in the sister package `kiroku-metrics` (`kiroku-metrics/src/Kiroku/Metrics/`), which today
serves metrics, health probes, the process-local live subscription registry, and a replayable
WebSocket event tail. In August 2026 the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`) audited that surface and
filed six improvement requests in this repository's `docs/improvement-requests/` bundle, IR-8
through IR-13, describing exactly what a browser UI needs from Kiroku and cannot get today:
paginated browsing of streams, categories, and events; public dead-letter reads; durable
cross-process subscription checkpoints over HTTP; CORS so a page on another origin can call the
server at all; additive convergence of the WebSocket protocol with the cross-project convention;
and a citable wire-stability contract. IR-13 is complete
([ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)).
The other five are open. Four of them already have ExecPlans (87, 88, 89, 90) written on
2026-09-10 as independent single plans; none has started, and each contains its own guess about
how to share the server-composition code, the error envelope, the version numbers, and the
release with its siblings. IR-12 has no plan.

This initiative coordinates all five open requests into one cohort and adds the one requirement
the requests do not state: everything exposed must also serve an **independent Kiroku UI**, a
browser application for teams that adopt only the event store and never link keiro. That
requirement changes nothing about the endpoints keiro-ui asked for, but it adds two things a
keiro-composed deployment gets for free from keiro and a store-only deployment does not: a way
to run the inspection surface without writing a Haskell host program, and a way for a UI to
discover what a given server offers instead of probing for 404s.

After the initiative is complete, an operator can point a browser UI at any process that
serves the Kiroku inspection surface and see: every stream and category with cursor pagination,
any stream's events forward or backward, the global `$all` log from any position with resolved
stream names, any single event by id, every subscription's durable checkpoint and store position
no matter which process is asked, each subscription's dead letters with the structured failure
reason, the process-local live registry and metrics where the process runs subscriptions, and a
live event tail whose frames carry resolved stream names and stable error codes. A page served
from a different origin can call all of it once the host lists that origin. A team without a
Haskell host program runs `kiroku-inspect --database-url ...` and gets the same surface from a
database URL. A UI asks `GET /capabilities` to learn which route families a server provides.
The whole cohort ships as one coordinated Hackage release (`kiroku-store` 0.11.0.0,
`kiroku-metrics` 0.3.0.0, and patch releases of the packages whose bounds move), proven from a
clean external consumer, after which IR-8 through IR-12 are `completed`.

In scope: the four `kiroku-store` read primitives beneath the endpoints (`listStreams`,
`listCategories`, `getEvent`, `subscriptionDeadLetters`), every route and frame the five
requests name, the CORS policy and middleware, the `ServerProviders` composition record and the
general starters that replace positional growth of the server API, the standalone
`kiroku-inspect` executable, the `GET /capabilities` discovery route, a task-oriented guide for
UI builders, the conformance mapping for the WebSocket protocol, the request lifecycle
bookkeeping, and the cohort release.

Explicitly out of scope: authentication, authorization, TLS, and rate limiting (the recorded
posture of every inspection server in the stack is a trusted network or an authenticating
reverse proxy; the conventions and each child's documentation restate it); any mutating
endpoint (dead-letter redrive or deletion, checkpoint reset, lifecycle control), which
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7` reserves for separately gated
owning-repository requests; bounded fan-in replay windows
(`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1`, a keiro request, not a UI
request); serving the browser UI's static assets from `kiroku-metrics`; composing several
projects' surfaces into one process, which keiro owns under
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`; renaming or reshaping any
published body, frame, path, or field, which ADR-9 forbids; a host bind-address option beyond
what the children find trivial and additive; and the browser UI itself, in either repository.


## Decomposition Strategy

The initiative decomposes by functional concern into seven child plans in three waves. Four of
the children already exist as plans 87, 88, 89, and 90 and are adopted here rather than
rewritten: each is a complete, self-contained specification of one request, and rewriting three
hundred kilobytes of reviewed plan text to change a handful of shared decisions would destroy
more value than it adds. Instead this MasterPlan settles the shared decisions in Integration
Points, and each adopted plan carries a short coordination note and targeted edits that point
at them. Three new children cover what no existing plan does: IR-12, the independent-UI
enablers, and the cohort release.

Wave one is the enabling and foundation work. EP-1 (plan 90, CORS) touches only
`MetricsServerConfig` and the single composition point of the server, has no dependency on any
other child, and is the request without which no browser reaches any endpoint; it lands first
so that every later route inherits the policy. EP-2 (plan 87, durable checkpoints) is the
smallest route plan, wraps a library operation that shipped long ago, and is therefore the right
owner of the providers record and server lifecycle. EP-1 owns the shared structured error
helpers; EP-2 hard-depends on EP-1 and reuses them. Making the
smallest plan the owner keeps the foundation reviewable and lets the two larger route plans
start from a settled server API.

Wave two is the routes and the protocol. EP-3 (plan 88, browse) and EP-4 (plan 89, dead
letters) each add library primitives to `kiroku-store` and a route family to `kiroku-metrics`;
they are independent of each other, both hard-depend on EP-2 for the record and envelope, and
can be implemented in parallel by different sessions. EP-5 (plan 94, WebSocket convergence) hard-depends on EP-3, the sole owner of the
resolved-name event encoder. No first-arrival ownership rule remains.

Wave three is the independent-UI enablers and the release. EP-6 (plan 95) adds the standalone
executable, the discovery route, and the UI-builder guide; it hard-depends on all five route, CORS and protocol plans because the executable serves the complete surface and the discovery route reports
the complete provider record. EP-7 (plan 96) assigns versions, releases the cohort, proves it
from a clean consumer, and completes the five requests; it hard-depends on everything.

Alternatives considered. Folding the standalone executable and the discovery route into the
existing route plans was rejected because they are a distinct functional concern (self-hosting
and self-description) that must observe the finished record, and because it would widen four
reviewed plans at once. Putting the standalone server in `kiroku-cli` as `kiroku serve` was
rejected because `kiroku-metrics` already depends on `kiroku-cli` for the shared
subscription-status codec, so the dependency would be circular; the executable lives in
`kiroku-metrics`. Releasing each request separately, as plans 87, 89, and 90 each planned, was
rejected because they change the same package and the same `MetricsServerConfig` and server
signatures, so separate releases would force `kiroku-metrics` through three major versions in a
week for one cohort of consumers. Adding a discovery route to keiro's composed mount instead of
to `kiroku-metrics` was rejected because a store-only deployment has no keiro. Writing a fresh
ExecPlan for each of IR-8 through IR-11 was rejected for the reason given above.

Relevant durable context, read for this initiative (the rest of `docs/adr/` was scanned by
heading and is not relevant):

- [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
  is the contract every child ships under: a shape becomes published when it ships in a Hackage
  release and is documented in `docs/user/metrics.md`; published fields, frames, and paths are
  never removed, renamed, or re-typed; additions are optional fields, new frame types, new
  routes, and new vocabulary members; new keys are snake_case even on the camelCase event
  object; a new surface ships with a test that pins its key set; `kiroku-store` owns no wire
  format and gains no web dependency; a sister package wraps supported library APIs and adds a
  missing read to the library first. EP-7 is the moment every child's shape becomes published.
- [ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md): fan-in reads
  carry a surrogate `originalStreamId`; names are resolved in batches with `lookupStreamNames`.
  EP-3 resolves them server-side for REST pages, and EP-5 does the same for WebSocket frames,
  because a browser client has no other way to turn a surrogate id into a name.
- [ADR-6](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md): the
  SQL-native precedent for frozen published surfaces; `kiroku.subscription_checkpoints_v1` is
  the relation EP-2's route mirrors.
- [ADR-5](../adr/0005-three-tier-performance-regression-gates.md): the structural and
  controlled-workload gates behind `just perf-check` are authoritative. EP-3 and EP-4 add read
  statements off every hot path and pin their query plans in
  `kiroku-store/test/Test/PerformanceStructure.hs`; EP-7 runs the gates as a release gate.
- [ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md):
  values that can be invalid are validated at construction with typed `Either` results; EP-4's
  page-size limit and EP-1's allowed-origin constructor follow it.
- [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) and
  [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md) explain why EP-2's rows are
  keyed by `(subscription, member)` and why `store_position` is the append frontier, not the
  visible head.

Cross-repository decisions, cited by the canonical handles the keiro-ui bundle publishes:
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1` (every inspection endpoint lives in the
project that owns the concept; store views are Kiroku's), `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2` (the WebSocket convention and
its frozen-dialect rule), `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3` (push is a hint, poll is truth), `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4` (inspection surfaces
live in sister packages that export a bare WAI `Application`), `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-5` (no backend-for-frontend:
the UI consumes these endpoints directly, so the published version set is the contract), and
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7` (read-only first). The shared wire conventions are `mori://shinzui/keiro-ui`,
`docs/architecture/inspection-api-conventions.md` (artifact-level URI pending). Keiro's composed
mount, `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`, will mount this package's
exported application behind a path prefix, which constrains EP-2, EP-5, and EP-6 as recorded in
Integration Points.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Add configurable CORS support to kiroku-metrics (IR-11) | docs/plans/90-add-configurable-cors-support-to-kiroku-metrics.md | None | None | Complete |
| 2 | Serve durable subscription checkpoints over HTTP (IR-10) | docs/plans/87-serve-durable-subscription-checkpoints-over-http.md | EP-1 | None | Complete |
| 3 | Expose a REST read API for browsing streams, categories, and events (IR-8) | docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md | EP-2 | EP-4 | In Progress |
| 4 | Expose a public dead-letter read API (IR-9) | docs/plans/89-expose-a-public-dead-letter-read-api.md | EP-2 | EP-3 | Not Started |
| 5 | Converge the kiroku-metrics WebSocket protocol with the cross-project convention (IR-12) | docs/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md | EP-3 | None | Not Started |
| 6 | Serve the Kiroku inspection surface standalone and make it self-describing | docs/plans/95-serve-the-kiroku-inspection-surface-standalone-and-make-it-self-describing.md | EP-1, EP-2, EP-3, EP-4, EP-5 | None | Not Started |
| 7 | Release the inspection surface cohort and complete the keiro-ui requests | docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md | EP-1, EP-2, EP-3, EP-4, EP-5, EP-6 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Plans 87, 88, 89, and 90 were created on 2026-09-10 as standalone plans under their own
Intentions (`intention_01m24k3bxye7cv6x088hpvs6ne`, `intention_01m24kefe1en2vvvek852kwcgv`,
`intention_01m24mtzy1embbt15zkh9h3z8c`, and `intention_01m24n4q6verjrhrk58qt6gbh2`) and were
adopted by this MasterPlan on 2026-09-30. Commits under those four plans carry their own
`Intention:` trailer together with the `MasterPlan:` trailer for this file; commits under plans
94, 95, and 96 carry this MasterPlan's Intention.


## Dependency Graph

EP-1 creates CORS and error helpers. EP-2 hard-depends on it and owns the providers
record, readiness, cancellation and mount behavior. EP-3 and EP-4 hard-depend on EP-2;
they can proceed independently but must preserve each other's Store interpreter arms,
structural tests and documentation. Their shared-file coordination is a soft dependency.

EP-5 hard-depends on EP-3 because it consumes the event encoder EP-3 owns.
EP-6 hard-depends on EP-1 through EP-5 so its complete-surface guide, capability tests
and standalone tail behavior refer to the implemented protocol. EP-7 hard-depends on all
six and owns release truth and cumulative performance acceptance.

```text
EP-1 -> EP-2 -> EP-3 -> EP-5 -> EP-6 -> EP-7
             \-> EP-4 ---------^
```

The longest serial chain has six plans. Registry dependencies and child prerequisites
must match this graph. Do not create shared artifacts out of order merely to parallelize.


## Integration Points

**Reviewed implementation constraints (2026-10-10).**
[ADR-15](../adr/0015-inspection-observers-preserve-wire-contracts-and-bound-shared-work.md)
records compatibility and bounded observer work; ADR-12 governs current typed decoding.
The September plans were checked against source at `f1a0209`; no feature or performance
milestone was implemented during review.

EP-2 owns readiness-before-return and propagates bind/server failures, preserving old starter
signatures. It normalizes mount-relative WebSocket dispatch as well as HTTP paths and enforces
enableWebSocket=False before upgrade dispatch. EP-6 tests capability truth against that
behavior; its callback is exactly `Int -> Capabilities -> IO ()`. Capabilities uses the
Haskell selector corsIsEnabled and ProviderPresence uses presentWebSocketChannels to avoid
conflicting umbrella exports. The JSON cors.enabled spelling is unchanged.

EP-3 owns validated BrowseLimits and same-query cursor/prefix correctness. Its nullable/prefix
SQL failed the sparse-prefix generic/custom EXPLAIN promotion check on 2026-10-10;
a reviewed prefix redesign is required before production implementation.
EP-4 bounds all-member candidates by member count times page size using existing per-member
index scans, including historical members. No child adds an append index or changes collation
to hide read costs without a separate reviewed design. Inventory is explicitly unpaginated;
clients must avoid overlapping polls. No child may claim LIMIT alone bounds query work.

EP-7 selects focused cumulative PostgreSQL 18 evidence against a pre-inspection control,
including disabled observers and representative active polling/tailing beside appends.
Existing pipeline ratios and another cohort's practical acceptance do not prove neutrality.
Correctness, structural invariants and child-specific focused checks come first; no default
full performance matrix or tight universal precision. Remote runs require the user's scoped
preflight details and one total 60-minute ceiling including setup/recovery/repeats.
Confirmed regressions block release; uncertainty is retained, not renamed a pass.

**The server composition record and starters** (owner: EP-2, plan 87; consumers: EP-3, EP-4,
EP-6; constraint on EP-1). Shared artifact: `kiroku-metrics/src/Kiroku/Metrics/Server.hs`. Plans
87 and 88 each proposed a different record (`MetricsProviders` replacing a positional argument
versus `ServerProviders` beside the legacy starters), and plan 89 deferred to whichever landed
first. This MasterPlan settles the shape, which EP-2 introduces and every later plan extends by
adding a field, never a second record or a second starter:

```haskell
-- Kiroku.Metrics.Server
data ServerProviders = ServerProviders
    { webSocketServer :: !WS.ServerApp
    , subscriptionStatus :: !(Maybe SubscriptionStatusProvider)      -- GET /subscriptions (live, process-local)
    , checkpointInventory :: !(Maybe CheckpointInventoryProvider)    -- GET /subscription-checkpoints        (EP-2)
    , storeBrowsing :: !(Maybe StoreBrowser)                               -- /streams, /categories, /events        (EP-3 adds)
    , deadLetters :: !(Maybe DeadLetterProvider)                     -- GET /subscriptions/<name>/dead-letters (EP-4 adds)
    , webSocketChannels :: !WebSocketChannels                        -- declared channels (EP-6 adds)
    }

defaultServerProviders :: ServerProviders      -- stubWebSocketApp, every provider Nothing
storeServerProviders :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> IO ServerProviders
    -- everything a store can offer, including the live registry; allocates the WebSocket state

startMetricsServerWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> IO MetricsServer
withMetricsServerWithProviders  :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> (MetricsServer -> IO a) -> IO a
combinedAppWithProviders        :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> Application
httpAppWithProviders            :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> Application
```

Every pre-existing starter and application function (`startMetricsServer`,
`startMetricsServerWith`, `startMetricsServerWith'`, `startMetricsServerWithStore`,
`withMetricsServer`, `withMetricsServerWithStore`, `withMetricsServerSubscriptions`,
`combinedApp`, `httpApp`) keeps its exact signature and becomes a one-line delegation.
`startMetricsServerWithStore` and `withMetricsServerWithStore` wire the real WebSocket app and
every store-backed provider that has landed (`checkpointInventory` from EP-2, `browser` from
EP-3, `deadLetters` from EP-4) but never `subscriptionStatus`, so `GET /subscriptions` on those
starters keeps answering its published 404, as plans 87 and 88 both decided.
`storeServerProviders` wires all five and is the documented path for new hosts and for EP-6's
executable. `combinedAppWithProviders` is the single composition point: it is the value wrapped
in `corsMiddleware cfg.cors` (EP-1's invariant), the value handed to Warp, and the value keiro's
composed mount (IR-31) will embed behind a path prefix. Consequently no route may assume an
absolute mount path, `httpAppWithProviders` matches `pathInfo` relative to the mount, and no
response may carry an absolute URL. Plan 87's `MetricsProviders`, `noProviders`, and
`storeProviders` are withdrawn; plan 88's Milestone 3 becomes "add the `browser` field and route
arm to the record EP-2 introduced"; plan 89's coordination rule 1 applies. EP-6 (plan 95) adds
one non-provider field, `webSocketChannels :: WebSocketChannels`, declaring which WebSocket
channels the chosen `webSocketServer` serves (a `WS.ServerApp` is opaque, so the builder of the
record declares it: `storeServerProviders` and `startMetricsServerWithStore` declare both,
`defaultServerProviders` and the legacy caller-supplied starters declare none), and exports a
`providerPresence :: ServerProviders -> ProviderPresence` projection for the discovery route.

**The structured error envelope** (owner: EP-1, plan 90, because it lands first; consumers:
EP-2, EP-3, EP-4, EP-6). Shared artifact: `kiroku-metrics/src/Kiroku/Metrics/JSON.hs`. One
helper pair with the details-carrying shape plan 89 asked for:

```haskell
-- Kiroku.Metrics.JSON
errorEnvelope :: Text -> Text -> Maybe Value -> Value
-- {"error":{"code":"<snake_case>","message":"<sentence>"}} plus "details" only when Just
errorResponse :: Status -> Text -> Text -> Maybe Value -> Response
storeErrorResponse :: Text -> StoreError -> Response  -- sanitized unavailable code / typed 500 mapping
```

Plan 87's two-argument `errorEnvelope` and plan 88's `browseErrorResponse` are replaced by
these; a plan that finds them already present reuses them and never adds a variant. The legacy
`{"error":"<string>"}` bodies on every pre-existing route and on the catch-all are frozen and
untouched. Shared code vocabulary across route families: `invalid_query_parameter` (400, with
`details` `{"parameter","value","reason"}`), `method_not_allowed` (405), `not_found` (404,
structured, only on paths under a new route family), `<family>_not_configured` (404 when the
provider is absent), `<family>_unavailable` or `store_unavailable` (503 on `ConnectionError`),
`event_decode_failed` (500 on EventDecodeFailed), and `store_error` (500 on other StoreError).
Never include raw error text, connection strings or payloads. New read routes implement
GET/HEAD and 405 with Allow: GET, HEAD; old route method behavior remains unchanged. Each child documents its own codes in
`docs/user/metrics.md`; EP-6's guide collects them.

**The resolved-name event object** (owner: EP-3, plan 88; consumer: EP-5, plan 94). Shared
artifact: `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`, beside `recordedEventToJSON`. The
function `recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value`
emits the published camelCase event object plus exactly one snake_case key,
`original_stream_name` (string, or `null` when unresolvable). EP-3 uses it for every REST item;
EP-5 uses it for `event` frames with a per-connection cache so unseen ids cost one batched
`lookupStreamNames` round trip per delivered batch. Plan 88's `recordedEventToBrowseJSON` in
`Kiroku.Metrics.Browse` is renamed and relocated to this. EP-5 hard-depends on EP-3 and never introduces a competing definition. The
justification is ADR-1: names are not carried on `RecordedEvent` because the batch lookup is
cheaper than a join on `$all` pages, and a browser has no other resolver.

**`MetricsServerConfig`** (owner: EP-1, plan 90). Shared artifact:
`kiroku-metrics/src/Kiroku/Metrics/Config.hs`. EP-1 adds `cors :: !CorsPolicy` with
`defaultConfig{cors = corsDisabled}`; this is the cohort's one configuration change and the
reason `kiroku-metrics` takes a PVP major bump. No other child adds a configuration field: EP-3
keeps browse limits on `StoreBrowser`, and EP-6 maps its command-line options onto existing
fields. There is no new bind option in this cohort; the executable documents the starter's
actual bind behavior and trusted-network requirements.

**Version numbers, bounds, and changelogs** (owner: EP-7, plan 96; constraint on every other
child). No child edits a `.cabal` `version:` line or a dependency bound. Each child writes its
bullets under one `## Unreleased` heading at the top of the affected package changelog
(`kiroku-store/CHANGELOG.md` for EP-3, EP-4, and EP-5; `kiroku-metrics/CHANGELOG.md` for all
six), grouped as the release skill expects (`### Breaking Changes`, `### New Features`,
`### Other Changes`). Plans 87, 88, and 89 previously specified in-tree bumps to
`kiroku-store` 0.9.0.0 and `kiroku-metrics` 0.3.0.0 or 0.1.1.0; those numbers are stale
(`kiroku-store` 0.10.0.0 and `kiroku-metrics` 0.2.0.0 are already released as verified on 2026-10-10) and are withdrawn.
EP-7's forecast, to be re-derived from the diffs: `kiroku-store` 0.11.0.0 (the closed `Store`
GADT gains four constructors and the exported `Subscriber` record gains a field),
`kiroku-metrics` 0.3.0.0 (the configuration field, the record, new modules, a new executable,
and new library dependencies `network`, `effectful-core` and `optparse-applicative`), and patch bumps
of `kiroku-otel`, `kiroku-cli`, and `shibuya-kiroku-adapter` to move their `kiroku-store`
bound, plus `kiroku-metrics`'s `kiroku-cli` bound. `kiroku-store-migrations` is outside the
cohort: it does not depend on `kiroku-store` (the release skill's dependents list says
otherwise and is stale on that point; EP-7 corrects the skill in its release commit) and this
cohort adds no migration. Because in-tree packages resolve against their local versions, leaving
every version untouched until EP-7 keeps `cabal build all` satisfiable throughout.

**The publisher drop counter** (owner: EP-5, plan 94). Shared artifact:
`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`. The user guide and ADR-9 both
promise that a slow WebSocket client "is told in-band by an `error` frame" when it loses
batches, but the publisher sets the `Overflowed` status only under `DropSubscription`; under
`DropOldest`, the tail's policy, it drops silently. EP-5 adds `subDropped :: TVar Word64` to
`Subscriber`, incremented only inside the existing `DropOldest` branch of `deliverBatchSTM`, a
`subscribePublisherWith` returning a `PublisherSubscription` that exposes the counter, and keeps
`subscribePublisher` as a wrapper returning today's triple. The queue remains TBQueue DecodedBatch and retains the no-hook UnchangedBatch fast path.
Counter writes occur only on actual drops. EP-5 samples queue/counter/status together and
notifies BEFORE sending survivors; the client recovers from its last contiguous pre-notice
cursor. Name enrichment has one batched lookup at most and a 4096-entry per-tail FIFO cache.
The existing Shibuya benchmark alone does not cover that resolver: EP-5 adds focused
tail/cache checks, and EP-7 owns cumulative append-under-observer evidence.
No other child edits the publisher.

**The `kiroku-store` `Store` effect** (EP-3 and EP-4 both extend it; owner of each constructor
is the plan that adds it). Shared artifact: `kiroku-store/src/Kiroku/Store/Effect.hs`. EP-3 adds
`ListStreams`, `ListCategories`, and `GetEvent`; EP-4 adds `ListSubscriptionDeadLetters`. The
effect is a closed GADT compiled with `-Werror=incomplete-patterns`, so every exhaustive
interpreter in the repository must gain arms for both plans' constructors; whichever plan lands
second updates the mock interpreters the first added. Both plans keep their SQL off every hot
path and pin plan shapes in `kiroku-store/test/Test/PerformanceStructure.hs` (ADR-5).

**Shared documentation and knowledge surfaces** (every child). `docs/user/metrics.md` is the
normative published inventory under ADR-9; sections are appended in landing order and the
Contents list is kept in sync. `kiroku-metrics/example/Main.hs` gains one numbered step per
child in landing order, renumbering the transcript that "Try it" quotes.
`docs/capabilities/operational-http-endpoints.md` (CAP-17) gains interface modules and evidence
entries per child with a dated `docs/capabilities/log.md` entry and `just capabilities-validate`.
Each request in `docs/improvement-requests/` follows one lifecycle: `accepted` now (IR-8 and
IR-12 were moved to `accepted` by this MasterPlan on 2026-09-30; IR-9, IR-10, and IR-11 already
were), `in_progress` when its plan's first milestone starts, an "Implementation Evidence"
section when the code lands, and `completed` with `completedAt` only in EP-7 with release
evidence. Every status change advances `timestamp`, adds a dated `docs/improvement-requests/log.md`
entry, and passes the strict bundle validation (whose "missing profile-recommended field:
reviews" lines are benign).

**The standalone executable and discovery route** (owner: EP-6, plan 95). Shared artifacts:
`kiroku-metrics/kiroku-metrics.cabal` (a new always-buildable `executable kiroku-inspect` stanza
depending only on published packages, never `kiroku-test-support`, so `nix build .#kiroku-metrics`
keeps working; `optparse-applicative` joins the library's dependencies because the option parser
lives in `Kiroku.Metrics.Standalone` for testability, and `unix` is executable-only),
`Kiroku.Metrics.Standalone`, `Kiroku.Metrics.Capabilities`, and the `GET /capabilities` arm in
`httpAppWithProviders`. The route is served regardless of `enableJSON`, `enablePrometheus`, and
`enableWebSocket` (a route whose job is to say what is enabled cannot be gated by what it
reports), so no child may document those flags as gating every JSON route. It reports booleans
derived from the record and the configuration, never configuration values such as the origin
list, and never an absolute URL; its `process_local` list names the routes whose answers describe
only the answering process. The executable uses `storeServerProviders`, so a standalone process
answers `GET /subscriptions` with `200 []` rather than the configured 404, and its options map
onto existing configuration fields only: there is no bind-address option, because
`MetricsServerConfig` has no host field and `startMetricsServerWith'` hard-codes
`Warp.setHost "*"` (see the Decision Log).

**ADR distillation.** EP-1 recorded the CORS posture in
[ADR-16](../adr/0016-browser-inspection-access-is-explicit-and-default-off.md): default-off
explicit origins applied at the WAI layer to HTTP and WebSocket alike, with validated
authorities, cache variation and wildcard grants unrepresentable. Future composition preserves it. EP-6 writes the record for the
composition boundary: the server never holds the store, store-backed routes enter through the
additive `ServerProviders` record, the exported application is the prefix-mountable unit, and
the surface is self-hosting and self-describing. Plan 88's planned Milestone 4 ADR on browse
endpoints wrapping `Store` primitives is withdrawn as subsumed by ADR-9 section 3. EP-7's
distillation pass reviews every child's Decision Log and decides whether ADR-9 section 1 needs
an amendment listing the newly published routes and frames, or whether the guide-as-inventory
rule suffices.


## Progress

- [x] (2026-10-10) EP-3 selected-layout measurement: verify proof plus five fresh and five observer pairs, all 21 benchmark-grade trials, raw recomputation and lease/cell cleanup. Preserve adverse cost estimates and unresolved precision in the [report](../../bench/mp13-index/evidence/2026-10-10-byte-name/README.md); EP-3 remains In Progress for cost review, with cumulative release acceptance still owned by EP-7.

- [x] (2026-10-10) EP-3: implement a disposable shared-access prototype: one byte-ordered browse index, bounded category/literal-prefix pages, and namespace global windows using existing event indexes. All 224 TypeID/edge-case checks pass (176 browse, 48 namespace); retain preceding rejected plans/setup error and verify every owned cluster stopped.
- [ ] EP-3: settle the new browsing-order preference (byte order versus deployment locale), then select the final shared layout and validate its own write cost before migration. The prior replacement's cost is not acceptance of a different layout.

- [x] (2026-10-10) EP-3: correct sparse observer recording, preserve primary append grade requirements, compile the Linux payload and verify diagnostic schedule/grade/cost-bound checks.
- [x] (2026-10-10) EP-3: verify the corrected observer proof (47,734 benchmark-grade append samples, 61–62 steady samples per diagnostic browse page), raw recomputation and lease release.
- [x] (2026-10-10) EP-3: finish five corrected benchmark-grade observer pairs; throughput loss bounded at 1.821% and p99 increase at 2.214% (95% intervals). Raw recomputation, exact delivery, durable drain and cell cleanup passed; unchanged zero-slowdown verdict remains inconclusive.
- [x] (2026-10-10) EP-3: verify all ten fresh-stream trials and recompute raw metrics; five-pair append acceptance is inconclusive (throughput -0.677%, 95% interval -2.687% to +1.374%).
- [x] (2026-10-10) EP-3: prepare the same-payload index-layout comparison, TypeID catalog/fresh fixtures, active category browsing and stream HOT/WAL snapshots; compile the Linux payload and verify paired-input/deadline invariants.
- [x] (2026-10-10) EP-3: verify remote lifecycle proof and second category-only control, sealed hashes, stream counters and owned lease release.
- [x] (2026-10-10) EP-3: complete and retain 18 sealed trials inside the original deadline, release the lease and verify all four cell instances stopped. Fresh acceptance is inconclusive; six observer trials are exploratory, not benchmark-grade. Acceptance remains open.
- [x] (2026-10-10) EP-3: research Kenshou coverage and a disposable category/name index replacement; retain three completed 96-case runs, initial setup error, layout sizes and benchmark source/run inventory. No append-cost acceptance.
- [x] (2026-10-10) Reviewed the integrated design against current source; corrected API and performance hazards. This is planning work, not implementation evidence.
- [ ] Implement and execute the focused correctness and performance acceptance added by this review.

- [x] (2026-09-30) Coordination: MasterPlan created; plans 87, 88, 89, and 90 adopted with
      coordination notes and the stale version, record, and envelope decisions withdrawn;
      plans 94, 95, and 96 created; IR-8 and IR-12 moved to `accepted`.
- [x] (2026-10-10) EP-1: `Kiroku.Metrics.Cors`, the `cors` configuration field, the shared error envelope
      helpers, and database-free CORS tests.
- [x] (2026-10-10) EP-1: middleware wired at the composition point; real-server HTTP and WebSocket origin
      tests; documentation, example step, CAP-17, changelog, IR-11 evidence.
- [x] (2026-10-10) EP-2: `Kiroku.Metrics.Checkpoints` and the pure codec test.
- [x] (2026-10-10) EP-2: `ServerProviders`, the four general starters, the reserved `/subscription-checkpoints`
      segment, legacy starters as delegations.
- [x] (2026-10-10) EP-2: end-to-end checkpoint tests; documentation, example step, CAP-17, changelog, IR-10
      evidence.
- [x] (2026-10-10) EP-3: execute M0 existing-index prototype diagnostics; reject inventory-proportional prefix work and retain evidence.
- [x] (2026-10-10) EP-3: evaluate user-directed category-scoped stream browsing with existing indexes; retain category-size scaling and correctness evidence.
- [x] (2026-10-10) EP-3: evaluate name ranges with TypeID fixtures on existing indexes; retain 224 initial and 400 refined cases with verified cleanup and rejected promotion.
- [ ] EP-3: resolve ordered paging within large categories and arbitrary prefix filtering before promoting browse SQL.
- [ ] EP-3: `listStreams`, `listCategories`, `getEvent` in `kiroku-store` with database, mock,
      and structural tests.
- [ ] EP-3: `Kiroku.Metrics.Browse`, `recordedEventToJSONResolved`, the `browser` field and
      route arms, mock and end-to-end tests.
- [ ] EP-3: documentation, example step, CAP-17, changelog, IR-8 evidence.
- [ ] EP-4: `subscriptionDeadLetters` in `kiroku-store` with database, mock, and structural
      tests.
- [ ] EP-4: `Kiroku.Metrics.DeadLetters`, the `deadLetters` field and route arm, scripted and
      end-to-end tests.
- [ ] EP-4: documentation, example step, CAP-17, changelog, IR-9 evidence.
- [ ] EP-5: the publisher drop counter in `kiroku-store` with a deterministic test and the
      overhead benchmark recorded before and after.
- [ ] EP-5: additive frames (`unsubscribe_metrics`, `error.code`, `original_stream_name`, the
      now-reachable `event_stream_overflowed` error) with tests proving existing frames
      byte-identical.
- [ ] EP-5: conformance mapping in the guide, CAP-17, changelog, IR-12 evidence.
- [ ] EP-6: `GET /capabilities` with pinned codec and real-server tests.
- [ ] EP-6: `kiroku-inspect` executable with option, environment, and end-to-end tests;
      `nix build .#kiroku-metrics` green.
- [ ] EP-6: `docs/guides/building-an-inspection-ui.md`, guide sections, CAP-17, changelog, the
      composition-boundary ADR.
- [ ] EP-7: release truth established and approved; cohort prepared and verified through the
      ADR-5 gates.
- [ ] EP-7: cohort published, clean-consumer proof recorded, IR-8 through IR-12 `completed`.
- [ ] EP-7: ADR distillation across all children; MasterPlan Outcomes written.


## Surprises & Discoveries

- 2026-10-10 shared-access prototype: one partial C-collated name index can
  serve global names, literal prefixes, exact categories and category-plus-prefix
  pages without also installing the category/name replacement. Keep the original
  unique-name constraint and small category index. Bound the ordered lower seek
  before testing the upper range: generic plans otherwise chose a bitmap scan
  and sort. Namespace reads can use migration 0012's denormalized event category
  and the existing global-position index, with bounded scan progress rather than
  per-stream probes. This requires new internal worker progress semantics; it is
  not implemented by this SQL diagnostic. See
  [shared-access research](../../kiroku-store/bench/results/mp13-ep3-shared-access/README.md).
  New API byte order remains a product choice, not an imposed database collation.

- 2026-10-10 corrected observer completion: all ten comparison trials are
  benchmark-grade. Throughput change -0.466% (95% interval -1.821% to +0.908%),
  append p99 -0.013% (-2.192% to +2.214%). First/absent diagnostic browse medians
  fall from 4.411/7.987 ms to 0.270/0.231 ms; late pages rise 0.369 to 0.389 ms.
  Global WAL/event rises 0.959% descriptively. Exact category delivery, durable
  drain, raw recomputation and two stream updates per event passed. All five
  pairs retained without replacements; lease released and all four instances
  verified stopped within the single budget. See the
  [corrected report](../../bench/mp13-index/evidence/2026-10-10-corrected-observer/README.md).
  This valid cost evidence meets the declared precision target; zero-slowdown
  acceptance remains inconclusive because intervals include both signs.

- 2026-10-10 corrected observer preparation: Kenshou grades each registered
  operation. Sparse browse timings now live in raw summary diagnostics, while
  the primary recorder contains only appends. Query shapes, 1 Hz browse load,
  subscriber, database durability and append minimum samples are unchanged.
  Scenario revision 5 identifies this measurement correction; old revision 4
  artifacts remain immutable. Linux compilation and controller checks passed.
- 2026-10-10 observer-grade failure: all six observer runs sealed, but 1 Hz
  browsing produced 185–186 samples per run, below the 1,000-sample operation
  minimum. The whole-run grade is exploratory. The controller caught this only
  after the queue; an early progress-audit grade check now prevents recurrence.
  All raw summaries were recomputed and all original pairs retained, without
  reruns, relaxed policy or acceptance. Diagnostic browse p50 fell 92.31%;
  combined append throughput was +2.326% (95% interval -0.900% to +5.656%).
  Exact delivery, durable drain, counters and sealed hashes passed. The lease
  is released and all four cell instances are stopped. See the
  [matched result](../../bench/mp13-index/evidence/2026-10-10/README.md).
- 2026-10-10 fresh comparison: throughput point estimate is -0.677%, with a
  95% interval from -2.687% to +1.374%; all four append metrics are inconclusive.
  Global WAL/event rose 2.43% descriptively; stream HOT fractions stayed
  98.703% / 98.698%. Incrementally populated fixture stream-index bytes rose
  79.06%, beyond the earlier compact-layout 53.7% result. Footprint does not
  translate directly into write latency. Observer results are retained in the matched experiment report.
- 2026-10-10 remote checkpoint: UUIDv4 plan IDs were rejected before execution;
  corrected to UUIDv7 and retained the rejection. Missing `zstd` publication
  tooling was supplied by the established pinned shell. The corrected proof
  and second control verified. The proof's 41,830 inserts/updates included
  41,280 HOT updates. Actual journals took 151.7s/132.2s per control, so the
  original two five-pair queues no longer fit the remaining hour. Before
  second-case submission, retain five fresh pairs and choose three observer
  diagnostic pairs. Its unchanged five-pair acceptance remains inconclusive;
  no deadline or policy was reset.
- 2026-10-10 matched harness preparation: Kenshou's `cell pair` shortcut varies
  payload identities, not knobs. The dedicated controller submits explicit AB/BA
  specs through the same executable and compares only `mp13.index-layout`. The
  default MP12 workload leaves layout unchanged. Linux compilation passed; the
  exploratory Darwin package compiled but failed its GHC runtime-closure check,
  so this dedicated payload advertises Linux only. No write-cost result is inferred.
  See [the bounded protocol](../../bench/mp13-index/README.md).
- 2026-10-10 index research: replacing the category-only index with
  `(category, stream_name)` in disposable databases gave correct results within
  the existing budget in all 48 replacement cases across C/ICU and generic/custom
  plans, including category enumeration. At 40,007 streams its compact footprint
  was 2,672 KiB versus 288 KiB; total stream-index bytes rose 53.7%. Current
  subscriptions use a separate unchanged `stream_events` index. Writer/cache
  effects remain unmeasured, as do this candidate's optional prefix filters.
  Kenshou's local historical runs use store 0.8.0.1; reuse the dedicated matched
  workload, not that historical control. Stream HOT counters and realistic fresh
  TypeID fixtures are missing from the existing payload. See the
  [index/benchmark research](../../kiroku-store/bench/results/mp13-ep3-index-research/README.md).

- 2026-10-10 EP-3 range follow-up: ordinary TypeID category pages can use the
  name index for eleven examined rows, but generated-category generic plans can
  still scan 20,007 rows and codepoint prefix bounds omit valid ICU matches.
  The refined 400-case run was correct in all 200 C cases and 168 ICU cases;
  earlier 224 cases are also retained. See the
  [range evidence](../../kiroku-store/bench/results/mp13-ep3-range/README.md).
  Both owned servers stopped; no index or production SQL was added. Stream
  indexes can affect event appends through new-stream inserts and non-HOT
  version updates. The proposed index's write cost remains unmeasured.

- 2026-10-10 EP-3 category follow-up: the existing category index is useful.
  Materializing category filters before sorting avoided unrelated-inventory
  scaling in the tested fixtures, but an eleven-row page examined all 20,001
  streams in a large selected category. All 192 diagnostic cases were correct;
  bounded page work remains unproved. The user's usual UI workflow is category
  browsing; arbitrary prefix search remains valid. No new index is added.
  [Category evidence](../../kiroku-store/bench/results/mp13-ep3-category/README.md)
  records query plans, exact inputs and cleanup. EP-3 remains In Progress.

- 2026-10-10 EP-3 implementation: M0 rejects the stream-prefix SQL prototype.
  Generic absent-prefix plans examine 20,003 rows for an eleven-row limit;
  mandatory cursors still examine 19,502 rows. ICU custom plans also scan.
  Category mandatory-cursor variants solve their seek problem, but not prefix
  filtering. [Retained evidence](../../kiroku-store/bench/results/mp13-ep3-prefix/README.md)
  records the two local runs, exact inputs, plans and stopped owned clusters.
  EP-3 remains In Progress awaiting a reviewed prefix design; consequently
  EP-5, EP-6 and EP-7 remain blocked on it. EP-4 is independently eligible.

- 2026-10-10 EP-2 implementation: one provider composition now preserves CORS,
  mount-relative HTTP/WebSocket dispatch and the disabled WebSocket gate. All
  legacy signatures compile. Store-backed starters wire durable reads while
  retaining the published live configured-404; new all-provider hosts opt in.
  `network` is declared directly for ephemeral socket finalizers. Bracketed
  callbacks run in a supervised thread; ADR-15 records that lifecycle constraint.

- 2026-10-10 EP-1 implementation: Default-off CORS and shared sanitized JSON errors
  are available. `CorsPolicy` remains the planned record; application construction
  captures its Set once, and disabled construction returns the original app.
  Later provider-based composition must preserve the outer wrap.
- 2026-10-10 EP-1 validation: `http-types` exports differ between the Cabal and Nix
  closures; typed header literals keep both builds working. Strict request metadata
  required recorded reviews on eleven existing documents; metadata-only `comments`
  reviews repair authoring validation without technical acceptance claims.

- 2026-10-10 review: Hackage and upstream tags already contain store 0.10.0.0 and metrics
  0.2.0.0. The new tentative targets are 0.11.0.0 / 0.3.0.0, re-derived at release.
  Current queues carry DecodedBatch and checkpoint seeding takes six parameters.
  LIMIT did not establish bounded SQL work, and unchanged append SQL did not establish
  observer neutrality. No runtime result was produced by this documentation review.

- Adoption audit (2026-09-30): plans 87, 88, and 89 all target an in-tree `kiroku-store` bump
  to 0.9.0.0 and `kiroku-metrics` bumps to 0.3.0.0 or 0.1.1.0, but `kiroku-store` 0.9.0.0 and
  0.9.0.1 shipped on 2026-09-25 (migration `0012`, the category index, and the idle-publisher
  retention fix) and `kiroku-metrics` is at 0.1.0.10. The next `kiroku-store` major is
  0.11.0.0, and the numbers are now assigned only by EP-7.
- Adoption audit (2026-09-30): plans 87 and 88 designed incompatible providers records
  (`MetricsProviders`, a breaking positional replacement, versus `ServerProviders`, an additive
  record beside the legacy starters) and plan 89 wrote a precedence rule to cope. With the
  cohort already major because of EP-1's configuration field, breaking versus additive no
  longer decides anything, so the additive record that carries the WebSocket app won on API
  merit; see the Decision Log.
- Adoption audit (2026-09-30): IR-12's candidate gap "idle-connection server pings may not
  run on both paths" is not a gap. Both `handleMetrics` and `handleEvents` in
  `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` run `WS.withPingThread conn 30 (pure ())`.
  The real gaps are the metrics channel's push-on-connect without a subscribe frame, the lack
  of a stable `code` on `error` frames, and, for an independent UI, the absence of any way to
  resolve `originalStreamId` from a frame; EP-5 addresses all three additively.
- Adoption audit (2026-09-30): plan 88 exposes `GET /streams/<name>` by name only, and no plan
  exposes a lookup by surrogate stream id, so a WebSocket-only client could never name the
  stream an `event` frame came from. Enriching the frame server-side (EP-5) was preferred
  over a new by-id route because plan 88 already anticipated one flat event decoder for REST
  items and frames.
- Adoption audit (2026-09-30): `kiroku-metrics` depends on `kiroku-cli` for the shared
  `SubscriptionStatusRow` codec, so a `kiroku serve` subcommand in `kiroku-cli` would create a
  dependency cycle. The standalone server therefore lives in `kiroku-metrics` as
  `kiroku-inspect`.
- Drafting plan 94 (2026-09-30): the in-band overflow `error` frame that `docs/user/metrics.md`
  documents and ADR-9 lists among the published delivery semantics is never emitted.
  `broadcastLoop` in `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` sends it only on the
  `Overflowed` status, which `deliverBatchSTM` in
  `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` sets only under
  `DropSubscription`; the tail subscribes with `DropOldest`, whose branch drops the oldest batch
  and leaves the status `Active` (verified against source). EP-5 therefore changes
  `kiroku-store` after all, with a drop counter on the subscriber; the MasterPlan's first draft
  had called EP-5 metrics-only.
- Drafting plan 95 (2026-09-30): the server always binds every interface (`Warp.setHost "*"`)
  and `MetricsServerConfig` has no host field, while the user guide tells operators to bind an
  internal interface. No child can express a bind address without a shared configuration
  change; recorded as a deliberate exclusion below.
- Drafting plan 96 (2026-09-30): `agents/skills/release/SKILL.md` lists
  `kiroku-store-migrations` as a dependent of `kiroku-store`, but its `.cabal` depends only on the
  `pg-migrate` family. The migrations package is outside this cohort, which adds no migration.


## Decision Log

- Decision (2026-10-10 approved continuation): pursue one shared physical design
  after the user's approval of the measured replacement trade-off. Test a
  byte-ordered name index as an alternative, with no separate namespace index.
  Do not transfer the previous layout's confidence bounds to this new layout or
  invent a new regression allowance. Keep its production migration unselected
  with user-approved UTF-8 byte ordering for new stream pages. Existing published reads,
  unique-name identity, database collation and event ordering remain unchanged.
  The namespace window strategy trades sparse historical catch-up throughput
  for bounded per-fetch work and no additional writer index. It needs distinct
  scan progress and successful-disposition checkpoint tests before worker use.

- Decision (2026-10-10 user-authorized follow-up): rerun only the broken
  observer case. Use one corrected observer proof followed by five matched
  pairs, retaining the valid fresh-write evidence and earlier calibration.
  Separate sparse browser diagnostics from primary append grading; never
  weaken the primary sample/health rules. Emit percent cost estimates and
  confidence bounds independently of the unchanged zero-slowdown verdict.
  This is a distinct experiment with one new 60-minute build-to-cleanup
  deadline, estimated 35–40 minutes including overhead, no extra repeats.
  Verify the proof grade/raw summaries/lease before queue expansion.
- Decision (2026-10-10 measured evidence): retain the replacement candidate,
  without production promotion. Fresh five-pair acceptance is inconclusive,
  and observer evidence is exploratory and below the minimum pair count.
  Faster diagnostic category browsing does not override those gates or settle
  general prefix/namespace access. Preserve every sample and the original
  grade rejection; fix early grade detection rather than rerun under a weaker
  policy. ADR-15 continues to govern the shared plan 54 design and cumulative
  original-control cost. No new durable architecture was selected.
- Decision (2026-10-10 matched comparison): keep both arms on the same current
  source and payload. Select fresh appends without observers, then existing
  appends with one category subscriber and one browse cycle per second, over
  20K streams per category. Declare 10/61/10-second phases, five interleaved
  pairs per case and the existing zero-slowdown policy before measurement. A
  small proof/calibration precedes expansion; its size does not prove statistical
  resolution. One persisted hour covers build, setup, recovery and verification.
  Stop rather than silently reduce coverage, weaken policy or replace failed runs.
- Decision (2026-10-10 research): retain the category/name replacement as a
  candidate, not a selected migration or complete browse access design. Reuse
  the existing matched append/subscriber harness with current-source arms that
  differ only by recorded layout. Measure stream HOT/update behavior and fresh
  inserts; benchmark placement/grade and historical hardening acceptance do not
  establish this index's write cost. Report whole-experiment scope and runtime
  before remote execution; no remote queue or lease was started. ADR-15 remains
  authoritative for plan 54 coordination and cumulative original-control cost.

- Decision (2026-10-10 range follow-up): hold EP-3 after the name-range
  experiment. Useful ordinary TypeID seeks do not override ICU correctness
  failures or broad planner work. Coordinate any physical-design proposal with
  plan 54 under ADR-15 and measure cumulative append cost; stream-version
  updates mean an index is not automatically free for event creation. The
  current investigation adds no index and completes no production milestone.

- Decision (2026-10-10 user clarification): coordinate EP-3's physical access design
  with [plan 54](../plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md).
  Avoid redundant indexes and assess any necessary structures together against one original
  append control, including combined active browsing/subscription load. Neither feature has
  an independent additive regression allowance. ADR-15 records this shared constraint.
  Rationale: the user is concerned about paying ongoing writer overhead twice, not only
  duplicating measurement work. This is a design coordination requirement, not adoption of
  plan 54 as a child or an implementation dependency. The current no-new-index direction holds.

- Decision (2026-10-10 user-directed follow-up): prioritize category-scoped
  browsing investigation with existing indexes, preserving arbitrary prefix
  search as a UI requirement. Do not treat this as a migration authorization or
  silently accept category-sized work as page-bounded work.
  Rationale: the category column and index already express the usual browsing
  workflow. Its measured sort/filter cost still needs resolution; current API
  and dependency contracts remain unchanged until a design is selected.

- Decision (2026-10-10 EP-3): retain EP-3 as In Progress and hold its production
  milestones after the measured prefix promotion failure. EP-5, EP-6 and EP-7
  retain their hard dependency on completed EP-3; EP-4 remains independent.
  Rationale: shipping inventory-proportional observer work or silently adding a
  write-cost-bearing index would bypass the reviewed constraints. ADR-15 already
  governs the required prefix read/write redesign; no new ADR is needed for this
  task-local rejection.

- Decision (2026-10-10): use the hard-dependency graph above, single owners for shared helpers,
  the nonshadowing checkpoint route, typed decoding, bounded tail state and proportional
  original-control performance gates. These supersede conflicting September decisions.
  Rationale: source review found mismatched SQL arguments, obsolete queue/decode APIs,
  full-history read risks, cache growth, late loss notices and a bind readiness race.
  Durable constraints are recorded in ADR-15; all implementation statuses remain Not Started.

- Decision: Adopt plans 87, 88, 89, and 90 as children of this MasterPlan rather than
  rewriting them, adding `master_plan` to their frontmatter, a coordination note, targeted
  edits of the withdrawn decisions, and a revision note each; they keep their own Intentions.
  Rationale: Each is a complete, reviewed, self-contained specification of one request. The
  conflicts between them are confined to a few shared artifacts that a MasterPlan exists to
  settle; rewriting them would risk introducing new inconsistencies and would lose their
  decision history. Their Intentions predate this initiative and remain truthful records of
  why each was started.
  Date: 2026-09-30

- Decision: The composition record is `ServerProviders` with the WebSocket app and four
  optional providers, introduced by EP-2 (plan 87) with the four general `...WithProviders`
  functions, every legacy starter kept as a delegation, and later plans adding fields only.
  Rationale: Plan 88's additive design carries the WebSocket app in the record, which makes
  one starter and one application function sufficient for every deployment, including EP-6's
  executable and keiro's composed mount; plan 87's `MetricsProviders` left the WebSocket app
  positional and forced another signature change per route family. The cohort is a PVP major
  regardless because of EP-1's configuration field, so additivity is chosen for API quality,
  not for versioning. EP-2 owns it because it is the smallest route plan and lands before the
  two larger ones.
  Date: 2026-09-30

- Decision: One error envelope helper pair, `errorEnvelope`/`errorResponse` with a `Maybe Value`
  details argument, created by EP-1 (plan 90) because it lands first, reused by every other
  child.
  Rationale: Three plans specified three shapes. The details-carrying shape is the superset
  the conventions describe, and a fixed owner removes the "whoever lands first" ambiguity that
  otherwise leaves the decision to whichever session starts on a given day.
  Date: 2026-09-30

- Decision: Land EP-1 (CORS) first, before the route plans.
  Rationale: It is the enabling request for every browser consumer, it touches only the
  configuration record and the single composition point, and landing it first means every
  later route inherits the middleware and its tests never need a CORS retrofit. Its
  configuration-field change also fixes the cohort's PVP outcome early, which simplifies every
  other child's versioning story to "no bump here".
  Date: 2026-09-30

- Decision: Defer every version number and dependency bound to EP-7 and let children write
  only `## Unreleased` changelog bullets.
  Rationale: Plans 87, 88, and 89 each forecast numbers that were stale within three weeks.
  Plan 85 established the pattern of a release child that re-queries Hackage and tags at
  execution time, and in-tree packages build against local versions, so nothing is lost by
  waiting.
  Date: 2026-09-30

- Decision: Add `original_stream_name` to WebSocket `event` frames (EP-5) with the encoder
  owned by EP-3 and shared with REST items.
  Rationale: The independent-UI requirement means a client may have only WebSocket frames and
  the REST routes in this package; neither offers a lookup by surrogate stream id, and ADR-1
  deliberately keeps names off `RecordedEvent`. Server-side resolution on the transient
  watcher path, cached per connection, costs one batched lookup per new stream id and touches
  no subscription hot path. ADR-9 permits the optional snake_case key on the frozen camelCase
  object.
  Date: 2026-09-30

- Decision: Put the standalone server in `kiroku-metrics` as the executable `kiroku-inspect`,
  and the discovery route at `GET /capabilities`, both in EP-6 after every route family has
  landed.
  Rationale: A `kiroku-cli` subcommand would be a dependency cycle. A discovery route written
  before the record is final would need editing by every later route plan; written after, it
  observes the finished record once. The executable is what makes "an independent Kiroku UI
  for store-only adopters" true in practice: without it, a team must write a Haskell host
  program to see the surface at all.
  Date: 2026-09-30

- Decision: `startMetricsServerWithStore` gains every store-backed provider that lands but not
  the live `subscriptionStatus` provider; `storeServerProviders` wires all five.
  Rationale: Plans 87 and 88 both decided this and IR-8 acceptance 7 and IR-10 acceptance 6
  require pre-existing endpoints unchanged; flipping `GET /subscriptions` from its published
  404 to 200 on an existing starter would change a shipped route's behaviour without the host
  opting in. New hosts and EP-6's executable use `storeServerProviders` and get everything.
  Date: 2026-09-30

- Decision: Withdraw plan 88's Milestone 4 ADR; assign the composition-boundary ADR to EP-6
  and the CORS-posture ADR decision to EP-1's distillation pass.
  Rationale: ADR-9, written after plan 88, already records that sister-package endpoints wrap
  `Store` primitives and follow the conventions, so plan 88's record would duplicate it. The
  providers record, the prefix-mountable application, and self-hosting are one coherent
  boundary that is only fully observable once EP-6 has consumed the finished record.
  Date: 2026-09-30

- Decision: IR-8 and IR-12 move to `accepted` now, citing their plans and this MasterPlan.
  Rationale: IR-9, IR-10, and IR-11 were accepted when their plans were written; IR-8's log
  entry left it `proposed` "until implementation lands", which is not the lifecycle the sibling
  requests follow. With every open request now planned under one initiative, the five records
  should read alike.
  Date: 2026-09-30

- Decision: EP-5 fixes the unreachable overflow signal in `kiroku-store` with a per-subscriber
  drop counter rather than documenting it as a deviation.
  Rationale: The conventions require overflow to be signalled in-band, ADR-9 already lists the
  signal as published, and the user guide has promised it since the package shipped; recording
  "never sent" would document a defect the cohort could fix. The increment sits inside the
  existing drop branch, so the per-batch delivery path gains no work, and the cohort's
  `kiroku-store` release is a major regardless. EP-5 owns the file and runs the overhead
  benchmark as its ADR-5 evidence.
  Date: 2026-09-30

- Decision: No bind-address option ships in this cohort; `kiroku-inspect` documents that the
  server binds every interface, and the guide keeps the trusted-network or
  authenticating-proxy posture. A `host` field on `MetricsServerConfig` is recorded as a
  candidate follow-up request, to be filed under `docs/improvement-requests/` if an adopter
  needs it, and would ship in a later major.
  Rationale: The gap predates this initiative and belongs to the shared configuration record,
  which EP-1 already changes once for CORS; adding a second field mid-cohort would couple every
  sibling that constructs the record to a change none of them needs, and the reverse-proxy
  deployment the conventions document already covers the internal-interface case.
  Date: 2026-09-30

- Decision: `GET /capabilities` is served regardless of the `enable*` flags.
  Rationale: A discovery route gated by the flags it reports would leave a client unable to
  distinguish "JSON disabled" from "not this package"; the route reports the flags instead.
  Date: 2026-09-30

- Decision: Serving static UI assets from `kiroku-metrics` is a deliberate exclusion.
  Rationale: Both UIs are static applications that any web server can host, EP-1's CORS hook
  and the documented reverse-proxy alternative cover the cross-origin case, and bundling
  assets would couple a Haskell package release to a JavaScript build. If a future request
  asks for it, it is a new route family under ADR-9, not a change to anything here.
  Date: 2026-09-30


## Outcomes & Retrospective

2026-10-10 shared design continuation: a concrete disposable query prototype
passes all 224 TypeID/edge-case checks for category-plus-literal-prefix browsing
and bounded namespace windows. Browse work is at most 12 rows / 12 buffers;
namespace work is at most 38 rows / 9 buffers. Owned clusters stopped.
The retained research distinguishes successful read evidence from migration,
worker and write-cost acceptance. The user accepted UTF-8 byte ordering for new stream pages;
no durable architecture or production index is selected. ADR-15 already governs
this shared review, so the distillation pass creates no new ADR yet.

2026-10-10 corrected observer completion: proof plus ten comparison trials are
benchmark-grade, raw metrics recompute and exact durable delivery passes.
Throughput loss is bounded at 1.821% and append p99 increase at 2.214% with 95%
intervals for this fixture. The zero-slowdown verdict remains inconclusive; no
cost allowance or production migration is selected. Cleanup is verified.
Shared literal-prefix/namespace design remains open. ADR distillation finds no
new architecture; ADR-15 already covers the coordination constraint.

2026-10-10 corrected observer preparation: benchmark-only correction compiled
and input, schedule, grade and cost-bound checks passed. The corrected proof
passed benchmark grade and raw recomputation, with realistic diagnostic page
coverage and released lease. All five matched pairs are now complete and
benchmark-grade. No production migration or browse milestone is promoted;
shared prefix/namespace design remains open under ADR-15.

2026-10-10 matched experiment completion: all 18 trials sealed; workload and
artifact checks completed, owned lease released and all four instances stopped
within the original hour. Fresh throughput estimate is -0.677% with an interval
from -2.687% to +1.374%; fresh append acceptance remains inconclusive. Observer
results are exploratory because the low-rate browse operation failed the sample
grade minimum, in addition to the three-pair acceptance limit. Retain every
sample, rejection and raw recomputation; an early grade guard prevents repeating
this queue mistake. EP-3 remains In Progress; no production migration or browse
route was promoted. ADR distillation found no new selected architecture. See
the [full report](../../bench/mp13-index/evidence/2026-10-10/README.md).
2026-10-10 matched harness checkpoint: benchmark-only preparation is complete
and Linux compilation passed. Paired-input and persistent-deadline checks passed;
remote proof and measured write cost remain pending. No production migration or
browse milestone is promoted. ADR-15 already governs this focused experiment.
2026-10-10 index research: completed the authorized source/benchmark research
and local footprint/read diagnosis. Three 96-case runs, the zero-case setup error
and the unchanged prefix regression result are retained, with all five owned
clusters stopped. The replacement bounded the tested category pages/enumeration
while increasing index footprint;
event-append and active-observer cost remain unmeasured. EP-3 remains In Progress
because general prefix access and complete promotion evidence are unresolved.
No production index, route or primitive was added. The research report records
the smallest useful matched comparison and its missing instrumentation; no
remote benchmark was launched. ADR distillation found no new durable decision.

2026-10-10 range follow-up: completed the authorized existing-index range
experiment and retained both runs. EP-3 remains In Progress because correctness
under ICU and bounded planner work are unresolved. The useful TypeID cases do
not authorize a naming restriction, collation change, new index or relaxed gate.
Plan 54 still shares the physical-design and cumulative write-cost review; no
append-cost acceptance is claimed. The dependency graph is unchanged.

2026-10-10 category follow-up: the requested no-new-index experiment is complete.
Category equality helps, while sorted/prefix-filtered pages still scale with
selected-category size. Correct results and server cleanup are verified; no
production browse milestone or performance acceptance is claimed. EP-3 remains
In Progress and arbitrary prefix search remains in scope. The two completed
children and the dependency graph are unchanged.

2026-10-10 EP-3 stopping point: two of seven children remain Complete. EP-3 is
In Progress with its required SQL promotion gate rejected, not performance
accepted. No core browse primitive or route was installed. The no-migration,
literal-prefix and database-collation constraints need a reviewed design before
implementation continues; ADR-15 already governs this stop. EP-4 remains
independently eligible. Publication and cumulative observer evidence remain
outstanding with EP-7.

2026-10-10 EP-2 implementation: two of seven children are now Complete. The durable
inventory, compatible provider composition, readiness and supervised cleanup are
implemented, with 19 new metrics cases. All six repository suites passed (593 examples);
the eight-step example, Cabal/Nix builds and strict bundle checks passed. ADR-15
captures the finalizer/supervision constraints. IR-10 stays `in_progress`; EP-7 still
owns publication and cumulative append-under-observer performance acceptance.
The next ready child is EP-3 (plan 88, streams/categories/events browsing); EP-4
is also unblocked but follows EP-3 in registry order.


2026-10-10 implementation: EP-1 is complete (one of seven children). Validated CORS,
shared structured/sanitized errors, real HTTP/WebSocket tests, the guide/example and
ADR-16 are committed. Six test suites passed (574 examples); final metrics checks,
Nix build and strict bundle validation passed. IR-11 remains `in_progress` until the
cohort ships. Local middleware evidence is in plan 90; cumulative performance,
release evidence and the other six child implementations remain outstanding.
EP-2 (plan 87) is now the next ready child.


2026-10-10 review validation: `git diff --check`, local Markdown-link/fence checks across
all 11 changed Markdown files, `just adr-validate`, and strict profiled/log-enforced ADR
validation passed (15 concepts). Mori reports an existing manifest/embedded-schema hash
warning while validating successfully; this review does not change that unrelated manifest.
No source implementation or runtime/performance test was run. Sparse-prefix SQL promotion
and the cumulative original-control comparison remain explicit implementation gates.

2026-10-10 review: implementation and performance acceptance remain pending. Static review does not prove zero runtime regression. Earlier planning-time observations and dated decisions are historical where this revision explicitly replaces them.

(To be filled during and after implementation.)


## API and performance review revision (2026-10-10)

Reviewed against repository HEAD `f1a0209` and the released typed-decoding implementation. Corrected integration contracts and made focused performance evidence a completion gate. Existing authorship history is preserved; this revision records no implemented milestone or accepted performance result. The active requirements above supersede incompatible September design decisions, not published wire contracts.

## Implementation revision (2026-10-10)

EP-1 and EP-2 are Complete; their focused correctness, affected-path, build and
documentation evidence is in plans 90 and 87. ADR-16 captures CORS, and ADR-15
records supervised callback/server cleanup. EP-3 is next. No cohort release or
cumulative append performance acceptance is claimed.

## EP-3 SQL promotion implementation revision (2026-10-10)

Started EP-3 and retained the failing M0 evidence. Its registry status is
In Progress. The prototype was held as required; no production API, index,
migration or version change was made. A reviewed prefix redesign is the next
EP-3 step. No performance gate was weakened.

## Category-first investigation revision (2026-10-10)

Recorded the user-directed existing-index experiment and its category-sized
work limitation. Category browsing is the priority workflow, arbitrary prefix
search remains required, and the original promotion gate remains in force.


## Shared access-cost clarification (2026-10-10)

Recorded the user's requirement to coordinate browsing and prefix-subscription physical
access and cumulative writer cost under ADR-15. No index or implementation milestone is
approved. Plan 88 also records the application's TypeID naming convention and its limits.


## Name-range prototype revision (2026-10-10)

EP-3 remains In Progress after 624 retained range cases. Ordinary TypeID pages can
seek cheaply, but ICU membership and planner-work failures prevent promotion. No
index or cumulative append acceptance is claimed; plan 54 coordination still applies.


## Index and benchmark research revision (2026-10-10)

Recorded disposable replacement footprint/read evidence and verified cleanup,
Kenshou source/run coverage, matched-harness instrumentation gaps, and the
unchanged shared access/cumulative write-cost obligation. No migration or
performance acceptance is selected; production milestones remain open.


## Matched index harness revision (2026-10-10)

Prepared a current-source, same-payload index comparison with TypeID fixtures,
stream HOT/WAL observations and active category browsing. Recorded the selected
small protocol, unchanged comparison policy and persistent whole-experiment budget.
Linux compilation and controller input invariants passed; remote evidence is pending.


## Remote proof and coverage revision (2026-10-10)

Recorded verified lifecycle/counter/cleanup evidence, preserved setup failures,
and reduced only the second-case sample count before its submission because
measured reset overhead exceeded the initial estimate. Policy and deadline
remain unchanged; paired cost evidence is still running.


## Matched experiment completion revision (2026-10-10)

Recorded completed samples, fresh uncertainty/WAL cost, the observer grade failure,
explicit diagnostic recovery, early guard correction and verified cell cleanup.
The original policy and hour were preserved; no performance acceptance or
production migration is claimed. General prefix and shared namespace access remain open.


## Corrected observer experiment revision (2026-10-10)

Prepared independent sparse browse diagnostics and an observer-only controller
path with a corrected proof, five pairs and explicit cost estimates. Preserved
all earlier evidence, primary grading requirements and the zero-slowdown policy.


## Corrected observer completion revision (2026-10-10)

Recorded all five valid observer pairs, append cost bounds, diagnostic per-page
browse timings, descriptive WAL/HOT observations and verified cleanup. Retained
raw recomputation and sealed evidence. No favorable retries, policy relaxation,
production promotion or new ADR decision; prefix/namespace design remains open.


## Shared access prototype revision (2026-10-10)

Implemented a bounded disposable probe for one byte-ordered name index and
namespace windows over the current denormalized global log. Retained generic-plan
failures, fixture repair and successful follow-up evidence. Recorded the pending
new-API ordering choice and kept migration, worker and final-layout cost gates open.

## Approved stream ordering revision (2026-10-10)

The user accepted stable UTF-8 byte order for new stream browsing.
[ADR-17](../adr/0017-stream-browsing-uses-byte-order-and-one-shared-name-index.md)
selects one partial C-collated name index for category and literal-prefix pages,
keeping existing unique name and category indexes. No separate category/name
index or namespace event index is selected. Plan 88 now implements this design
for isolated correctness and cost verification. Plan 54's future bounded global
windows reuse existing event indexes and require independent scanned-frontier
tracking; its worker and semantic decision remain unfinished. Final-layout cost
and cumulative release acceptance remain open.

## EP-3 functional implementation checkpoint (2026-10-10)

EP-3 now has supported bounded Store browsing reads, migration 0015 and mounted
HTTP routes. Serial validation passes 434 store, 24 migration and 68 metrics
examples, including production prepared plans in C and English ICU databases.
ADR/capability/request validation passes. The example and final-layout remote
cost comparison are next; EP-3 stays In Progress and publication stays with EP-7.


## EP-3 selected-layout cost evidence revision (2026-10-10)

The supported browsing API and nine-step example pass, and the final physical
layout now has its own matched original-control evidence: 21 verified trials,
including proof and five pairs each for fresh-stream writes and existing-stream
writes with a category subscriber and SQL browsing. All sealed hashes, raw
recomputation, counters, durable drain and exact delivery checks pass. The same
pre-build clock was explicitly extended to 75 minutes; cleanup verified all four
cell instances stopped and no lease at 59.32 minutes. Retained setup/reporting
recoveries did not replace any measured sample.

Actual throughput change is -2.980% [-6.128%, +0.274%] for fresh streams and
-1.722% [-4.631%, +1.276%] for the observer workload. Fresh p99 is +3.700%
[-3.814%, +11.802%]; observer p99 +0.308% [-3.556%, +4.327%]. Most intervals
miss the frozen precision target; both zero-slowdown verdicts are inconclusive.
Fresh WAL/event rises 5.668%, observer WAL/event 0.187%; the shared index adds
3.180 MiB on 40,000 streams. Browse first/late/absent medians are
0.647/0.471/0.380 ms versus 15.020/4.968/16.414 ms originally.

See the [selected-layout report](../../bench/mp13-index/evidence/2026-10-10-byte-name/README.md)
for hashes, pair values and corrected ratio semantics. Functional implementation
is complete, but EP-3 remains In Progress for cost review; no performance gate
was relaxed. Keep the one shared index and original category/identity indexes.
Plan 54 remains independently unimplemented and receives no separate additive
write-cost allowance. EP-7 still owns cumulative inspection load and publication;
the registry and dependency graph remain unchanged.
