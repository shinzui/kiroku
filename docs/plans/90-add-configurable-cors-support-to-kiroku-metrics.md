---
id: 90
slug: add-configurable-cors-support-to-kiroku-metrics
title: "Add configurable CORS support to kiroku-metrics"
kind: exec-plan
created_at: 2026-09-10T03:24:48Z
intention: "intention_01m24n4q6verjrhrk58qt6gbh2"
master_plan: "docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-10T03:24:48Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-30T22:56:43Z
      mode: "update"
      note: "Adopted as a child of MasterPlan 13: settled ServerProviders record, errorEnvelope/errorResponse ownership, resolved-name encoder, versions deferred to plan 96, release milestone moved"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:06Z
      mode: "update"
      note: "Correct current APIs, integration ownership and bounded observer work; runtime acceptance remains pending."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T15:58:37Z
      mode: "implement"
      note: "Implement and validate the CORS foundation and shared sanitized errors"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:07Z
      verdict: "comments"
      note: "Source review corrections applied; SQL promotion and focused performance gates require implementation evidence."
---

# Add configurable CORS support to kiroku-metrics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan implements the improvement request
[IR-11, Add configurable CORS support to kiroku-metrics](../improvement-requests/add-configurable-cors-support-to-kiroku-metrics.md),
canonically `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-11`. The request was
filed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`), which
is building a browser UI over the keiro runtime stack. It is the enabling request for every
browser consumer of `kiroku-metrics`: until the server opts in, a page served from any other
origin cannot call a single inspection endpoint. The request was moved from `proposed` to
`accepted` in the same commit that created this plan, and its Status section links back here.

Since 2026-09-30 this plan is EP-1 of
[MasterPlan 13, Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md),
which coordinates the five open keiro-ui requests as one cohort, and it lands first. Three
things changed when it was adopted, and the MasterPlan's Integration Points section is
authoritative wherever this plan's older text disagrees: this plan owns the structured error
envelope for the whole cohort and creates it as the details-carrying pair
`errorEnvelope :: Text -> Text -> Maybe Value -> Value` and
`errorResponse :: Status -> Text -> Text -> Maybe Value -> Response` in `Kiroku.Metrics.JSON`,
which plans 87, 88, 89, and 95 reuse; the wrap this plan puts around the composed application
is an invariant plan 87 (EP-2) must preserve when it moves the composition into
`combinedAppWithProviders`; and no version is bumped and nothing is released here, because plan
96 (EP-7) releases the whole cohort and this plan's configuration field is what makes that
release a PVP major. Commits carry this plan's Intention trailer and a `MasterPlan:` trailer
naming the MasterPlan file.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store written in Haskell. Its HTTP sister package,
`kiroku-metrics`, serves operational metrics, health probes, a live subscription registry, and a
WebSocket that streams events, all from a small Warp server that a host application starts with
`withMetricsServerWithStore` or one of its siblings. Today that server sends no CORS headers at
all (verified at commit `4a1b98a`: `grep -rn 'Access-Control\|hOrigin\|"Origin"' kiroku-metrics/src`
finds nothing; the only "origin" text in the package is the event object's `originalStreamId`
and `originalVersion` keys). CORS, Cross-Origin Resource Sharing, is the browser rule that a web
page loaded from one origin (scheme, host, and port, such as `https://ops.example.com`) may not
read the response of an HTTP request to a different origin unless that server explicitly says so
in response headers. So a dashboard served from `https://ops.example.com` cannot read
`GET /metrics` from a metrics server on `http://worker-3:9091`, even on a trusted network, and
non-browser clients such as `curl` and Prometheus never notice the difference.

After this plan, a host that wants browser access adds one field to its server configuration:

```haskell
import Kiroku.Metrics

main = do
  origins <- either (fail . show) pure (traverse allowedOrigin ["https://ops.example.com"])
  let cfg = defaultConfig{port = 9091, cors = corsAllowOrigins origins}
  withMetricsServerWithStore cfg metrics store [postgresPing store] $ \_ -> ...
```

and can observe, from another shell, that a browser-style preflight and a browser-style request
from that origin are answered with the headers a browser needs, while an origin not on the list
gets exactly the response it gets today (abridged; Warp also emits `Date`, `Server`, and
`Transfer-Encoding`):

```text
$ curl -si -X OPTIONS http://localhost:9091/metrics \
    -H 'Origin: https://ops.example.com' -H 'Access-Control-Request-Method: GET'
HTTP/1.1 204 No Content
Access-Control-Allow-Origin: https://ops.example.com
Vary: Origin
Access-Control-Allow-Methods: GET, HEAD, OPTIONS

$ curl -si http://localhost:9091/metrics -H 'Origin: https://ops.example.com' | head -4
HTTP/1.1 200 OK
Content-Type: application/json
Access-Control-Allow-Origin: https://ops.example.com
Vary: Origin

$ curl -si http://localhost:9091/metrics -H 'Origin: https://evil.example.com' | head -2
HTTP/1.1 200 OK
Content-Type: application/json
```

The same list governs the WebSocket: with origins configured, a browser page on
`https://ops.example.com` can open `wss://api.example.com/ws/events` through the host's TLS proxy, a page on
`https://evil.example.com` is refused with HTTP 403 before the WebSocket protocol starts, and a
non-browser client that sends no `Origin` header connects exactly as it does today. With the
default configuration nothing changes anywhere: every response is byte-for-byte what it is today,
which is the behaviour the request's first acceptance item demands.

The forbidden CORS combination, a wildcard origin together with credentialed requests, cannot be
expressed: the only way to build an allowed origin is a validating constructor that refuses `*`
(and the opaque `null` origin). This prevents wildcard credential grants, not unauthorized
access: authentication and TLS remain the host's responsibility.


## Progress

- [x] (2026-10-10) Reviewed the integrated design against current source; corrected API and performance hazards. This is planning work, not implementation evidence.
- [ ] Implement and execute the focused correctness and performance acceptance added by this review.

- [x] (2026-10-10) Milestone 1: `Kiroku.Metrics.Cors` module (validated `AllowedOrigin`, `CorsPolicy`,
      `corsMiddleware`), the `cors` field on `MetricsServerConfig` defaulting to
      `corsDisabled`, umbrella re-export, changelog `Unreleased` entry, and the standalone
      (database-free) `Test.CorsSpec` examples for configuration validation, preflight, actual
      requests, disallowed and absent origins, matching rules, credentials, and the WebSocket
      upgrade refusal at the WAI layer; IR-11 set to `in_progress`.
- [x] (2026-10-10) Milestone 2: middleware wired into `combinedApp` so every starter honours `cfg.cors`; the
      shared `errorEnvelope`/`errorResponse` helpers in `Kiroku.Metrics.JSON` (created in
      Milestone 1); real-server examples proving
      `GET /metrics` is decorated through `startMetricsServerWithStore`, `/ws/metrics` upgrades
      for an allowed origin, is refused for a disallowed one, ignores an absent `Origin`, and
      stays open to any origin when CORS is disabled; whole suite green.
- [ ] Milestone 3: `docs/user/metrics.md` CORS section with transcripts, the WebSocket origin
      rule, the credentials rule, and the reverse-proxy alternative; config table row and
      deployment note; example extended with a CORS step and the quoted transcript updated;
      CAP-17 updated with log entry; changelog finalized; IR-11 body updated with implementation
      evidence; all repository validations green.
