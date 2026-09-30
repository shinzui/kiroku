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
The whole cohort ships as one coordinated Hackage release (`kiroku-store` 0.10.0.0,
`kiroku-metrics` 0.2.0.0, and patch releases of the packages whose bounds move), proven from a
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
owner of the two artifacts every later route needs: the `ServerProviders` record through which
store-backed behaviour enters the server, and the structured error envelope helper. Making the
smallest plan the owner keeps the foundation reviewable and lets the two larger route plans
start from a settled server API.

Wave two is the routes and the protocol. EP-3 (plan 88, browse) and EP-4 (plan 89, dead
letters) each add library primitives to `kiroku-store` and a route family to `kiroku-metrics`;
they are independent of each other, both hard-depend on EP-2 for the record and envelope, and
can be implemented in parallel by different sessions. EP-5 (plan 94, WebSocket convergence) is
independent of the routes and can run at any time; its one shared artifact with EP-3, the
resolved-name event encoder, is an integration dependency resolved by the "whoever lands first
creates it" rule with the name and type fixed here.

Wave three is the independent-UI enablers and the release. EP-6 (plan 95) adds the standalone
executable, the discovery route, and the UI-builder guide; it hard-depends on the four route and
CORS plans because the executable serves the complete surface and the discovery route reports
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
project that owns the concept; store views are Kiroku's), `ADR-2` (the WebSocket convention and
its frozen-dialect rule), `ADR-3` (push is a hint, poll is truth), `ADR-4` (inspection surfaces
live in sister packages that export a bare WAI `Application`), `ADR-5` (no backend-for-frontend:
the UI consumes these endpoints directly, so the published version set is the contract), and
`ADR-7` (read-only first). The shared wire conventions are `mori://shinzui/keiro-ui`,
`docs/architecture/inspection-api-conventions.md` (artifact-level URI pending). Keiro's composed
mount, `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`, will mount this package's
exported application behind a path prefix, which constrains EP-2, EP-5, and EP-6 as recorded in
Integration Points.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Add configurable CORS support to kiroku-metrics (IR-11) | docs/plans/90-add-configurable-cors-support-to-kiroku-metrics.md | None | None | Not Started |
| 2 | Serve durable subscription checkpoints over HTTP (IR-10) | docs/plans/87-serve-durable-subscription-checkpoints-over-http.md | None | EP-1 | Not Started |
| 3 | Expose a REST read API for browsing streams, categories, and events (IR-8) | docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md | EP-2 | EP-4, EP-5 | Not Started |
| 4 | Expose a public dead-letter read API (IR-9) | docs/plans/89-expose-a-public-dead-letter-read-api.md | EP-2 | EP-3 | Not Started |
| 5 | Converge the kiroku-metrics WebSocket protocol with the cross-project convention (IR-12) | docs/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md | None | EP-3 | Not Started |
| 6 | Serve the Kiroku inspection surface standalone and make it self-describing | docs/plans/95-serve-the-kiroku-inspection-surface-standalone-and-make-it-self-describing.md | EP-1, EP-2, EP-3, EP-4 | EP-5 | Not Started |
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

EP-1 has no dependencies and lands first. Its only shared artifact is the composition point in
`kiroku-metrics/src/Kiroku/Metrics/Server.hs`, where it wraps the application handed to Warp in
`corsMiddleware cfg.cors`. It also introduces the structured error envelope helper because its
refused-upgrade response is the first structured body to ship.

EP-2 has no hard dependency, but it must be implemented after EP-1 or, if it starts first,
preserve the invariant EP-1 establishes: the value passed to `Warp.runSettings` and
`Warp.runSettingsSocket` is the CORS-wrapped composition. That is why EP-1 is a soft dependency.
EP-2 owns the `ServerProviders` record and the four general starters, which is why EP-3 and EP-4
hard-depend on it: their route arms are fields on that record, and their tests start servers
through `withMetricsServerWithProviders` and `storeServerProviders`.