- [ ] Milestone 4: ADR distillation pass performed (the CORS-posture record decided with
      evidence in hand) and Outcomes written. (The release, the clean-consumer check, and
      IR-11's `completed` status moved to plan 96, EP-7 of MasterPlan 13, on 2026-09-30.)


## Surprises & Discoveries

- 2026-10-10 source review: The proposed origin parser accepted malformed authorities and default-port mismatches; enabled no-origin/disallowed responses omitted Vary, allowing cache-dependent browser failures. Network header equality also included volatile Warp headers. No runtime acceptance is inferred from this finding.

Implementation baseline: `cabal build kiroku-metrics` passed and the existing suite
reported 23 examples, zero failures. After wiring the middleware, `cabal test kiroku-metrics
--test-show-details=direct` reported 43 examples, zero failures. The initial standalone
checks exposed an empty requested-header list accepted by `ByteString.split`; explicit
nonempty validation corrected it. The real refused handshake is `MalformedResponse`,
as expected for HTTP 403. No append, publisher or subscription module changed.


## Decision Log

- Decision (2026-10-10): the reviewed Context and Plan of Work supersede incompatible September choices on dependencies, routes, decoding, method handling, bounds and performance. Implementation remains pending; durable constraints are in ADR-15.
  Rationale: the released APIs changed and the original sketches contained correctness and shared-resource hazards.

- Decision: Implement CORS as a hand-written WAI middleware in a new module
  `Kiroku.Metrics.Cors`, using only libraries the package already depends on (`wai`,
  `http-types`, `bytestring`, `text`, `aeson`), rather than adding the `wai-cors` package.
  Rationale: Repository policy is to read a dependency's source through Mori before relying on
  its API, and `wai-cors` is not in the registered corpus (`mori registry search wai-cors`
  finds nothing), so its exact semantics for disallowed origins, `Vary`, and preflight could not
  be verified; the request's "byte-for-byte identical when disabled" and "no headers for
  disallowed origins" acceptance items need precise control that is easier to own in roughly a
  hundred lines than to configure around another library's defaults; and every new library
  widens the Nix closure that `nix build .#kiroku-metrics` must realize. The middleware is
  exported so a host that mounts `httpApp` itself can wrap it too.
  Date: 2026-09-10

- Decision: The configuration is a new field `cors :: !CorsPolicy` on `MetricsServerConfig`,
  where `CorsPolicy` is a small record (`allowedOrigins :: [AllowedOrigin]`,
  `allowCredentials :: Bool`, `maxAgeSeconds :: Maybe Int`) and an empty `allowedOrigins` list
  means disabled; `defaultConfig` sets `cors = corsDisabled`.
  Rationale: IR-11 names `MetricsServerConfig` and asks for "an explicit list of allowed
  origins, default empty", and CORS is server-wide policy that must apply to every starter,
  unlike the per-route data sources that plans 87 and 88 route through provider records. Every
  documented caller (the user guide, both test suites, the example) builds the record with
  `defaultConfig{port = ...}`, which stays source-compatible; positional and explicit complete
  construction must account for the new field. This is a PVP major change regardless of local
  usage, and belongs in the changelog. Plan 88
  declined to add config fields for its browse limits because a limit is route-local; this
  field is not. A sub-record rather than three flat fields lets the middleware take exactly the
  policy it needs and lets future CORS knobs be added without touching `MetricsServerConfig`
  again.
  Date: 2026-09-10

- Decision: Wildcard and opaque origins are unrepresentable. `AllowedOrigin` is an abstract
  newtype whose only constructor function `allowedOrigin :: Text -> Either OriginError
  AllowedOrigin` refuses `*`, `null`, values without `scheme://`, values with an empty host, and
  values carrying a path, query, or fragment (one trailing `/` is tolerated and stripped), and
  lowercases what it accepts. This prevents wildcard grants with credentials, but does not authenticate callers.
  Rationale: The cross-project conventions require that "no wildcard origin with credentials"
  be unrepresentable, and IR-11 acceptance 6 asks that the combination fail at configuration
  time or be unrepresentable; refusing the wildcard outright is the simplest way to satisfy both
  and matches the request's "explicit allowed-origins list" wording. Origins are compared as
  lowercased ASCII bytes because scheme and host are case-insensitive by definition and an
  origin has no case-sensitive component. The port is significant: `https://a.example:8443` and
  `https://a.example` are different origins.
  Date: 2026-09-10

- Decision: The middleware wraps the whole combined application in `combinedApp`, and the
  WebSocket `Origin` check happens at the WAI layer (using `isWebSocketsReq` from
  `wai-websockets`) by answering HTTP 403 before `websocketsOr` runs, not inside
  `websocketApp`.
  Rationale: Every starter funnels through `startMetricsServerWith'` and `combinedApp` today,
  so one wrapping point covers HTTP routes, the real WebSocket app, and the rejecting stub alike,
  and it cannot be forgotten by a new starter. In `wai` 3.2.5, `mapResponseHeaders` is a no-op on
  `ResponseRaw` (verified in `Network/Wai.hs`), so decorating responses can never disturb a
  WebSocket upgrade that is allowed through. A 403 at the WAI layer is what "rejected before the
  protocol starts" means: the client sees an ordinary HTTP response and no WebSocket frames are
  exchanged.
  Date: 2026-09-10

- Decision (revised 2026-10-10): Disabled CORS is exactly the identity; enabled HTTP
  responses always vary on Origin, while only allowed origins receive grants. Preflight
  validates methods/header names and includes their Vary keys when reflected.
  Rationale: Cached responses without grants also vary by origin. Lack of explicit freshness
  is not a sufficient cache-correctness argument. The Milestone 1 tests replace the
  September no-Vary assertions for enabled policies.

- Decision: The WebSocket `Origin` check is enforced only when CORS is enabled. With the
  default `corsDisabled`, upgrades from any origin succeed exactly as today.
  Rationale: IR-11 requires that the default is "today's behaviour" and scopes the origin check
  to "when origins are configured". Browsers do not apply CORS to WebSocket handshakes, so a
  metrics server on the default configuration is reachable from any page, which is the
  documented trusted-network posture (conventions section 8). The user guide says explicitly
  that configuring origins also tightens the WebSocket, so an operator can choose.
  Date: 2026-09-10

- Decision: The refused upgrade answers with the structured error envelope
  `{"error":{"code":"origin_not_allowed","message":"..."}}` and HTTP 403, built with an
  `errorEnvelope` helper in `Kiroku.Metrics.JSON` that is byte-for-byte the helper plan 87
  specifies; this plan creates it and plan 87 hard-depends on this plan.
  Amended on 2026-09-30: this plan lands first and owns the helper, and the shape is the
  details-carrying pair `errorEnvelope :: Text -> Text -> Maybe Value -> Value` plus
  `errorResponse :: Status -> Text -> Text -> Maybe Value -> Response` (the `details` key is
  omitted when `Nothing`), so plans 87, 88, 89, and 95 share one definition.
  Rationale: The cross-project conventions require the envelope for new responses and freeze the
  legacy string bodies; ADR-9 makes shipped bodies permanent and asks that a new surface ship
  with a test pinning its key set, which `Test.CorsSpec` does. Nothing this plan adds changes a
  published body, status, frame, or path: CORS response headers are not part of the published
  shapes ADR-9 enumerates, the preflight `204` and the `403` are reachable only under explicit
  host configuration, and ADR-9 lists `MetricsServerConfig` fields as PVP-governed Haskell API
  rather than wire contract.
  Date: 2026-09-10

- Decision: IR-11's `status` moved from `proposed` to `accepted` when this plan was created
  (with the request's Status section linking the plan), moves to `in_progress` when Milestone 1
  starts, and to `completed` (with `completedAt`) only after release evidence exists; the release
  itself requires explicit user confirmation through the repository `release` skill.
  Rationale: This is the lifecycle IR-10 and plan 87 follow, using Mori's closed vocabulary
  (`proposed`, `accepted`, `in_progress`, `completed`, `declined`, `superseded`). IR-11 predates
  its plan, so acceptance is a distinct, recordable step. Publishing is irreversible and the
  request leaves version bumps "at kiroku's discretion", so a human confirms.
  Date: 2026-09-10

- Decision: The release is a PVP major bump of `kiroku-metrics` computed against whatever
  version is current when Milestone 4 runs (0.1.0.8 at planning time, so 0.3.0.0 unless plan 87
  or plan 88 has shipped first, in which case the next major after theirs). `kiroku-store` and
  `kiroku-cli` are unchanged and unreleased by this plan.
  Rationale: Adding a field to a record whose constructor is exported changes the datatype
  definition, which the PVP classifies as major. Plans 87, 88, and 89 are being written or
  implemented concurrently against the same package; the changelog `Unreleased` section is the
  merge point, and the release skill re-checks Hackage and tags before proposing a number.
  Date: 2026-09-10
  Superseded on 2026-09-30: this plan releases nothing and edits no `version:` line or bound.
  Plan 96 (EP-7 of MasterPlan 13) assigns the cohort's versions; the `cors` field is still what
  makes `kiroku-metrics`'s next release a PVP major (0.3.0.0 is the forecast).

- Decision: Land first among the MasterPlan's children, and treat the CORS wrap around the
  composed application as an invariant of the composition point that plan 87 preserves when it
  introduces `combinedAppWithProviders`.
  Rationale: This is the enabling request for every browser consumer and touches only the
  configuration record and the composition point, so landing it first means every later route
  inherits the middleware without a retrofit. MasterPlan 13 records the invariant in its
  Integration Points, and plan 87's Milestone 2 checks it with the same `grep` this plan uses.
  Date: 2026-09-30

- Decision: No new ADR is planned up front. The distillation pass at completion decides whether
  to record "browser access to sister-package HTTP surfaces is default-off, explicit-origin CORS
  applied at the WAI layer to HTTP and WebSocket alike, with wildcard origins unrepresentable"
  as an ADR; it is the most likely candidate because future routes (plans 87, 88, 89) inherit it
  silently and a future sister package should follow it.
  Rationale: PLANS.md asks for durable context to be promoted at completion with evidence in
  hand; the wire-stability contract that this plan must respect already exists as ADR-9.
  Date: 2026-09-10


## Outcomes & Retrospective

2026-10-10 review: implementation and performance acceptance remain pending. Static review does not prove zero runtime regression. Earlier planning-time observations and dated decisions are historical where this revision explicitly replaces them.

(To be filled during and after implementation.)


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

An **origin** is the triple of URL scheme, host, and port that a browser treats as one security
boundary, written like `https://ops.example.com` or `http://localhost:5173` (no path, no trailing
slash; the port is omitted when it is the scheme's default). Browsers send the page's origin in
an `Origin` request header on cross-origin requests and on every WebSocket handshake. A special
value `null` (the **opaque origin**) is sent for sandboxed frames and `file://` pages and must
never be trusted as an identity.

**CORS** (Cross-Origin Resource Sharing) is the browser-enforced protocol by which a server
opts in to cross-origin reads. The browser makes the request, then refuses to hand the response
to the page unless the response carries `Access-Control-Allow-Origin` naming the page's origin.
For requests that are not "simple" (any method other than `GET`, `HEAD`, or `POST`, or any
custom header), the browser first sends a **preflight**: an `OPTIONS` request with
`Access-Control-Request-Method` (and optionally `Access-Control-Request-Headers`), and proceeds
only if the response allows the method and headers. **Credentialed** requests are those the page
makes with cookies or an `Authorization` header (`fetch(url, {credentials: "include"})`); for
them the server must send `Access-Control-Allow-Credentials: true` and may not use the wildcard
`*` as the allowed origin. `Vary: Origin` tells caches that the response depends on the request's
`Origin` header. In this plan "CORS headers" means any response header whose name starts with
`Access-Control-`.

A **WAI `Application`** is the standard Haskell value a web server such as Warp runs: a function
from a request and a response callback to an `IO` action. A **`Middleware`** is a function from
one `Application` to another; it can inspect the request, short-circuit with its own response,
or transform the inner response (`type Middleware = Application -> Application` in
`Network.Wai`). A **WebSocket upgrade** is an HTTP request carrying `Upgrade: websocket` that a
server answers with status `101 Switching Protocols` and then speaks the WebSocket framing on the
same socket; in this package `wai-websockets`' `websocketsOr` recognises such requests and hands
them to a `websockets` `ServerApp`. **PVP** is the Haskell Package Versioning Policy: a change to
an exported datatype's definition is a major bump (`0.1.x.y` to `0.3.0.0`); an addition is a
minor bump.

### The metrics server today

Everything below is under `kiroku-metrics/`, version 0.2.0.0 at the 2026-10-10 review. The
package's `common` stanza enables `DuplicateRecordFields`, `OverloadedRecordDot`,
`OverloadedStrings`, `RecordWildCards`, `LambdaCase`, `DerivingStrategies`, `DeriveAnyClass`, and
builds with `-Wall -Werror=incomplete-patterns`. The library depends on `aeson`, `async`, `base`,
`bytestring`, `containers`, `hasql`, `hasql-pool`, `http-types`, `kiroku-cli`, `kiroku-store`,
`stm`, `text`, `time`, `uuid`, `vector`, `wai`, `wai-websockets`, `warp`, and `websockets`. The
test suite additionally uses `hspec`, `http-client`, `lens`, `generic-lens`, `scientific`, and
`kiroku-test-support`; it does not list `wai` or `case-insensitive`, which Milestone 1 adds.

`src/Kiroku/Metrics/Config.hs` defines the whole configuration:

```haskell
data MetricsServerConfig = MetricsServerConfig
    { port :: !Int
    , enableJSON :: !Bool
    , enablePrometheus :: !Bool
    , enableWebSocket :: !Bool
    , wsPushIntervalUs :: !Int
    , wsMaxConnections :: !Int
    , wsEventQueueCap :: !Natural
    , readinessMaxLag :: !Int64
    , livenessTimeoutUs :: !Int
    }
    deriving stock (Eq, Show)

defaultConfig :: MetricsServerConfig
defaultConfig = MetricsServerConfig { port = 9091, enableJSON = True, ... }
```

`src/Kiroku/Metrics/Server.hs` holds the lifecycle and the router. Every public starter
(`startMetricsServer`, `startMetricsServerWith`, `startMetricsServerWithStore`, and the
bracketed `withMetricsServer`, `withMetricsServerWithStore`, `withMetricsServerSubscriptions`)
delegates to `startMetricsServerWith'`, which builds the application with `combinedApp` and hands
it to Warp (on an OS-assigned port when `cfg.port == 0`). `combinedApp` is the single composition
point:

```haskell
combinedApp cfg m deps mProvider wsApp =
    WaiWS.websocketsOr WS.defaultConnectionOptions wsApp (httpApp cfg m deps mProvider)
```

`httpApp` pattern-matches on `pathInfo req` only (never on the method) for `/metrics`,
`/metrics/prometheus`, `/metrics/<name>`, `/subscriptions`, `/subscriptions/<name>`, `/health`,
`/health/live`, `/health/ready`, and `/ws`, and answers `404 {"error":"Not found"}` otherwise.
Plans 87, 88, and 89 (all unimplemented at planning time; plan 89 is a checked-in child) restructure the starters and the router around provider records but keep `combinedApp`
or a successor as the place where the WebSocket app and the router are composed; this plan only
wraps that composition and never changes the router's cases or any starter's signature.

`src/Kiroku/Metrics/WebSocket.hs` implements the `ServerApp`. It dispatches on
`WS.requestPath (WS.pendingRequest pending)` (`/ws/metrics` or `/ws/events`) and rejects unknown
paths and over-capacity connections with `WS.rejectRequest pending "<message>"`, which sends an
HTTP 400. The stub used by store-less starters, `stubWebSocketApp` in `Server.hs`, rejects every
upgrade the same way. Neither looks at the `Origin` header.

`src/Kiroku/Metrics/JSON.hs` exports `jsonResponse :: Status -> LBS.ByteString -> Response`
(sets `Content-Type: application/json`). `src/Kiroku/Metrics.hs` is the umbrella module that
re-exports every submodule with `module Kiroku.Metrics.X` lines; a new module must be added to
both its export list and its imports.

The test suite is Hspec, entered from `test/Main.hs`, which wraps every spec in
`withSharedMigratedPostgres` from `kiroku-test-support` and lists the spec modules; the cabal
`test-suite` stanza lists them under `other-modules`. `test/Test/ServerSpec.hs` shows the HTTP
pattern (boot a store with `withMigratedTestDatabase` and `withStore`, start a server on
`port = 0`, `threadDelay 200_000`, then `http-client` requests through a helper
`get :: Manager -> String -> IO (Int, ByteString)`), and `test/Test/WebSocketSpec.hs` shows the
WebSocket pattern (`startMetricsServerWithStore`, then `WS.runClient "127.0.0.1" port
"/ws/metrics"` inside `timeout 15_000_000`, decoding frames with aeson and checking their `type`).

`example/Main.hs` is the self-verifying example (`cabal run -fexample kiroku-metrics-example`,
behind the manual cabal flag `example`) whose six-step transcript `docs/user/metrics.md` quotes in
its "Try it" section; it starts the server with `withMetricsServerWithStore (defaultConfig{port = 0})`.

### Library facts this plan relies on (verified from source)

Sources were read from the Mori corpus (`mori://yesodweb/wai`, project-relative
`wai/Network/Wai.hs` and `wai-websockets/Network/Wai/Handler/WebSockets.hs`; artifact URIs pending) and, for packages not in the corpus, from
the exact versions in `dist-newstyle/cache/plan.json` unpacked from the cabal package cache.

- `wai` 3.2.5, `Network.Wai`: `type Middleware = Application -> Application`;
  `mapResponseHeaders :: (ResponseHeaders -> ResponseHeaders) -> Response -> Response` rewrites
  the headers of `ResponseFile`, `ResponseBuilder`, and `ResponseStream` and leaves
  `ResponseRaw` (the WebSocket upgrade) untouched; `requestMethod`, `requestHeaders`,
  `responseLBS` are the accessors and constructor used here.
- `wai-websockets` 3.0.1.2, `Network.Wai.Handler.WebSockets`: exports `isWebSocketsReq ::
  Request -> Bool`, true when the `Upgrade` header equals `websocket` case-insensitively, and
  `websocketsOr`, which calls the backup application for anything that is not an upgrade.
- `websockets` 0.13.0.0: `RequestHead{requestPath, requestHeaders, requestSecure}` with
  `type Headers = [(CI ByteString, ByteString)]`; `runClientWith :: String -> Int -> String ->
  ConnectionOptions -> Headers -> ClientApp a -> IO a` sends custom headers (the test uses it to
  send `Origin`); a handshake answered with a non-101 status makes the client throw
  `HandshakeException` (`MalformedResponse` for any status other than 400, `RequestRejected`
  for 400), so a test asserts on the exception type, not its constructor.
- `http-types` 0.12.6: `hOrigin`, `hVary`, `methodOptions`, `methodHead`, `status204`,
  `status403`; `HeaderName` is `CI ByteString`, so header names can be written as string
  literals under `OverloadedStrings` and compare case-insensitively.
- `http-client` 0.7.19: `Request{method, requestHeaders}` are updatable record fields on the
  value `parseRequest` returns; `responseHeaders :: Response a -> ResponseHeaders`.
- `warp` 3.4.15: `testWithApplication :: IO Application -> (Port -> IO a) -> IO a` runs an
  application on a free port for the duration of the action (used for database-free tests), and
  Warp strips the body of `HEAD` responses itself, which is why `HEAD` is an honest member of the
  allowed methods.

### Documentation and knowledge bundles touched

`docs/user/metrics.md` is the package user guide. Its opening callout states the no-auth,
no-TLS deployment assumption; "Starting the server" has the configuration table; "Wire-format
stability" (added with ADR-9 on 2026-09-10) explains what is frozen; "Try it" quotes the example
transcript. This plan adds a "Cross-origin browser access (CORS)" section, a table row, and a
sentence in the callout.

`docs/capabilities/operational-http-endpoints.md` is capability `CAP-17` in the profile-governed
`capabilities` OKF bundle (validated by `just capabilities-validate`); its `description`,
`interface`, `evidence`, and body must mention CORS, and `docs/capabilities/log.md` receives a
dated `**Update**` entry. Do not change `generated.at`, `since`, or `capabilityId`.

`docs/improvement-requests/add-configurable-cors-support-to-kiroku-metrics.md` is IR-11 in the
`improvement-requests` OKF bundle governed by `mori/improvement-requests-profile.dhall`
(okf-profiles v0.5.0 `coordination.improvementRequests`). Its frontmatter carries `timestamp`,
`requestId: IR-11`, `status: accepted` (set when this plan was created; its Status section links
back here), and `origin: mori://shinzui/keiro-ui`. Every status change must advance `timestamp`,
add a dated entry to `docs/improvement-requests/log.md`, and pass the strict validation command
in Concrete Steps.

`agents/skills/release/SKILL.md` is the release procedure (independent per-package PVP versions,
tags named `<package>-v<version>`, publish order ending with `kiroku-metrics`). Only
`kiroku-metrics` is released by this plan.

### Relevant architecture decisions

Local ADRs read for this plan (the others were scanned by heading and are not relevant):

- [ADR-9, Published HTTP and WebSocket wire shapes are frozen and served only by sister packages](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
  (`mori://shinzui/kiroku/okf/adrs/concepts/ADR-9`): every documented JSON body, status code,
  frame, and path of `kiroku-metrics` is frozen and may only grow additively; a new surface
  ships with a test pinning its keys; `MetricsServerConfig` fields are Haskell API under the PVP,
  not wire contract; the text of WebSocket upgrade rejections is not published; the surface
  lives in sister packages that wrap supported `kiroku-store` APIs and add no web dependency to
  the core. This plan adds response headers and two configuration-gated responses (the preflight
  `204` and the `403` envelope), changes no shipped body, and pins the new envelope's keys.
- [ADR-6, Versioned public SQL relations are owner-published and frozen](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md)
  is the precedent ADR-9 extends and is cited only for that lineage.

Cross-repository decisions, cited by the canonical handles the keiro-ui bundle publishes:

- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1` (inspection endpoints live in the project
  that owns the concept) is why the CORS hook is kiroku's to build.
- The shared conventions are `mori://shinzui/keiro-ui`,
  `docs/architecture/inspection-api-conventions.md` (artifact-level URI pending). Section 7
  (CORS) binds directly: an explicit allowed-origins list configured by the host, disabled by
  default with no CORS headers, no wildcard origin with credentials made unrepresentable, and
  the reverse-proxy single-origin deployment documented as a legitimate alternative. Section 4
  requires the structured error envelope for new responses. Section 8 requires this plan's
  documentation to restate that the server has no authentication and assumes a trusted network
  or an authenticating reverse proxy, and that CORS is not a substitute.

`mori path` may report the keiro-ui handles as not found because registry observation lags
fresh commits (plans 69 and 87 recorded the same); per repository policy the canonical URIs are
retained.


## Plan of Work

### Milestone 1: validated policy, cache-correct middleware, and database-free tests

Create `kiroku-metrics/src/Kiroku/Metrics/Cors.hs` and register/re-export it in the cabal
file and `Kiroku.Metrics`. Move IR-11 to in_progress when implementation actually starts,
maintain its bundle log, and keep release completion owned by plan 96.
Expose abstract `AllowedOrigin`, `OriginError(..)`, `allowedOrigin :: Text -> Either OriginError AllowedOrigin`
and `renderAllowedOrigin :: AllowedOrigin -> Text`. Keep the existing proposed error
constructors WildcardOrigin, OpaqueOrigin, MissingScheme, EmptyHost, HasPathQueryOrFragment
and NotAnOrigin, each detailed constructor carrying Text.

Validate an actual HTTP(S) origin, not merely a string containing `://`. Accept an ASCII
DNS host, IPv4 host or bracketed IPv6 literal with optional decimal port 0..65535. Validate
the authority fully; reject empty scheme/host, unsupported schemes, userinfo, wildcard hosts,
unbracketed IPv6, invalid ports, whitespace/control characters, percent-escaped authority,
query/fragment/path, and raw Unicode hostnames (callers supply their ASCII form).
Normalize scheme and DNS case, default ports 80/443 and IPv6 literal representation.
Configuration may trim surrounding whitespace and strip one trailing slash; recheck host
nonemptiness afterward. Request origins must be a single valid serialized origin, with no
trailing slash or multiple header values. Do not lowercase arbitrary Unicode into acceptance.
If using a URI/IP parsing dependency, locate its source with Mori and verify the released
API and bounds before choosing it. The origin contract and adversarial tests are mandatory,
not the earlier hand-written split-and-lowercase algorithm.

Retain the small public policy and defaults:

```haskell
data CorsPolicy = CorsPolicy
    { allowedOrigins :: ![AllowedOrigin]
    , allowCredentials :: !Bool
    , maxAgeSeconds :: !(Maybe Int)
    }
corsDisabled :: CorsPolicy
corsAllowOrigins :: [AllowedOrigin] -> CorsPolicy
corsEnabled :: CorsPolicy -> Bool
corsAllowedMethods :: ByteString  -- "GET, HEAD, OPTIONS"
originAllowed :: CorsPolicy -> ByteString -> Bool
isPreflight :: Request -> Bool
corsMiddleware :: CorsPolicy -> Middleware
```

An empty list disables CORS. Credentials default False and max-age defaults Nothing.
For compatibility with the record-shaped policy, a negative maxAgeSeconds is treated as
absent and documented/tested, never serialized as a negative header.
Wildcard origins cannot be constructed, but that is not authentication or a claim that
credentials are universally safe.

Choose disabled identity at middleware construction (`corsMiddleware corsDisabled app = app`
in observable behavior); precompute the normalized origin Set once for an enabled policy.
No request-time rebuild, database access or extra thread is permitted.
For enabled ordinary HTTP responses, merge `Origin` into Vary even for absent, malformed
or disallowed origins. Preserve existing Vary tokens, matching case-insensitively, without
duplicates; preserve `Vary: *`. Those origins get no Access-Control-Allow-* grant.
An allowed request gets exactly its serialized origin echoed once, plus credentials only
when enabled. Do not concatenate duplicate grant headers.

A preflight is OPTIONS with Origin and Access-Control-Request-Method. An allowed origin
requesting GET or HEAD gets 204 and the declared allow-methods; reject an unsupported method
with 403 `cors_method_not_allowed`. Validate requested header names as HTTP tokens before
reflecting them; malformed input gets 400 `invalid_cors_request`. A reflected preflight
varies also on Access-Control-Request-Method and Access-Control-Request-Headers.
Disallowed preflights pass through without grants (plus Vary); their status is whatever the
legacy router produces, not necessarily 404. Plain OPTIONS is not a preflight.
Reject malformed/duplicate/disallowed Origin on an upgrade with 403
`origin_not_allowed` before `websocketsOr`. An absent Origin remains allowed for nonbrowser
clients. Disabled CORS retains existing upgrade behavior. Allowed upgrades are raw WAI
responses, not JSON/HTTP bodies to rewrite.

This plan owns the shared JSON helper pair in `kiroku-metrics/src/Kiroku/Metrics/JSON.hs`:

```haskell
errorEnvelope :: Text -> Text -> Maybe Value -> Value
errorResponse :: Status -> Text -> Text -> Maybe Value -> Response
storeErrorResponse :: Text -> StoreError -> Response
```

The envelope is `{"error":{"code":"...","message":"...","details":...}}`, omitting details
when Nothing. The response is application/json. `storeErrorResponse unavailableCode`
maps ConnectionError to sanitized 503 with that code, EventDecodeFailed to sanitized
500 event_decode_failed, and other errors to sanitized 500 store_error. It does not catch
exceptions. Import the existing public StoreError type; never leak its Show text.
Every new route reuses these definitions; published legacy string errors stay unchanged.

Append `cors :: !CorsPolicy` to `MetricsServerConfig`, defaulting to corsDisabled.
Config imports Cors; Cors must not import Config. Update umbrella exports and compile a
consumer importing all of `Kiroku.Metrics`. Constructor additions are source-breaking:
only existing defaultConfig record-update callers are automatically compatible.
Add Unreleased changelog bullets; no version edits here.

Create/register `kiroku-metrics/test/Test/CorsSpec.hs`. Use a trivial instrumented WAI app
and a real Warp/WebSocket integration fixture. Test disabled identity at the WAI level or
exclude volatile Warp-generated Date headers from network comparisons. Check GET and HEAD,
allowed/disallowed/absent origins, duplicate Origin, allowed and unsupported preflight methods,
invalid requested headers, preserved Vary tokens and *, no duplicate grants, credentials and
negative/positive max-age, malformed authorities, default ports, IPv4 and IPv6, uppercase
configuration, and an explicit distinction between a configuration trailing slash and an
invalid request trailing slash. Sequential allowed and disallowed requests must not receive
a cached grant from the other origin; no-origin cached responses must not suppress an allowed
grant. No database is needed.

The standards basis is the [Fetch CORS protocol and HTTP caches](https://fetch.spec.whatwg.org/#cors-protocol-and-http-caches)
and [RFC 6454 origin serialization](https://www.rfc-editor.org/rfc/rfc6454.html#section-6).
Acceptance: `cabal build kiroku-metrics` and `cabal test kiroku-metrics-test --test-options='--match Cors'`
pass; middleware tests prove grants and cache variation independently of volatile headers.


### Milestone 2: wire the middleware into every starter and prove the WebSocket rule

Scope: make `cfg.cors` take effect on the real server and prove the WebSocket half of IR-11
against a real store. At the end, a server started by any public starter honours the policy,
and `cabal test kiroku-metrics` is green including three new real-server examples.

In `kiroku-metrics/src/Kiroku/Metrics/Server.hs` import `Kiroku.Metrics.Cors (corsMiddleware)`
and change the composition point:

```haskell
combinedApp cfg m deps mProvider wsApp =
    corsMiddleware cfg.cors $
        WaiWS.websocketsOr WS.defaultConnectionOptions wsApp (httpApp cfg m deps mProvider)
```

Under MasterPlan 13 this plan lands first, so `combinedApp` is the function to wrap; plan 87
later moves the composition into `combinedAppWithProviders` and is bound to keep the wrap. If,
against the recommended order, plan 87 or 88 has already landed and renamed this function, wrap
the function that `startMetricsServerWith'` or its successor hands to Warp; the invariant is
that the value passed to `Warp.runSettings` and `Warp.runSettingsSocket` is the wrapped one.
Verify with
`grep -n "runSettings" kiroku-metrics/src/Kiroku/Metrics/Server.hs` that both call sites use
the application built through the wrapped composition. Update the module header comment (the
server applies the host's CORS policy at the WAI layer to HTTP and WebSocket alike) and the
Haddock of `combinedApp` and `httpApp` (the latter is exported unwrapped; a host mounting it
directly wraps it with `corsMiddleware cfg.cors` itself).

Extend `kiroku-metrics/test/Test/CorsSpec.hs` with `describe "Kiroku.Metrics.Cors (real
server)"`. Reuse the boot sequence of `test/Test/WebSocketSpec.hs`: `withMigratedTestDatabase`,
`newKirokuMetricsWith` over a `TVar (Maybe KirokuStore)`, `withStore` with the metrics handlers
installed, then `startMetricsServerWithStore serverCfg km store []` and `threadDelay 300_000`.
Copy the small `readPosition` and `readSubscribers` helpers rather than importing them (they are
private to the sibling spec). Write a helper
`wsSnapshot :: Int -> RequestHeaders -> IO (Either WS.HandshakeException Text)` that runs
`WS.runClientWith "127.0.0.1" port "/ws/metrics" WS.defaultConnectionOptions headers` under
`timeout 15_000_000`, receives one text frame, decodes it with aeson, and returns its `type`
field, catching `WS.HandshakeException` with `try`. Unwrap timeout explicitly: Nothing fails
the test as a timeout, while Just result returns the Either in the stated signature.

12. With `serverCfg = defaultConfig{port = 0, cors = opsPolicy}`: `GET /metrics` with
    `Origin: ops` through `http-client` returns 200 with `access-control-allow-origin` equal to
    `ops` (proves the middleware is wired into the store-backed starter, not only standalone);
    with `Origin: evil` it returns 200 with no CORS headers; the preflight from `ops` returns
    204.
13. Same server: `wsSnapshot port [("Origin", ops)]` is `Right "snapshot"`;
    `wsSnapshot port [("Origin", evil)]` is `Left _` (record the exact constructor observed in
    Surprises & Discoveries; the plan expects `MalformedResponse` because the refusal is a 403);
    `wsSnapshot port []` is `Right "snapshot"` (IR-11 acceptance 4 and the WebSocket half of 5).
14. With `serverCfg = defaultConfig{port = 0}` (CORS disabled): `wsSnapshot port [("Origin",
    evil)]` is `Right "snapshot"`, pinning that the default keeps today's open WebSocket
    behaviour (acceptance 1 for the WebSocket).

Acceptance for Milestone 2: `cabal test kiroku-metrics` passes with every pre-existing example
plus every revised configuration, cache and integration case, and `nix fmt` leaves the tree unchanged. Behaviourally, in a
`cabal repl kiroku-metrics` session start `withMetricsServerWithStore (defaultConfig{port =
9091, cors = opsPolicy}) m store []` against any migrated store and reproduce the three `curl`
transcripts from Purpose from another shell (there is no `curl` in the Nix dev shell, as plan 52
noted; the tests are the authoritative check, and `websocat -H 'Origin: https://evil.example.com'
ws://localhost:9091/ws/metrics` from a host shell shows the 403 if the tool is available).

### Milestone 3: documentation, example, capability, changelog, and request evidence

Scope: make the feature discoverable and its security posture unambiguous, and record
implementation evidence in the bundles that track this work. At the end, a reader of
`docs/user/metrics.md` can enable browser access, understand what it does and does not protect,
and choose the reverse-proxy alternative instead, and every repository validation passes.

In `docs/user/metrics.md`:

- In the opening deployment callout add one sentence: CORS (below) only tells browsers which
  pages may read responses; it is not authentication, and the trusted-network or
  authenticating-proxy assumption stands with or without it.
- Add a Contents entry "Cross-origin browser access (CORS)".
- In the "Starting the server" table add the row `cors` with default `corsDisabled` and meaning
  "Allowed browser origins for HTTP responses, preflights, and WebSocket upgrades; disabled
  sends no CORS headers and leaves upgrades open."
- Add a section "Cross-origin browser access (CORS)" after "Subscription status over HTTP" and
  before "Try it" containing, in this order: two sentences defining CORS and why a page on
  another origin cannot read `/metrics` today; the configuration snippet from Purpose using
  `allowedOrigin`, `corsAllowOrigins`, and `defaultConfig{cors = ...}` with the note that
  `allowedOrigin` refuses `*`, `null`, and anything with a path, and normalizes case and a
  trailing slash; the three `curl` transcripts from Purpose (preflight, decorated GET,
  undecorated GET from a disallowed origin) copied from a real run; a short list of exactly what
  the middleware does (allowed origin: `Access-Control-Allow-Origin` echoed plus `Vary: Origin`,
  and `Access-Control-Allow-Credentials: true` when enabled; preflight: `204` with
  `GET, HEAD, OPTIONS`, echoed request headers, and `Access-Control-Max-Age` when set;
  disallowed origin or no `Origin`: no grant, unchanged body/status, but Vary includes Origin);
  the WebSocket rule (with origins configured, a
  handshake whose `Origin` is not listed is answered `403` with the
  `{"error":{"code":"origin_not_allowed", ...}}` envelope before any frame is exchanged; a
  handshake with no `Origin` is never affected; with the default configuration upgrades stay
  open to any origin exactly as before); the credentials rule (set `allowCredentials = True`
  when the page sends cookies or an `Authorization` header through an authenticating proxy;
  wildcard grants are unrepresentable, but authentication is still required); the reverse-proxy alternative as a
  paragraph plus an illustrative Caddyfile that serves the UI at `/` and proxies `/kiroku/*` to
  `127.0.0.1:9091` with `handle_path` (which strips the prefix), noting that WebSockets proxy
  through unchanged and that with a single origin no CORS configuration is needed; and a
  stability note that the `origin_not_allowed` envelope keys are published once shipped, per the
  wire-format stability section, while header values are configuration.

Extend `kiroku-metrics/example/Main.hs`: build the config with
`cors = corsAllowOrigins [origin]` where `origin` comes from
`allowedOrigin "https://ops.example.com"`, and after the HTTP checks add one step that sends
`GET /metrics` with `Origin: https://ops.example.com`, checks `Access-Control-Allow-Origin`
echoes it, sends the same with `Origin: https://evil.example.com`, checks no `Access-Control-`
header is present, and prints
`[5/7] CORS: preflight and GET from https://ops.example.com allowed; https://evil.example.com undecorated`.
Renumber the steps and update the quoted transcript in "Try it". If plan 87 has already added
its checkpoint step, insert this one after it and renumber to eight. Run it as
`cabal run -fexample kiroku-metrics-example` from the repository root inside the dev shell; if
cabal reports the flag as unknown for another local package, use
`cabal run --constraint='kiroku-metrics +example' kiroku-metrics-example` and record which form
worked in Surprises & Discoveries.

Update `docs/capabilities/operational-http-endpoints.md` (CAP-17): extend `description` and the
body to say the surface supports host-configured, default-off CORS for browser clients across
HTTP, preflight, and WebSocket upgrades; add `Kiroku.Metrics.Cors` to `interface`; add an
`evidence` entry for `kiroku-metrics/test/Test/CorsSpec.hs` proving default-off byte identity,
allowed-origin decoration, preflight, and WebSocket refusal; add a dated `**Update**: CAP-17 ...`
entry to `docs/capabilities/log.md`. Run `just capabilities-validate`.

Update IR-11's body (status stays `in_progress`): add an "Implementation Evidence" section
naming the module, the configuration field, the middleware semantics, the test file, and the
example, mirroring the completed IR-13 document; advance `timestamp`; add a log entry; validate.

Finalize this plan's bullets in the `## Unreleased` changelog section so they are ready to be
dated by plan 96: Breaking Changes (the `cors` field and the migration hint), New Features (the
module, `AllowedOrigin` and `allowedOrigin`, `CorsPolicy`, `corsMiddleware`, the WebSocket
origin refusal, the `origin_not_allowed` envelope, `errorEnvelope` and `errorResponse`). Do not
date the section, do not edit `version:` in `kiroku-metrics.cabal`, and do not touch any
dependency bound; plan 96 assigns the cohort's versions.

Acceptance for Milestone 3: `nix fmt` is a no-op, `cabal build all`, `cabal test all`, and
`nix build .#kiroku-metrics` succeed, `just capabilities-validate` and the strict
improvement-request validation pass, `git diff --check` is clean, and the example prints its
full passing transcript including the CORS step.

### Milestone 4: ADR distillation and Outcomes

Scope: close this plan's own bookkeeping. The release and the completion of IR-11 are no longer
this plan's work: plan 96 (EP-7 of MasterPlan 13) releases `kiroku-metrics` together with
`kiroku-store` and the other cohort packages after every child of the MasterPlan is complete,
verifies the cohort from a clean consumer, and sets IR-11 to `completed` with release evidence.
Until then IR-11 stays `in_progress` with its "Implementation Evidence" section and the
changelog section stays `## Unreleased`.

Perform the ADR distillation pass required by PLANS.md: reread the Decision Log and Surprises &
Discoveries and decide whether the CORS posture (default-off, explicit origins, wildcard
unrepresentable, WAI-layer enforcement covering WebSocket upgrades) is durable project context
that future routes and sister packages must honour. MasterPlan 13 names it the most likely
candidate because plans 87, 88, 89, and 95 inherit it silently. If so, allocate a record with
`okf id next docs/adr --profile docs/adr/profile.dhall ADR`, write it citing ADR-9 and the
keiro-ui conventions (imitate the frontmatter of `docs/adr/0010-...md`), add the bundle log
entry with `okf log add`, and run `just adr-validate`; if not, record in Outcomes why. Write
Outcomes & Retrospective, and update the MasterPlan's Exec-Plan Registry row for EP-1 to
`Complete` and its Progress entries.

Acceptance for Milestone 4: Outcomes & Retrospective is written, the ADR bundle validates
whether or not a record was added, this plan's Progress shows every item checked, and the
MasterPlan registry shows EP-1 complete.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` inside the Nix dev
shell (`nix develop`, or the direnv-loaded shell from `.envrc`).

Establish a clean baseline first:

```bash
git status --short --branch
cabal build kiroku-metrics
cabal test kiroku-metrics
```

Expected: a clean tree on `master` (untracked plan files from concurrent sessions are fine),
and the existing suite passing with zero failures. If the baseline fails, stop and record it
before changing anything.

Milestone 1 edits and checks:

```bash
# edit docs/improvement-requests/add-configurable-cors-support-to-kiroku-metrics.md  (status: in_progress, timestamp, Status paragraph)
# edit docs/improvement-requests/log.md                                              (dated Implementation entry)
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
# write kiroku-metrics/src/Kiroku/Metrics/Cors.hs
# edit kiroku-metrics/src/Kiroku/Metrics/JSON.hs        (+ errorEnvelope, errorResponse)
# edit kiroku-metrics/src/Kiroku/Metrics/Config.hs      (+ cors field; defaultConfig)
# edit kiroku-metrics/src/Kiroku/Metrics.hs             (+ module re-export)
# edit kiroku-metrics/kiroku-metrics.cabal              (+ exposed module; test other-modules; test deps wai, case-insensitive)
# write kiroku-metrics/test/Test/CorsSpec.hs            (configuration + standalone middleware examples)
# edit kiroku-metrics/test/Main.hs                      (+ CorsSpec.spec)
# edit kiroku-metrics/CHANGELOG.md                      (## Unreleased: Breaking Changes, New Features)
nix fmt
cabal build kiroku-metrics
cabal test kiroku-metrics --test-options='--match Cors'
```

Expected tail of the focused run:

```text
Kiroku.Metrics.Cors (configuration)
  accepts an https origin, lowercases it, and strips one trailing slash [✔]
  rejects the wildcard, the opaque null origin, and values with a path, query, or fragment [✔]
  rejects values without a scheme, without a host, or with whitespace [✔]
Kiroku.Metrics.Cors (middleware, standalone)
  leaves every response byte-for-byte untouched when no origin is configured [✔]
  answers a preflight from an allowed origin with 204 and the allow headers [✔]
  decorates an actual response from an allowed origin with allow-origin and Vary [✔]
  adds Vary without granting a disallowed origin [✔]
  varies enabled no-Origin responses and preserves disabled identity [✔]
  matches origins case-insensitively, tolerates a trailing slash, and is port-sensitive [✔]
  adds credentials and max-age headers only when configured [✔]
  refuses a WebSocket upgrade from a disallowed origin with a 403 envelope and passes others through [✔]

Finished in 0.6 seconds
11 examples, 0 failures
```

Commit with the MasterPlan, plan, and intention trailers (every commit under this plan carries
all three):

```text
feat(kiroku-metrics)!: add a host-configured CORS policy and middleware

BREAKING CHANGE: MetricsServerConfig gains a `cors` field (default
corsDisabled); positional constructions must supply it.

MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md
ExecPlan: docs/plans/90-add-configurable-cors-support-to-kiroku-metrics.md
Intention: intention_01m24n4q6verjrhrk58qt6gbh2
```

Milestone 2 edits and checks:

```bash
# edit kiroku-metrics/src/Kiroku/Metrics/Server.hs   (corsMiddleware cfg.cors around the combined app; Haddocks)
grep -n "runSettings\|corsMiddleware" kiroku-metrics/src/Kiroku/Metrics/Server.hs   # both Warp calls receive the wrapped app
# edit kiroku-metrics/test/Test/CorsSpec.hs           (three real-server examples)
nix fmt
cabal build kiroku-metrics
cabal test kiroku-metrics
```

Expected focused tail (`--match "real server"`):

```text
Kiroku.Metrics.Cors (real server)
  serves GET /metrics with allow-origin through startMetricsServerWithStore [✔]
  upgrades /ws/metrics for an allowed origin, refuses a disallowed one, and ignores an absent Origin [✔]
  keeps WebSocket upgrades open to any origin when CORS is disabled [✔]

3 examples, 0 failures
```

Commit as `feat(kiroku-metrics): apply the CORS policy to every starter and WebSocket upgrade`
with the three trailers.

Milestone 3 edits and checks:

```bash
# edit docs/user/metrics.md
# edit kiroku-metrics/example/Main.hs
# edit docs/capabilities/operational-http-endpoints.md, docs/capabilities/log.md
# edit docs/improvement-requests/add-configurable-cors-support-to-kiroku-metrics.md, docs/improvement-requests/log.md
# edit kiroku-metrics/CHANGELOG.md
cabal run -fexample kiroku-metrics-example
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
git diff --check
git status --short
```

Expected example transcript (port varies; step count is eight if plan 87's step landed first):

```text
[1/7] ephemeral postgres ready
[2/7] store + collector + metrics server on port 57277
[3/7] appended 3 events to orders-1
[4/7] HTTP /metrics, /prometheus, /health/live, /health/ready all OK
[5/7] CORS: preflight and GET from https://ops.example.com allowed; https://evil.example.com undecorated
[6/7] WebSocket /ws/events received event eventType=OrderRefunded
[7/7] kiroku-metrics-example: all checks passed (snapshot global position = 4)
```

Commit as `docs(kiroku-metrics): document configurable CORS and the reverse-proxy alternative`
with the three trailers (one commit for docs and example, one for the bundles is also fine).

Milestone 4:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR   # only if the distillation pass warrants the CORS-posture record
# write docs/adr/00NN-<slug>.md; okf log add docs/adr --kind Addition -m "..."
just adr-validate
# edit docs/plans/90-add-configurable-cors-support-to-kiroku-metrics.md   (Outcomes & Retrospective, Progress)
# edit docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md   (EP-1 Complete; Progress)
```

Commit as `docs(plans): complete plan 90 and mark EP-1 done in MasterPlan 13` (and
`docs(adr): ...` if a record was added) with the three trailers. The release, the
clean-consumer check, and `docs(improvement-requests): complete IR-11` belong to plan 96.


## Validation and Acceptance

The reviewed API, lifecycle and performance obligations in Context and Plan of Work are
mandatory in addition to the route-specific cases below. Historical transcripts are examples,
not evidence that the new tests have run; update counts from actual output at implementation.

The revised Milestone 1 cache, parser and method tests are mandatory. Network identity
comparisons exclude Warp-generated Date headers; disabled application responses remain exact.
Enabled responses without a grant still carry Vary: Origin. Test default-off construction
and fixed precomputed policy state; no per-request origin-list rebuild or DB call is accepted.

The plan is accepted when all of the following are observable:

1. With `defaultConfig`, every response, with or without an `Origin` header, and every
   WebSocket upgrade regardless of `Origin`, is byte-for-byte what it is at commit `4a1b98a`
   (examples 4, 8, 14; IR-11 acceptance 1 and 5).
2. With `https://ops.example.com` configured, `OPTIONS /metrics` with that `Origin` and
   `Access-Control-Request-Method: GET` returns 204 with `Access-Control-Allow-Origin:
   https://ops.example.com`, and `GET /metrics` with that `Origin` returns 200 carrying the same
   header (examples 5, 6, 12; acceptance 2).
3. The same two requests with `Origin: https://evil.example.com` carry no `Access-Control-`
   header and are otherwise identical to requests without `Origin` (example 7; acceptance 3).
4. With `https://ops.example.com` configured, a WebSocket handshake on `/ws/metrics` with that
   `Origin` receives a `snapshot` frame, one with `Origin: https://evil.example.com` fails with
   an HTTP 403 whose body is the `origin_not_allowed` envelope, and one with no `Origin`
   receives a `snapshot` (examples 11, 13; acceptance 4 and 5).
5. `allowedOrigin "*"` and `allowedOrigin "null"` are `Left`, so no policy can combine a
   wildcard with `allowCredentials = True` (examples 2, 10; acceptance 6).
6. Every pre-existing endpoint, frame, and body is unchanged: the existing specs pass without
   assertion edits, and `git diff` shows no change under
   `kiroku-metrics/src/Kiroku/Metrics/{Subscriptions,WebSocket,Prometheus,Health,Types,Collector}.hs`.
7. `docs/user/metrics.md` contains the CORS section with the three transcripts, the WebSocket
   rule, the credentials rule, and the reverse-proxy alternative; CAP-17 and IR-11 are updated
   and their bundles validate; the example prints its transcript with the CORS step.
8. Outcomes & Retrospective is written and the MasterPlan registry shows EP-1 complete. (The
   Hackage release, the clean-consumer check, and IR-11's `completed` status are plan 96's
   acceptance, not this plan's.)


## Idempotence and Recovery

All source and documentation edits are additive or mechanical and can be re-applied; `nix fmt`,
`cabal build`, `cabal test`, `okf validate`, and the example are safe to rerun. The middleware is
stateless and the endpoints are read-only, so repeating any request or test is always safe.
Tests use OS-assigned ports (`testWithApplication` and `port = 0`) and, where a store is needed,
a fresh migrated database per example, so reruns cannot collide.

If a concurrent plan (87, 88, or 89) lands between milestones and changes `Server.hs`,
re-apply the single wrapping edit at the new composition point and re-run the real-server
examples; the `grep` for `runSettings` in Milestone 2 is the check. If `Kiroku.Metrics.JSON`
already has `errorEnvelope`/`errorResponse` because a sibling ran ahead of the recommended
order, keep the one definition with the details-carrying type. If the example's step numbering
conflicts, renumber and re-quote the transcript.

The IR and capability bundle edits are validated by strict profile checks; if validation fails
after an edit, the message names the offending field (typically a `timestamp` that did not
advance or a missing dated log entry) and the fix is local. Keep `status: in_progress` until the
release evidence exists; never set `completed` on the strength of a local build.

Publishing is not idempotent. Before retrying a partially failed release, inspect Hackage, local
and upstream tags, and `git status` to see which step succeeded, and follow the release skill's
recovery guidance; never reuse a version for different contents or move a pushed tag (plan 69
recorded the `kiroku-metrics-v0.1.0.2` incident that established this rule). If the release is
declined or deferred, Milestones 1 to 3 remain complete and valid on `master`, the changelog
section stays `## Unreleased`, and IR-11 stays `in_progress` with its evidence.


## Interfaces and Dependencies

At the end of Milestone 1, `kiroku-metrics` exposes:

```haskell
-- Kiroku.Metrics.Cors (new module)
newtype AllowedOrigin                                   -- abstract; Eq, Show
allowedOrigin :: Text -> Either OriginError AllowedOrigin
renderAllowedOrigin :: AllowedOrigin -> Text
data OriginError
    = WildcardOrigin | OpaqueOrigin | MissingScheme Text | EmptyHost Text
    | HasPathQueryOrFragment Text | NotAnOrigin Text     -- Eq, Show

data CorsPolicy = CorsPolicy
    { allowedOrigins :: ![AllowedOrigin]
    , allowCredentials :: !Bool
    , maxAgeSeconds :: !(Maybe Int)
    }                                                   -- Eq, Show
corsDisabled :: CorsPolicy
corsAllowOrigins :: [AllowedOrigin] -> CorsPolicy
corsEnabled :: CorsPolicy -> Bool
corsAllowedMethods :: ByteString                        -- "GET, HEAD, OPTIONS"

corsMiddleware :: CorsPolicy -> Network.Wai.Middleware
originAllowed :: CorsPolicy -> ByteString -> Bool
isPreflight :: Network.Wai.Request -> Bool

-- Kiroku.Metrics.JSON (addition; owned by this plan, reused by plans 87, 88, 89, 95)
errorEnvelope :: Text -> Text -> Maybe Data.Aeson.Value -> Data.Aeson.Value
errorResponse :: Network.HTTP.Types.Status -> Text -> Text -> Maybe Data.Aeson.Value -> Network.Wai.Response

-- Kiroku.Metrics.Config (changed datatype)
data MetricsServerConfig = MetricsServerConfig { ..., cors :: !CorsPolicy }
defaultConfig :: MetricsServerConfig                    -- cors = corsDisabled
```

At the end of Milestone 2 no signature changes; `combinedApp` (or its successor) returns the
application wrapped in `corsMiddleware cfg.cors`, and every public starter therefore honours
`cfg.cors`. `httpApp` remains exported unwrapped.

Wire contract owned by this plan (frozen once released, per ADR-9): the refused WebSocket
upgrade body

```json
{ "error": { "code": "origin_not_allowed", "message": "..." } }
```

with HTTP 403 and `Content-Type: application/json`. Response headers emitted for an allowed
origin are `Access-Control-Allow-Origin` (echo), `Vary: Origin`, and optionally
`Access-Control-Allow-Credentials: true`; preflights add `Access-Control-Allow-Methods`,
optionally `Access-Control-Allow-Headers` (validated echo), and optionally `Access-Control-Max-Age`.
Enabled ordinary responses without a grant still vary on Origin; reflected preflights also
vary on the requested method and header names. Disabled responses are unchanged.

Dependencies: no new library dependency. The library already depends on `aeson`, `bytestring`,
`text`, `http-types`, `wai`, `wai-websockets`, `warp`, and `websockets`; the test suite gains
`wai` and `case-insensitive`, both already in the build closure. `kiroku-store` and `kiroku-cli`
are unchanged and unreleased by this plan. The only runtime service is PostgreSQL with the
existing Kiroku migrations, and only for the real-server examples. Locate dependency sources
through `mori registry show <project> --full` (for example `yesodweb/wai`) when behaviour is
uncertain; for `websockets`, `http-types`, and `http-client`, which are not in the corpus, unpack
the exact versions from `dist-newstyle/cache/plan.json` out of `~/.cabal/packages`; do not
inspect `/nix/store`.

Dependency direction is unchanged: `kiroku-metrics` depends on `kiroku-cli` and `kiroku-store`;
nothing depends on `kiroku-metrics`. No `.cabal` `version:` line and no dependency bound
changes in this plan; plan 96 assigns the cohort's versions.


## Revision Notes

- 2026-09-30: Adopted as EP-1 of MasterPlan 13 (`master_plan` added to the frontmatter) and
  ordered first. This plan now owns the cohort's structured error envelope as the
  details-carrying `errorEnvelope`/`errorResponse` pair; its wrap around the composed
  application is recorded as an invariant plan 87 preserves; the release milestone and IR-11's
  `completed` transition moved to plan 96, so this plan bumps no version and edits no bound and
  Milestone 4 is now the distillation pass. Milestones 1, 2, 3, and 4, the Progress list, the
  Decision Log, Concrete Steps, Validation, Idempotence, and Interfaces were updated; the CORS
  behaviour, the wire shape, and the tests are unchanged.


## API and performance review revision (2026-10-10)

Reviewed against repository HEAD `f1a0209` and the released typed-decoding implementation. Corrected integration contracts and made focused performance evidence a completion gate. Existing authorship history is preserved; this revision records no implemented milestone or accepted performance result. The active requirements above supersede incompatible September design decisions, not published wire contracts.