EP-3 and EP-4 are independent of each other and may proceed in parallel once EP-2 is complete.
Their soft dependency on each other is textual: both add bullets under one unreleased heading
in `kiroku-store/CHANGELOG.md` and `kiroku-metrics/CHANGELOG.md`, both add `time` and `vector`
to the metrics test suite if absent, both append a step to `kiroku-metrics/example/Main.hs` and
a section to `docs/user/metrics.md`, and both use the identical `invalid_query_parameter`
details shape. Whichever lands second appends after what exists.

EP-5 has no hard dependency. Its soft dependency on EP-3 is the resolved-name event encoder
`recordedEventToJSONResolved`, owned by EP-3; if EP-5 lands first it introduces the function
with the fixed name, type, and module and EP-3 reuses it. EP-5 also changes `kiroku-store`
(the publisher's drop counter, see Integration Points), so it shares the store changelog's
unreleased heading with EP-3 and EP-4, but it touches no file those plans edit. EP-5 may
otherwise run in parallel with anything.

EP-6 hard-depends on EP-1 through EP-4 because the standalone executable exposes the CORS
options and serves every route family through `storeServerProviders`, and because the
discovery route reports the presence of every field of the finished record. It soft-depends on
EP-5 so that the UI-builder guide can link the conformance mapping; without EP-5 the guide links
the existing protocol section instead.

EP-7 hard-depends on all six because version numbers, dependency bounds, changelog dating,
release order, the clean-consumer proof, and request completion can be chosen truthfully only
from the integrated code. This MasterPlan deliberately forecasts but does not pin the version
numbers; EP-7 re-queries Hackage, upstream tags, and Mori dependents at execution time.

The recommended landing order is therefore EP-1, EP-2, then EP-3, EP-4, and EP-5 in any order or
in parallel, then EP-6, then EP-7. The longest serial chain is five plans deep (EP-1, EP-2, one
of EP-3 or EP-4, EP-6, EP-7).


## Integration Points

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
    , checkpointInventory :: !(Maybe CheckpointInventoryProvider)    -- GET /subscriptions/checkpoints        (EP-2)
    , browser :: !(Maybe StoreBrowser)                               -- /streams, /categories, /events        (EP-3 adds)
    , deadLetters :: !(Maybe DeadLetterProvider)                     -- GET /subscriptions/<name>/dead-letters (EP-4 adds)
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
```

Plan 87's two-argument `errorEnvelope` and plan 88's `browseErrorResponse` are replaced by
these; a plan that finds them already present reuses them and never adds a variant. The legacy
`{"error":"<string>"}` bodies on every pre-existing route and on the catch-all are frozen and
untouched. Shared code vocabulary across route families: `invalid_query_parameter` (400, with
`details` `{"parameter","value","reason"}`), `method_not_allowed` (405), `not_found` (404,
structured, only on paths under a new route family), `<family>_not_configured` (404 when the
provider is absent), `<family>_unavailable` or `store_unavailable` (503 on `ConnectionError`),
and `store_error` (500 on any other `StoreError`). Each child documents its own codes in
`docs/user/metrics.md`; EP-6's guide collects them.

**The resolved-name event object** (owner: EP-3, plan 88; consumer: EP-5, plan 94). Shared
artifact: `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`, beside `recordedEventToJSON`. The
function `recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value`
emits the published camelCase event object plus exactly one snake_case key,
`original_stream_name` (string, or `null` when unresolvable). EP-3 uses it for every REST item;
EP-5 uses it for `event` frames with a per-connection cache so unseen ids cost one batched
`lookupStreamNames` round trip per delivered batch. Plan 88's `recordedEventToBrowseJSON` in
`Kiroku.Metrics.Browse` is renamed and relocated to this. If EP-5 lands before EP-3, EP-5
introduces the function with this exact name, type, and module and EP-3 reuses it. The
justification is ADR-1: names are not carried on `RecordedEvent` because the batch lookup is
cheaper than a join on `$all` pages, and a browser has no other resolver.

**`MetricsServerConfig`** (owner: EP-1, plan 90). Shared artifact:
`kiroku-metrics/src/Kiroku/Metrics/Config.hs`. EP-1 adds `cors :: !CorsPolicy` with
`defaultConfig{cors = corsDisabled}`; this is the cohort's one configuration change and the
reason `kiroku-metrics` takes a PVP major bump. No other child adds a configuration field: EP-3
keeps browse limits on `StoreBrowser`, and EP-6 maps its command-line options onto existing
fields. If EP-6 finds a host bind option trivial and additive it records the decision; otherwise
`Warp.setHost "*"` stays as it is and the executable documents it.

**Version numbers, bounds, and changelogs** (owner: EP-7, plan 96; constraint on every other
child). No child edits a `.cabal` `version:` line or a dependency bound. Each child writes its
bullets under one `## Unreleased` heading at the top of the affected package changelog
(`kiroku-store/CHANGELOG.md` for EP-3, EP-4, and EP-5; `kiroku-metrics/CHANGELOG.md` for all
six), grouped as the release skill expects (`### Breaking Changes`, `### New Features`,
`### Other Changes`). Plans 87, 88, and 89 previously specified in-tree bumps to
`kiroku-store` 0.9.0.0 and `kiroku-metrics` 0.2.0.0 or 0.1.1.0; those numbers are stale
(`kiroku-store` 0.9.0.1 and `kiroku-metrics` 0.1.0.10 are already released) and are withdrawn.
EP-7's forecast, to be re-derived from the diffs: `kiroku-store` 0.10.0.0 (the closed `Store`
GADT gains four constructors and the exported `Subscriber` record gains a field),
`kiroku-metrics` 0.2.0.0 (the configuration field, the record, new modules, a new executable,
and two new library dependencies, `effectful-core` and `optparse-applicative`), and patch bumps
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
`subscribePublisher` as a wrapper returning today's triple. The ordinary not-full delivery path
is untouched, so under [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) EP-5's
gate is `cabal bench kiroku-store:kiroku-shibuya-overhead` before and after, recorded in its
plan; EP-7 runs the full gates for the cohort. No other child edits this file.

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

**ADR candidates.** EP-1's distillation pass decides whether to record the CORS posture
(default-off explicit origins applied at the WAI layer to HTTP and WebSocket alike, wildcard
unrepresentable) as a record future sister packages follow. EP-6 writes the record for the
composition boundary: the server never holds the store, store-backed routes enter through the
additive `ServerProviders` record, the exported application is the prefix-mountable unit, and
the surface is self-hosting and self-describing. Plan 88's planned Milestone 4 ADR on browse
endpoints wrapping `Store` primitives is withdrawn as subsumed by ADR-9 section 3. EP-7's
distillation pass reviews every child's Decision Log and decides whether ADR-9 section 1 needs
an amendment listing the newly published routes and frames, or whether the guide-as-inventory
rule suffices.


## Progress

- [x] (2026-09-30) Coordination: MasterPlan created; plans 87, 88, 89, and 90 adopted with
      coordination notes and the stale version, record, and envelope decisions withdrawn;
      plans 94, 95, and 96 created; IR-8 and IR-12 moved to `accepted`.
- [ ] EP-1: `Kiroku.Metrics.Cors`, the `cors` configuration field, the shared error envelope
      helpers, and database-free CORS tests.
- [ ] EP-1: middleware wired at the composition point; real-server HTTP and WebSocket origin
      tests; documentation, example step, CAP-17, changelog, IR-11 evidence.
- [ ] EP-2: `Kiroku.Metrics.Checkpoints` and the pure codec test.
- [ ] EP-2: `ServerProviders`, the four general starters, the reserved `/subscriptions/checkpoints`
      segment, legacy starters as delegations.
- [ ] EP-2: end-to-end checkpoint tests; documentation, example step, CAP-17, changelog, IR-10
      evidence.
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

- Adoption audit (2026-09-30): plans 87, 88, and 89 all target an in-tree `kiroku-store` bump
  to 0.9.0.0 and `kiroku-metrics` bumps to 0.2.0.0 or 0.1.1.0, but `kiroku-store` 0.9.0.0 and
  0.9.0.1 shipped on 2026-09-25 (migration `0012`, the category index, and the idle-publisher
  retention fix) and `kiroku-metrics` is at 0.1.0.10. The next `kiroku-store` major is
  0.10.0.0, and the numbers are now assigned only by EP-7.
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

(To be filled during and after implementation.)
