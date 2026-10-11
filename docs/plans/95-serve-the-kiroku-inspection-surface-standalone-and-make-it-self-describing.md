---
id: 95
slug: serve-the-kiroku-inspection-surface-standalone-and-make-it-self-describing
title: "Serve the Kiroku inspection surface standalone and make it self-describing"
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
      at: 2026-10-10T15:41:07Z
      mode: "update"
      note: "Correct current APIs, integration ownership and bounded observer work; runtime acceptance remains pending."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-11T02:39:50Z
      mode: "implement"
      note: "Implement capability discovery and standalone inspection with focused lifecycle and composition checks."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T15:41:07Z
      verdict: "comments"
      note: "Source review corrections applied; SQL promotion and focused performance gates require implementation evidence."
---

# Serve the Kiroku inspection surface standalone and make it self-describing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is child EP-6 of
[MasterPlan 13, Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md).
The MasterPlan's other children add the routes a browser needs to `kiroku-metrics`: plan 90
(CORS, IR-11), plan 87 (durable checkpoints over HTTP, IR-10), plan 88 (the browse read API,
IR-8), plan 89 (dead-letter reads, IR-9), and plan 94 (WebSocket convergence, IR-12). Those
requests were filed by the keiro runtime UI initiative, which composes Kiroku's surface into a
console for applications built on the whole keiro stack. This plan serves the second audience the
MasterPlan names: someone who adopts only the event store and wants a browser UI for it without
writing a Haskell host program and without keiro. Every commit made under this plan carries three
trailers: `MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md`,
`ExecPlan: docs/plans/95-serve-the-kiroku-inspection-surface-standalone-and-make-it-self-describing.md`,
and `Intention: intention_01m3t7a7jaeewbf71vqrzk4zd8`.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store written in Haskell. Its HTTP sister package,
`kiroku-metrics`, is a library: a host application that already owns a `KirokuStore` calls a
starter such as `withMetricsServerWithStore`, and a small Warp server appears on port 9091
serving metrics, health probes, the live subscription registry, a WebSocket event tail, and, once
the sibling plans land, stream browsing, durable checkpoints, and dead letters. Two things are
still missing for a browser UI that is not part of a keiro application. First, there is no way to
run that surface without writing Haskell: a team that adopts `kiroku-store` and wants to point a
browser at their store has to build and wire a program. Second, a UI cannot tell what the server
it is talking to actually offers. A server started without a store answers browse routes with a
`404`, a process that runs no subscriptions answers `GET /subscriptions` with an empty list, and
the only way to learn which is which is to probe every route and interpret its error.

After this plan, an operator with nothing but a migrated Kiroku database can run:

```bash
DATABASE_URL='postgresql://localhost/kiroku' kiroku-inspect --port 9091 --cors-origin http://localhost:5173
```

and see:

```text
kiroku-inspect: connected to schema "kiroku"; listening on port 9091
kiroku-inspect: routes browse=on subscriptions_checkpoints=on dead_letters=on subscriptions_live=on websocket_events=on cors=on
kiroku-inspect: this process runs no subscriptions; /subscriptions, /metrics, and /health reflect only this process
```

A browser page served from `http://localhost:5173` can then call every read route and open the
event tail. Any client, on any server built from this package, can first ask:

```bash
curl -s http://localhost:9091/capabilities | jq .
```

```json
{
  "package": "kiroku-metrics",
  "version": "0.2.0.0",
  "routes": {
    "metrics": true,
    "prometheus": true,
    "health": true,
    "subscriptions_live": true,
    "subscriptions_checkpoints": true,
    "dead_letters": true,
    "browse": true,
    "websocket_metrics": true,
    "websocket_events": true
  },
  "cors": { "enabled": true },
  "process_local": ["metrics", "prometheus", "health", "subscriptions_live", "websocket_metrics"]
}
```

and render only the screens the server can back, marking the panels that reflect one process. A
new guide, `docs/guides/building-an-inspection-ui.md`, maps each UI screen to the routes that
serve it, so the keiro runtime UI's client package and an independent Kiroku UI are built against
the same, documented contract. Nothing the keiro runtime UI already composes changes: every
existing route, frame, body, and starter keeps its published shape, and the WAI application that
keiro mounts behind a path prefix stays a plain value with relative paths.


## Progress

- [x] (2026-10-10) Reviewed the integrated design against current source; corrected API and performance hazards. This is planning work, not implementation evidence.
- [x] (2026-10-11) Implement and execute the focused correctness and performance acceptance added by this review.

- [x] (2026-10-10) M0: verify every hard dependency is complete in the working tree (`ServerProviders` with
      `webSocketServer`, `subscriptionStatus`, `checkpointInventory`, `storeBrowsing`, `deadLetters`;
      the modules `Kiroku.Metrics.Cors`, `Kiroku.Metrics.Checkpoints`, `Kiroku.Metrics.Browse`,
      `Kiroku.Metrics.DeadLetters`; `errorEnvelope`/`errorResponse` in `Kiroku.Metrics.JSON`);
      record the observed state in Surprises & Discoveries and stop if anything is missing.
- [x] (2026-10-10) M1: `Kiroku.Metrics.Capabilities` module (`WebSocketChannels`, `ProviderPresence`,
      `RouteAvailability`, `Capabilities`, `capabilitiesFor`, `kirokuMetricsVersion`,
      `capabilitiesApp`) with hand-written JSON codec; `Paths_kiroku_metrics` wired into the
      library stanza.
- [x] (2026-10-10) M1: additive `webSocketChannels :: !WebSocketChannels` field on `ServerProviders`; the
      `/capabilities` arm mounted in `httpAppWithProviders` ahead of the catch-all; every starter
      declares its channels truthfully; umbrella re-export; changelog `Unreleased` bullets.
- [x] (2026-10-10) M1: `kiroku-metrics/test/Test/CapabilitiesSpec.hs` (codec pin, standalone mount, plain
      server, store-backed server, `enableJSON = False`, non-GET); registered; suite green.
- [x] (2026-10-10) M2: `Kiroku.Metrics.Standalone` module (`InspectOptions`, `inspectOptionsParser`,
      `inspectParserInfo`, `resolveInspectOptions`, `InspectRuntime`, `InspectHooks`,
      `runInspect`, `renderStartupBanner`); `optparse-applicative` added to the library
      `build-depends`.
- [x] (2026-10-11) M2: `executable kiroku-inspect` stanza with `app-inspect/Main.hs` (signal handling,
      exit codes); `cabal build kiroku-metrics:exe:kiroku-inspect`, `cabal check`, `cabal sdist`,
      and `nix build .#kiroku-metrics` all succeed.
- [x] (2026-10-10) M2: `kiroku-metrics/test/Test/StandaloneSpec.hs` (parser and resolution examples, one
      end-to-end run against a real database, one CORS run); registered; suite green.
- [x] (2026-10-10) M3: `docs/guides/building-an-inspection-ui.md` written and indexed in
      `docs/guides/README.md`; `docs/user/metrics.md` gains "Discovering the surface" and
      "Running the standalone server"; `docs/user/operator-cli.md` distinguishes `kiroku` from
      `kiroku-inspect`; `docs/user/README.md` summary line updated.
- [x] (2026-10-10) M3: `kiroku-metrics/example/Main.hs` checks `/capabilities`; the quoted transcript in
      `docs/user/metrics.md` updated; CAP-17 and `docs/capabilities/log.md` updated;
      `just capabilities-validate` green; changelog `Unreleased` finalized for this plan's scope.
- [x] (2026-10-11) M4: ADR allocated with `okf id next`, written, logged, `just adr-validate` and the strict
      validation green; Outcomes & Retrospective written; closing provenance revision recorded.


## Surprises & Discoveries

- 2026-10-10 packaging recovery: the first Nix invocation was interrupted after about eight minutes waiting on configured remote building; it also predated the final HEAD/error and shared-discovery closure changes. Its log is retained. The final check uses `--builders '' --max-jobs 2 -L`, preserving visible local compilation progress and testing finished source. This is packaging recovery, not a performance sample or a new benchmark budget.

- 2026-10-10 lifecycle evidence: standalone tests add occupied-port, immediate shutdown, hook failure, cancellation and real SIGINT/SIGTERM cases. Existing `CheckpointsSpec` again tests unexpected server termination and cancellation at acquisition; `runInspect` uses that unchanged supervised bracket directly and adds no exception-swallowing layer. The collector allocates STM state only, with no collector thread to stop.

- 2026-10-10 implementation: focused discovery passed 7 examples; standalone options/lifetime passed 8; executable exit/signal checks passed 3. The integrated metrics suite passed 116 examples (14.0858s), with every pre-existing assertion retained. Final package, full-repository and Nix checks remain in progress.
- 2026-10-10 packaging: the existing Nix overlay erased every executable dependency to exclude the unpublished example. It now keeps the published `kiroku-inspect` dependencies while the example remains disabled. Cabal package checking reported no errors or warnings.

- 2026-10-10 implementation baseline: all five predecessors are Complete; the five provider fields and CORS/error helpers are present. The browse field is `storeBrowsing`, retained throughout this implementation. `cabal test kiroku-metrics -j1` passed 98 examples (11.3455s); log `/tmp/mp13-ep6-baseline.log`.

- 2026-10-10 source review: The onListening sketches disagreed on arity and could run before bind success. Exported record selectors collided across the umbrella module; a Bool credentials switch could not override an environment True with False. No runtime acceptance is inferred from this finding.

(None yet.)


## Decision Log

- Decision (2026-10-10 implementation): preserve `storeBrowsing`, include Prometheus in the fixed process-local list, and use persistent `Catch` signal handlers with `tryPutMVar` so repeated signals cannot restore a terminating default or block. NoFieldSelectors prevents exported function clashes, but record labels still require qualified updates; two pre-existing tests receive only mechanical qualification, with every assertion unchanged.

- Decision (2026-10-10 implementation): proportional evidence is the 98-example baseline, discovery provider non-invocation assertions, and the real standalone lifecycle/read path. No store/publisher/migration code changes or additional index/append cost are introduced; cumulative release performance acceptance remains plan 96.

- Decision (2026-10-10): the reviewed Context and Plan of Work supersede incompatible September choices on dependencies, routes, decoding, method handling, bounds and performance. Implementation remains pending; durable constraints are in ADR-15.
  Rationale: the released APIs changed and the original sketches contained correctness and shared-resource hazards.

- Decision: The discovery route is `GET /capabilities`, served by a new module
  `Kiroku.Metrics.Capabilities`, mounted in the router ahead of the catch-all, and answered
  regardless of `enableJSON`, `enablePrometheus`, or `enableWebSocket`.
  Rationale: A route whose purpose is to say what is enabled cannot itself be disabled by the
  flags it reports, or a client could not distinguish "JSON disabled" from "not this package".
  The path is a single literal segment that collides with no existing or planned route
  (`/metrics`, `/health`, `/subscriptions`, `/streams`, `/categories`, `/events`, `/ws`).
  `/about` and `/` were considered; `/` is the path a reverse proxy most often rewrites, and
  `/about` reads as prose, not machine-readable discovery.
  Date: 2026-09-30

- Decision: The response is one JSON object with the keys `package`, `version`, `routes`, `cors`,
  and `process_local`; `routes` is an object of booleans keyed `metrics`, `prometheus`, `health`,
  `subscriptions_live`, `subscriptions_checkpoints`, `dead_letters`, `browse`,
  `websocket_metrics`, `websocket_events`; `cors` is `{"enabled": <bool>}` and never lists
  origins; `process_local` is a constant array of the route keys whose answers describe only the
  answering process. No value is an absolute URL.
  Rationale: Booleans keyed by the same names the user guide uses let a client switch screens on
  and off without a second vocabulary. The origin list is configuration, not something a caller
  should learn from the wire. `process_local` exists because a standalone server truthfully
  answers `GET /subscriptions` with `[]` and `GET /metrics` with no subscriptions, and a UI must
  be able to explain that emptiness rather than report it as a fault. Relative-only content keeps
  the body correct when keiro mounts the application behind `/kiroku` (keiro's request
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`). The keys are snake_case per
  [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
  and become a published contract on release, so the codec test pins them.
  Date: 2026-09-30

- Decision: The two WebSocket flags are derived from a new additive field
  `webSocketChannels :: !WebSocketChannels` on `ServerProviders`, declared by whoever builds the
  providers, combined with `cfg.enableWebSocket`. `storeServerProviders` and
  `startMetricsServerWithStore` declare both channels; `defaultServerProviders`,
  `startMetricsServer`, `withMetricsServer`, and `withMetricsServerSubscriptions` declare none
  (they mount the rejecting stub); the legacy `startMetricsServerWith` and
  `startMetricsServerWith'`, whose WebSocket app is caller-supplied and opaque, declare none and
  the user guide says so.
  Rationale: A `WS.ServerApp` is a function; the record cannot inspect whether it is the real
  `websocketApp` or the stub, so the only honest report is a declaration made at the point where
  the app is chosen. The record was introduced by plan 87 precisely so later plans add fields
  additively; the field defaults to "none", so a false negative is the worst outcome for a host
  that supplies its own app through a legacy starter, never a false positive. Alternatives:
  reporting `enableWebSocket` alone (a lie for every stub server), or probing the app at startup
  with a synthetic upgrade (fragile, and it would exercise connection limits).
  Date: 2026-09-30

- Decision: The version string comes from the cabal-generated `Paths_kiroku_metrics` module
  (`Data.Version.showVersion Paths_kiroku_metrics.version`), exposed to callers and tests as
  `kirokuMetricsVersion :: Text`.
  Rationale: It is the one source that cannot drift from the released package. No package in the
  repository uses a `Paths_` module today, so the plan spells out the `autogen-modules` and
  `other-modules` entries the library stanza needs.
  Date: 2026-09-30

- Decision: The standalone server is an executable named `kiroku-inspect` inside the
  `kiroku-metrics` package, always buildable (no cabal flag), with every piece of logic in a
  library module `Kiroku.Metrics.Standalone` and a thin `app-inspect/Main.hs`.
  Rationale: It cannot live in `kiroku-cli`: `kiroku-metrics` depends on `kiroku-cli` for the
  `/subscriptions` row codec, so the reverse dependency would be a cycle. A new package would
  cost a release train for one executable. The `kiroku` binary is documented as a pure remote
  client that opens no database, so folding a database-owning server into it would contradict
  `docs/user/operator-cli.md`. The example executable in this package is flag-gated only because
  it depends on `kiroku-test-support` and `ephemeral-pg`, which are not on Hackage and have no
  buildable source in the pinned Nix set; `kiroku-inspect` depends only on published packages
  (`base`, `kiroku-metrics`, `optparse-applicative`, `text`, `unix`), so it is safe to build
  unconditionally under both Cabal and `nix build .#kiroku-metrics`. The name says what it does
  (inspect a store) and does not claim to be the operator CLI.
  Date: 2026-09-30

- Decision: Options and their environment fallbacks are `--database-url` (`DATABASE_URL`, the
  same variable `kiroku-store-migrate` and the Justfile use; required), `--schema`
  (`KIROKU_INSPECT_SCHEMA`, default `kiroku`), `--pool-size` (`KIROKU_INSPECT_POOL_SIZE`, default
  the library's `defaultConnectionSettings` value, 10), `--port` (`KIROKU_INSPECT_PORT`, default
  9091, `0` means an OS-assigned port that is printed), `--cors-origin` repeatable
  (`KIROKU_INSPECT_CORS_ORIGINS`, comma-separated), `--cors-allow-credentials`
  (`KIROKU_INSPECT_CORS_ALLOW_CREDENTIALS=true`), and `--ws-max-connections`
  (`KIROKU_INSPECT_WS_MAX_CONNECTIONS`, default 100). A flag wins over its variable; resolution is
  one pure function so it is testable without a process.
  Rationale: This is the shape `Kiroku.Cli.Standalone.resolveStandaloneOptions` already uses
  (`--remote-url` over `KIROKU_REMOTE_URL`), and `DATABASE_URL` is what an operator of this
  repository already exports for migrations. Origins are validated through `allowedOrigin` from
  plan 90 so the wildcard is refused before any socket opens.
  Date: 2026-09-30

- Decision: No `--bind` option. `startMetricsServerWith'` binds with `Warp.setHost "*"` (every
  IPv4 and IPv6 interface) and `MetricsServerConfig` has no host field; adding one is a
  constructor change to a record shared by every host and belongs to the MasterPlan, not to a
  child that only consumes the configuration.
  Rationale: The user guide's deployment note says to bind the server to an internal interface,
  which the package cannot express today; that gap predates this plan. This plan documents the
  limitation in the standalone section and in the ADR's exclusions, and the MasterPlan is told
  so it can decide whether a follow-up request is warranted. Widening this plan into a
  configuration change would couple it to every sibling that constructs the record.
  Date: 2026-09-30

- Decision: `runInspect` takes an `InspectHooks` record with `onListening :: Int -> Capabilities -> IO ()`
  (called once with the bound port) and `waitForShutdown :: IO ()` (returns when the process
  should stop); `app-inspect/Main.hs` supplies a hook that waits for `SIGINT` or `SIGTERM`
  through the `unix` package, and the test supplies `MVar`-based hooks.
  Rationale: The server must be started in-process by a test on port `0`, learn the port, and be
  stopped deterministically; a callback and a blocking action are the smallest seam that makes
  the executable's real code path testable. Handling `SIGTERM` matters because container
  runtimes send it, and a clean return lets `withStore`'s bracket release the pool and the
  notifier's `LISTEN` connection. `unix` is a GHC boot library, so it adds nothing to the Nix
  closure; it is an executable-only dependency so the library stays portable.
  Date: 2026-09-30

- Decision: A standalone process runs no subscriptions and says so on startup and in the
  documentation: `/subscriptions` answers `200 []`, `/metrics` has an empty `subscriptions`
  map, readiness reflects only the PostgreSQL ping, while `/subscription-checkpoints`, the
  dead-letter route, the browse routes, and the `/ws/events` tail are authoritative because they
  read the database. `storeServerProviders` is used so `/subscriptions` answers `200 []` rather
  than the configured `404`.
  Rationale: The truthful answer for "which workers run here" is "none", and a UI reading
  `/capabilities` can see `subscriptions_live` in `process_local`. Answering `404` would make the
  standalone server look misconfigured. The durable inventory is the cross-process truth the
  keiro runtime UI direction already prefers.
  Date: 2026-09-30

- Decision: The guide lives at `docs/guides/building-an-inspection-ui.md`, next to the other
  task-oriented guides, and the user reference `docs/user/metrics.md` gains two sections rather
  than a second reference page.
  Rationale: `docs/guides/README.md` defines guides as end-to-end scenarios and `docs/user/` as
  per-surface reference; building a UI is a scenario that spans every route, while discovery and
  the standalone server are reference facts about this package.
  Date: 2026-09-30

- Decision: This plan bumps no version and publishes nothing. `kiroku-metrics` keeps its
  `## Unreleased` changelog section, which plan 96 dates and releases as 0.3.0.0 for the whole
  cohort.
  Rationale: The MasterPlan releases the cohort once so the keiro runtime UI pins one version
  set, and a PVP major is already forced by the siblings' `MetricsServerConfig` and
  `ServerProviders` changes.
  Date: 2026-09-30

- Decision: One ADR is written at the end of this plan (handle allocated by `okf id next` at that
  time; `ADR-11` was the next free handle when the plan was written) recording that the server
  never holds the store, that store-backed routes enter through the additive `ServerProviders`
  record of closures, that `combinedAppWithProviders` is the prefix-mountable unit keiro composes,
  that the surface is self-hosting through `kiroku-inspect` and self-describing through
  `/capabilities`, and the deliberate exclusions.
  Rationale: These are cross-plan boundaries that every future route and sister package inherits
  silently; ADR-9 covers wire stability but not composition, hosting, or discovery. Writing the
  record last lets it cite evidence rather than intent.
  Date: 2026-09-30


## Outcomes & Retrospective

2026-10-11 completion: EP-6 is Complete locally. `/capabilities` describes actual provider wiring without database reads, and `kiroku-inspect` opens a migrated store, runs no subscription workers and serves the complete read surface. The reusable parser validates CLI/environment precedence, bounds and explicit credential disabling; signal and failure paths release the bracketed lifetime. The UI guide maps every screen to its route, retains mount prefixes and lossless cursors, and explains safe overflow recovery and process-local annotations.

All six Cabal suites passed 672 examples (store 448, metrics 116, CLI 22, OTel 17, migrations 24, adapter 45). A final seven-case discovery run passed after adding explicit 404/405 code assertions; production source was unchanged. The eleven-step example passed, an external umbrella consumer compiled, `cabal check` was clean, and the final sdist contains the executable. The finished runtime source built under local Nix and the installed binary's help ran. Capability and ADR checks passed, including strict ADR-18 validation. Evidence, initial failures and the interrupted remote-builder packaging attempt are retained in `kiroku-metrics/bench/results/mp13-ep6-standalone-discovery/README.md` with 29 artifacts plus a manifest and ten source fingerprints.

Functional implementation is committed as `7f9e4f0`. This child changes no store/migration/CLI code, append SQL, index or publisher logic, and discovery tests prove it invokes none of its four providers. These are proportional focused/structural checks, not a new statistical write-cost claim. Plan 96 still owns cumulative observer-under-append acceptance, PVP/version derivation and publication; the earlier index policy verdict stays inconclusive. IR statuses remain in_progress. ADR-18 distills composition, hosting, truthful discovery and explicit exclusions; ADR-15 continues to govern cost and lifecycle constraints.

Historical 2026-10-10 planning review: implementation and performance acceptance were pending. Static review does not prove zero runtime regression. Earlier planning-time observations and dated decisions are historical where this revision explicitly replaces them.




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

A **WAI `Application`** is the standard Haskell value a web server such as Warp runs: a
function from a request and a response callback to an `IO` action. `kiroku-metrics` builds one
router application from small per-route applications and mounts it on Warp; the same value can
be mounted by another server behind a path prefix, which is what "composable" means here. A
**provider closure** is an `IO` action, or a function returning one, that the host supplies so
the server can fetch store-backed data without holding the `KirokuStore` itself. The **live
registry** is the in-memory map of subscription workers running in one process, read through
`Kiroku.Store.Subscription.subscriptionStates`; the **durable checkpoint inventory** is the
database fact read through `subscriptionCheckpointInventory`, identical from every process. A
**standalone** server is one that opens its own store from a database URL and runs no
subscriptions. **CORS** (Cross-Origin Resource Sharing) is the browser rule that a page from one
origin may not read a response from another origin unless the server opts in with headers; plan
90 added the policy and middleware this plan configures from the command line. **PVP** is the
Haskell Package Versioning Policy. An **OKF bundle** is a directory of Markdown concept files with
YAML frontmatter validated by the `okf` tool against a profile; `docs/adr/` and
`docs/capabilities/` are two such bundles.

### Hard dependencies and what they leave in the tree

This plan starts only after all five predecessors are complete, because it serves and describes
what they add. The four HTTP/provider dependencies below and plan 94's WebSocket convergence are verified together. Milestone 0 verifies each of these in the working tree before any edit:

- Plan 90 (`docs/plans/90-add-configurable-cors-support-to-kiroku-metrics.md`, IR-11) added
  `kiroku-metrics/src/Kiroku/Metrics/Cors.hs` with `AllowedOrigin`, `allowedOrigin :: Text ->
  Either OriginError AllowedOrigin`, `renderAllowedOrigin`, `CorsPolicy(..)` (`allowedOrigins`,
  `allowCredentials`, `maxAgeSeconds`), `corsDisabled`, `corsAllowOrigins`, `corsEnabled`, and
  `corsMiddleware`; and the field `cors :: !CorsPolicy` on `MetricsServerConfig` in
  `kiroku-metrics/src/Kiroku/Metrics/Config.hs`, defaulting to `corsDisabled`. The composed
  application is wrapped in `corsMiddleware cfg.cors`.
- Plan 87 (`docs/plans/87-serve-durable-subscription-checkpoints-over-http.md`, IR-10) added
  `kiroku-metrics/src/Kiroku/Metrics/Checkpoints.hs` (`CheckpointInventoryProvider`,
  `storeCheckpointInventory`, `checkpointsApp`) and, in
  `kiroku-metrics/src/Kiroku/Metrics/Server.hs`, the providers record and the general starters
  that every later route builds on. It reuses plan 90's errorEnvelope, errorResponse and sanitized storeErrorResponse helpers
  in kiroku-metrics/src/Kiroku/Metrics/JSON.hs.
- Plan 88 (`docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md`,
  IR-8) added `kiroku-metrics/src/Kiroku/Metrics/Browse.hs` (`StoreBrowser(..)` with a
  rank-2 `runStoreRead` field and `limits`, `storeBrowser`, `defaultBrowseLimits`, `browseApp`)
  and the `storeBrowsing` field.
- Plan 89 (`docs/plans/89-expose-a-public-dead-letter-read-api.md`, IR-9) added
  `kiroku-metrics/src/Kiroku/Metrics/DeadLetters.hs` (`DeadLetterProvider`, `storeDeadLetters`,
  `deadLettersApp`) and the `deadLetters` field.

The settled contract in `Kiroku.Metrics.Server` after those four plans, which this plan
restates so it can be checked and must not redesign, is:

```haskell
data ServerProviders = ServerProviders
    { webSocketServer :: !WS.ServerApp
    , subscriptionStatus :: !(Maybe SubscriptionStatusProvider)      -- GET /subscriptions (live, process-local)
    , checkpointInventory :: !(Maybe CheckpointInventoryProvider)    -- GET /subscription-checkpoints
    , storeBrowsing :: !(Maybe StoreBrowser)                               -- /streams, /categories, /events
    , deadLetters :: !(Maybe DeadLetterProvider)                     -- /subscriptions/<name>/dead-letters
    }

defaultServerProviders :: ServerProviders            -- rejecting WebSocket stub, every provider Nothing
storeServerProviders :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> IO ServerProviders
                                                      -- everything a store offers, including the live registry
startMetricsServerWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> IO MetricsServer
withMetricsServerWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> (MetricsServer -> IO a) -> IO a
combinedAppWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> Application
                                                      -- wrapped in corsMiddleware cfg.cors; the value keiro mounts behind a prefix
httpAppWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> Application
                                                      -- the unwrapped router
```

Every legacy starter (`startMetricsServer`, `startMetricsServerWith`, `startMetricsServerWith'`,
`startMetricsServerWithStore`, `withMetricsServer`, `withMetricsServerWithStore`,
`withMetricsServerSubscriptions`) keeps its exact signature as a one-line delegation.
`startMetricsServerWithStore` wires the durable, browse, and dead-letter providers but leaves
`subscriptionStatus` as `Nothing`, so `GET /subscriptions` on that starter still answers the
published `404 {"error":"subscription status not configured"}`. The catch-all answers the frozen
`404 {"error":"Not found"}`. Routes added by the siblings answer errors with the structured
envelope `{"error":{"code":"<snake_case>","message":"<sentence>","details":{...}}}`.

Plan 94 (`docs/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md`,
IR-12) is also a hard dependency: the complete-surface guide and standalone tests must
exercise the implemented four-code protocol, loss notification ordering and bounded name cache.

### The package as it stands

Everything below is under `kiroku-metrics/`. The `common` stanza of `kiroku-metrics.cabal`
enables `DeriveAnyClass`, `DerivingStrategies`, `DuplicateRecordFields`, `LambdaCase`,
`OverloadedRecordDot`, `OverloadedStrings`, and `RecordWildCards`, and builds with
`-Wall -Werror=incomplete-patterns`. The library depends on `aeson`, `async`, `base`,
`bytestring`, `containers`, `hasql`, `hasql-pool`, `http-types`, `kiroku-cli`, `kiroku-store`,
`stm`, `text`, `time`, `uuid`, `vector`, `wai`, `wai-websockets`, `warp`, and `websockets`, plus
`effectful-core` after plan 88. No package in the repository lists a cabal-generated `Paths_`
module yet. `src/Kiroku/Metrics.hs` is the umbrella module that re-exports every submodule with
`module Kiroku.Metrics.X` lines; a new module goes in both its export list and its imports.

`src/Kiroku/Metrics/Config.hs` defines `MetricsServerConfig` with the fields `port`,
`enableJSON`, `enablePrometheus`, `enableWebSocket`, `wsPushIntervalUs`, `wsMaxConnections`,
`wsEventQueueCap`, `readinessMaxLag`, `livenessTimeoutUs`, and (after plan 90) `cors`, and
`defaultConfig` (port 9091, everything enabled, `cors = corsDisabled`). `enableJSON` gates the
`/metrics`, `/metrics/<name>`, and `/health*` routes; `enablePrometheus` gates
`/metrics/prometheus`; `enableWebSocket` gates the `/ws` hint route and is consulted by the
WebSocket app. `startMetricsServerWith'` binds Warp with `Warp.setHost "*"` and, when
`cfg.port == 0`, with `Warp.openFreePort`, reporting the bound port in `MetricsServer.serverPort`.

`src/Kiroku/Metrics/Collector.hs` exports `newKirokuMetricsWith :: STM GlobalPosition -> STM Int
-> IO KirokuMetrics`, `metricsEventHandler`, `metricsObservationHandler`, and `snapshotMetrics`.
The collector must be built before the store opens (its handlers go on `ConnectionSettings`) yet
reads store gauges from the live handle; `example/Main.hs` shows the supported pattern, a
`TVar (Maybe KirokuStore)` filled in once `withStore` yields the store:

```haskell
storeVar <- newTVarIO Nothing
metrics <- newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)
let settings =
        defaultConnectionSettings connStr
            & #eventHandler .~ Just (metricsEventHandler metrics Nothing)
            & #observationHandler .~ Just (metricsObservationHandler metrics Nothing)
withStore settings $ \store -> do
    atomically (writeTVar storeVar (Just store))
    ...

readPosition :: TVar (Maybe KirokuStore) -> STM GlobalPosition
readPosition storeVar =
    readTVar storeVar >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher))

readSubscribers :: TVar (Maybe KirokuStore) -> STM Int
readSubscribers storeVar =
    readTVar storeVar >>= maybe (pure 0) (\s -> IntMap.size <$> readTVar (subscribers s.publisher))
```

`src/Kiroku/Metrics/Health.hs` exports `postgresPing :: KirokuStore -> DependencyCheck`, the
built-in readiness dependency (a `SELECT 1` through the store's pool).

The store side: `kiroku-store/src/Kiroku/Store/Connection.hs` defines
`ConnectionSettings` with the fields `connString :: Text` (a libpq URI or key-value string, passed
verbatim), `poolSize :: Int` (default 10), `schema :: Text` (default `"kiroku"`; authoritative for
both the `search_path` and the `LISTEN <schema>.events` channel, per
[ADR-3](../adr/0003-dedicated-kiroku-schema.md)), `extraSearchPath`, `idleInTransactionTimeout`,
`statementTimeout`, `observationHandler`, `eventHandler`, and `storeSettings`;
`defaultConnectionSettings :: Text -> ConnectionSettings`; and
`withStore :: MonadUnliftIO m => ConnectionSettings -> (KirokuStore -> m a) -> m a`, a bracket
that acquires the pool, starts the notifier's dedicated `LISTEN` connection, starts the event
publisher, and releases all three in reverse order. A store that cannot reach PostgreSQL fails
inside `withStore` with an exception (for example `NotifierStartError`). Fields are read with
`generic-lens` labels (`value ^. #field`) or `OverloadedRecordDot` (`store.pool`).

The CLI pattern to imitate is `kiroku-cli/src/Kiroku/Cli/Standalone.hs`: an options record
parsed by `optparse-applicative`, a pure `resolveStandaloneOptions :: [(String, String)] ->
StandaloneOptions -> Either Text StandaloneRuntime` that applies environment fallbacks and refuses
with guidance, and a thin `kiroku-cli/app/Main.hs` that runs `execParser`, `getEnvironment`,
the resolver, then the runtime under `try`, printing `kiroku: <error>` to stderr and exiting
non-zero on failure. `kiroku-cli` depends on `optparse-applicative >=0.19 && <0.20`.
`kiroku-store-migrations/app/Main.hs` reads `DATABASE_URL` with `lookupEnv`; the Justfile's
`init-schema` recipe exports the same variable.

Tests are Hspec, entered from `test/Main.hs`, which wraps every spec in
`withSharedMigratedPostgres` from `kiroku-test-support` (`Kiroku.Test.Postgres`); a test that
needs a database calls `withMigratedTestDatabase :: (Text -> IO a) -> IO a` for a fresh migrated
database and its connection string. `test/Test/ServerSpec.hs` shows the HTTP pattern (boot,
`port = 0`, `threadDelay`, `http-client` GETs through a helper that never throws on non-2xx);
`test/Test/WebSocketSpec.hs` shows the client pattern (`WS.runClient "127.0.0.1" port
"/ws/events"` under `timeout 15_000_000`, decoding frames with aeson and switching on `type`).
Database-free route tests mount an application with `Network.Wai.Handler.Warp.testWithApplication`.
The self-verifying example is `example/Main.hs` (`cabal run -fexample kiroku-metrics-example`,
behind the manual flag `example` because it depends on `kiroku-test-support`); it prints numbered
steps `[k/N]` and `docs/user/metrics.md` quotes the transcript in "Try it". The siblings each add
a step; this plan appends one more after whatever exists and renumbers.

### Packaging under Nix

`flake.module.nix` builds every package with `callCabal2nix` from a `ghc9124` set extended by
`nix/haskell-overlay.nix`, and exposes `packages.kiroku-metrics`, so `nix build .#kiroku-metrics`
must succeed. `cabal2nix` lists every stanza's dependencies as build inputs whether or not the
stanza is built; that is why the overlay strips `wai-websockets`' example dependencies and why
`kiroku-metrics-example` is flag-gated (its `kiroku-test-support` and `ephemeral-pg` dependencies
are not buildable in the pinned set). The rule for `kiroku-inspect` follows: its `build-depends`
may name only packages already realized by the library closure or published on Hackage and
present in the set (`optparse-applicative` is realized through `kiroku-cli`; `unix` is a GHC boot
library). Never add `kiroku-test-support`, `ephemeral-pg`, or any test-only package to the
executable.

### Documentation and knowledge bundles touched

`docs/user/metrics.md` is the package reference (Contents at the top; sections through
"Subscription status over HTTP", the siblings' sections, then "Try it" and "See Also"; a
deployment call-out near the top states the no-auth posture and asks operators to bind to an
internal interface or put an authenticating proxy in front). `docs/user/operator-cli.md`
describes the `kiroku` binary as a pure remote client with sections "Standalone Usage", "How
Status Is Sourced", and "Embedding In A Host CLI". `docs/user/README.md` indexes the reference
pages with one summary line each. `docs/guides/README.md` indexes the task-oriented guides under
"Available Guides" and defines the guide-versus-reference split.

`docs/capabilities/operational-http-endpoints.md` is `CAP-17` in the profile-governed
`capabilities` bundle (validated by `just capabilities-validate`, which runs `mori validate`, the
profiled `okf validate`, and `okf graph`); updates change `description`, `interface`, `evidence`,
and the body, add a dated `**Update**` entry to `docs/capabilities/log.md`, and never touch
`generated.at`, `since`, or `capabilityId`.

`docs/adr/` is a profile-governed bundle (`docs/adr/profile.dhall`, okf-profiles v0.8.0
`documentation.architectureDecisions`; bundle root `okf_version: "0.2"`). Records are one file at
the root named `NNNN-<slug>.md` with frontmatter `type: Architecture Decision Record`, `title`,
one-sentence `description`, `generated.by` (an OKF actor such as `anthropic/claude-fable-5-1`)
and `generated.at`, `docId: ADR-N`, `status: Accepted`, `date`, `timestamp`, and optionally
`originatingPlan`; the body opens with `# ADR-NNNN: <title>`, a `- **Related:**` list, then
`## Context`, `## Decision`, `## Consequences`, and `## Alternatives Considered`, as
`docs/adr/0010-category-reads-use-a-denormalized-category-index-on-all-rows.md` shows. Handles
are allocated with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` (never by
counting files), `index.md` gains a catalog line, `log.md` gains an entry through
`okf log add`, and `just adr-validate` plus the strict command in Concrete Steps must pass.

### Relevant architecture decisions

Local ADRs read for this plan (the rest were scanned by heading; ADR-2, ADR-4, ADR-5, ADR-7,
ADR-8, and ADR-10 concern consumer groups, checkpoint lifecycle, performance gates, retention,
subscription configuration, and category reads, and do not bear on discovery or hosting):

- [ADR-9, Published HTTP and WebSocket wire shapes are frozen and served only by sister packages](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md):
  a shape becomes a published contract once it ships in a Hackage release and is documented in
  the user guide; published fields are never removed, renamed, or re-typed; additions are new
  optional fields, routes, or frame types; new keys are snake_case; a new surface ships with a
  test pinning its key set; `MetricsServerConfig` fields are PVP-governed Haskell API, not wire
  contract; `kiroku-store` owns no wire format; sister packages wrap supported public APIs only.
  This is why `/capabilities` is a new route with a pinned codec and why `kiroku-inspect` lives
  in the sister package.
- [ADR-1, Resolve stream names via an on-demand lookup API, not a `RecordedEvent` field](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md):
  fan-in reads carry a surrogate `originalStreamId`; the guide must tell UI authors that browse
  items carry a resolved `original_stream_name` (plan 88) while `event` frames on `/ws/events`
  carry only the surrogate unless plan 94 adds the name.
- [ADR-6, Versioned public SQL relations are owner-published and frozen](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md):
  the lineage behind ADR-9's freeze; cited so the guide can point a SQL-native reader at
  `kiroku.subscription_checkpoints_v1` as the database equivalent of the HTTP inventory.
- [ADR-3, Install Kiroku objects in a dedicated `kiroku` schema](../adr/0003-dedicated-kiroku-schema.md):
  `--schema` must set `ConnectionSettings.schema`, which drives both table resolution and the
  notification channel, so a standalone server pointed at a schema-per-tenant database needs
  exactly this one knob.

Cross-repository decisions, cited by the canonical handles the keiro-ui bundle publishes
(`mori path` may lag fresh commits; the canonical URIs are retained regardless):

- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1` (inspection endpoints live in the project
  that owns the concept): store-level screens are Kiroku's to serve, which is why an independent
  Kiroku UI needs nothing from keiro.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3` (push is a hint, poll is truth): the guide's
  live-tail advice.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4` (inspection surfaces live in sister packages
  and export both a convenience runner and the bare WAI application): `kiroku-inspect` is the
  runner for the no-host case, and `combinedAppWithProviders` is the bare application.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-5` (no backend-for-frontend): the UI consumes
  each project's endpoints directly, so discovery must come from this server, not from an
  aggregator.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7` (read-only first): nothing here mutates.
- The shared wire conventions are `mori://shinzui/keiro-ui`,
  `docs/architecture/inspection-api-conventions.md` (artifact-level URI pending): area 1
  (sister packages export a runner and the bare application), area 2 (snake_case new fields),
  area 3 (cursor pagination), area 4 (the structured error envelope), area 7 (CORS posture), and
  area 8 (no authentication; trusted network or authenticating proxy, which the documentation
  restates).
- `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31` (keiro mounts composed runtime
  inspection surfaces behind per-surface prefixes): the reason no response body may carry an
  absolute URL and why the exported application must stay a plain, prefix-agnostic value.

The improvement requests this plan serves indirectly are
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-8` through `IR-12`; none of them asks
for discovery or a standalone server, so this plan changes no request's status and files none.
The MasterPlan records the standalone-UI requirement as the user's own.


## Plan of Work

### Reviewed startup, options, and capability obligations

Plan 87 owns the readiness barrier and server-failure propagation. Its bracket returns only
after listening and keeps unexpected server failure linked to the owning scope, so the
runInspect wait cannot hide a failed Warp worker. Call onListening exactly once after that
barrier, passing both actual port and computed capabilities. A hook failure or shutdown
must release server, collector, store pool and notifier. Test occupied port, early shutdown,
hook exception and unexpected server-worker failure with bounded waits. Test the real
executable's SIGINT and SIGTERM exit 0 and a bind failure exit 1; no success banner on failure.
Use tryPutMVar for signal notifications so a second signal cannot block.

Parse numeric CLI/environment input into Integer, check bounds, then narrow to Int;
do not use `option auto` inferred as Int. Pool size and WebSocket connection limit must be
positive and <= maxBound Int, port 0..65535, schema and explicitly supplied URL nonempty.
An explicit valid flag overrides even a malformed environment value without parsing it.
Use Maybe Bool for credentials and mutually exclusive positive/negative flags so False
can override environment True. Reject malformed booleans. Do not derive an unredacted Show
instance for InspectOptions/InspectRuntime or print a raw caught exception containing the URL.
Catch synchronous runtime failures at the executable boundary without swallowing asynchronous
cancellation; usage errors exit 2. Preserve the API types in Interfaces and Dependencies.

Capabilities are computed once without DB access. Include prometheus among process-local
answers; health reflects this process's connection checks, not another process's workers.
Every advertised true route must be reachable through the same configured app; in particular
enableWebSocket=False must refuse upgrades, not merely report false. Test default providers,
store providers, legacy store starters and a custom declared WebSocket app both enabled
and disabled. Do not infer channels by inspecting the opaque function.

Enable NoFieldSelectors explicitly in the new Capabilities and Standalone modules: their
record labels (for example deadLetters, port and cors) otherwise conflict with selectors
from re-exported existing modules. Record construction and OverloadedRecordDot remain the
supported access syntax. Compile an external consumer importing the entire Kiroku.Metrics umbrella. Use distinct
selector names across re-exported modules (corsIsEnabled and presentWebSocketChannels);
do not rely on qualified local imports to resolve conflicting exports.
No bind/host option is added in this cohort: document the starter's actual bind behavior
and trusted-network posture. CORS is not authentication; use a controlled network/proxy.

### Milestone 0: confirm the dependencies landed

Scope: no edits. Read `kiroku-metrics/src/Kiroku/Metrics/Server.hs` and confirm it exports
`ServerProviders` with exactly the five fields listed in Context and Orientation,
`defaultServerProviders`, `storeServerProviders`, `startMetricsServerWithProviders`,
`withMetricsServerWithProviders`, `combinedAppWithProviders`, and `httpAppWithProviders`; that
`combinedAppWithProviders` wraps the composition in `corsMiddleware cfg.cors`; that the modules
`Kiroku.Metrics.Cors`, `Kiroku.Metrics.Checkpoints`, `Kiroku.Metrics.Browse`, and
`Kiroku.Metrics.DeadLetters` exist and are re-exported by `Kiroku.Metrics`; and that
`Kiroku.Metrics.JSON` exports `errorEnvelope` and `errorResponse` with the `Maybe Value` details
argument. Run:

```bash
grep -n "data ServerProviders" -A 8 kiroku-metrics/src/Kiroku/Metrics/Server.hs
grep -n "corsMiddleware\|httpAppWithProviders\|combinedAppWithProviders" kiroku-metrics/src/Kiroku/Metrics/Server.hs
grep -n "^errorEnvelope\|^errorResponse" kiroku-metrics/src/Kiroku/Metrics/JSON.hs
ls kiroku-metrics/src/Kiroku/Metrics/
cabal build kiroku-metrics && cabal test kiroku-metrics
```

Record the observed field names in Surprises & Discoveries. If any name differs from the
contract, use the name found in the tree and note the difference; if a module or field is missing,
stop and report to the MasterPlan, because the sibling plan has not completed. Also check the
MasterPlan's Exec-Plan Registry rows for plans 87, 88, 89, and 90 read `Complete`.

Acceptance for Milestone 0: the baseline suite passes and Surprises & Discoveries records the
verified contract.

### Milestone 1: the discovery route

Scope: create `kiroku-metrics/src/Kiroku/Metrics/Capabilities.hs`, add the additive
`webSocketChannels` field to `ServerProviders`, mount `GET /capabilities`, and pin its shape with
tests. At the end, every server built from this package answers `/capabilities` truthfully and
every pre-existing test passes unchanged.

First wire the cabal-generated version module. In `kiroku-metrics/kiroku-metrics.cabal`, inside
the `library` stanza, add:

```text
  other-modules:   Paths_kiroku_metrics
  autogen-modules: Paths_kiroku_metrics
```

(Cabal generates `Paths_kiroku_metrics` from the package name with `-` replaced by `_`; it
exports `version :: Data.Version.Version`.) Run `cabal build kiroku-metrics` once to confirm the
module is generated before writing code that imports it.

Write the new module. Its types are deliberately free of `Kiroku.Metrics.Server` so that
`Server` can import it without a cycle; the server computes a small "what is wired" record and
hands it over:

```haskell
{- | The @GET /capabilities@ discovery route.

A browser UI cannot tell from the outside whether a @kiroku-metrics@ server was
started with a store (browse, durable checkpoints, dead letters, the event
tail), with a live subscription registry, with the WebSocket stub, or with
CORS. This route says so, in one JSON object whose keys are the route names the
user guide uses, so a client renders the screens the server can back instead of
probing for @404@s. It is served regardless of the @enable*@ flags it reports.
Every value is relative to this server; nothing is an absolute URL, so the body
is correct when the application is mounted behind a path prefix.
-}
{-# LANGUAGE NoFieldSelectors #-}

module Kiroku.Metrics.Capabilities (
    -- * Declarations the server makes
    WebSocketChannels (..),
    noWebSocketChannels,
    storeWebSocketChannels,
    ProviderPresence (..),

    -- * The response
    RouteAvailability (..),
    Capabilities (..),
    capabilitiesFor,
    kirokuMetricsVersion,
    processLocalRoutes,

    -- * The WAI application
    capabilitiesApp,
    capabilitiesPath,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, encode, object, withObject, (.:), (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (showVersion)
import Network.HTTP.Types (methodGet, status200, status404, status405)
import Network.Wai (Application, pathInfo, requestMethod)

import Kiroku.Metrics.Config (MetricsServerConfig (..))
import Kiroku.Metrics.Cors qualified as Cors
import Kiroku.Metrics.JSON (errorResponse, jsonResponse)
import Paths_kiroku_metrics qualified as Paths

-- | Which WebSocket channels the configured 'WS.ServerApp' actually serves.
-- A 'ServerApp' is opaque, so whoever chooses it declares this.
data WebSocketChannels = WebSocketChannels
    { metricsChannel :: !Bool  -- ^ @/ws/metrics@
    , eventsChannel :: !Bool   -- ^ @/ws/events@
    }
    deriving stock (Eq, Show)

noWebSocketChannels :: WebSocketChannels
noWebSocketChannels = WebSocketChannels False False

storeWebSocketChannels :: WebSocketChannels
storeWebSocketChannels = WebSocketChannels True True

-- | What the server has wired, derived from its providers with 'isJust'.
data ProviderPresence = ProviderPresence
    { hasSubscriptionStatus :: !Bool
    , hasCheckpointInventory :: !Bool
    , hasBrowser :: !Bool
    , hasDeadLetters :: !Bool
    , presentWebSocketChannels :: !WebSocketChannels
    }
    deriving stock (Eq, Show)

data RouteAvailability = RouteAvailability
    { metrics :: !Bool
    , prometheus :: !Bool
    , health :: !Bool
    , subscriptionsLive :: !Bool
    , subscriptionsCheckpoints :: !Bool
    , deadLetters :: !Bool
    , browse :: !Bool
    , websocketMetrics :: !Bool
    , websocketEvents :: !Bool
    }
    deriving stock (Eq, Show)

data Capabilities = Capabilities
    { package :: !Text
    , version :: !Text
    , routes :: !RouteAvailability
    , corsIsEnabled :: !Bool
    , processLocal :: ![Text]
    }
    deriving stock (Eq, Show)

kirokuMetricsVersion :: Text
kirokuMetricsVersion = T.pack (showVersion Paths.version)

-- | Route keys whose answers describe only the answering process.
processLocalRoutes :: [Text]
processLocalRoutes = ["metrics", "prometheus", "health", "subscriptions_live", "websocket_metrics"]

capabilitiesFor :: MetricsServerConfig -> ProviderPresence -> Capabilities
capabilitiesFor cfg presence =
    Capabilities
        { package = "kiroku-metrics"
        , version = kirokuMetricsVersion
        , routes =
            RouteAvailability
                { metrics = cfg.enableJSON
                , prometheus = cfg.enablePrometheus
                , health = cfg.enableJSON
                , subscriptionsLive = presence.hasSubscriptionStatus
                , subscriptionsCheckpoints = presence.hasCheckpointInventory
                , deadLetters = presence.hasDeadLetters
                , browse = presence.hasBrowser
                , websocketMetrics = cfg.enableWebSocket && presence.presentWebSocketChannels.metricsChannel
                , websocketEvents = cfg.enableWebSocket && presence.presentWebSocketChannels.eventsChannel
                }
        , corsIsEnabled = Cors.corsEnabled cfg.cors
        , processLocal = processLocalRoutes
        }
```

Write the `ToJSON` and `FromJSON` instances by hand with exactly these keys: top level
`package`, `version`, `routes`, `cors`, `process_local`; inside `routes` the nine keys
`metrics`, `prometheus`, `health`, `subscriptions_live`, `subscriptions_checkpoints`,
`dead_letters`, `browse`, `websocket_metrics`, `websocket_events`; inside `cors` the key
`enabled`. The `FromJSON` instance exists so tests round-trip and a Haskell client can decode.
The Haskell field is `corsIsEnabled`, not `corsEnabled`: qualifying an import does not
resolve conflicting umbrella-module exports of two distinct selectors/functions. Likewise
ProviderPresence uses `presentWebSocketChannels`, distinct from ServerProviders.webSocketChannels.
The JSON key remains cors.enabled.

The application matches the exact path and refuses other methods:

Define `capabilitiesPath = ["capabilities"]` and
`capabilitiesApp :: Capabilities -> Application`. An unmatched path gives structured
404 not_found. GET returns the encoded capabilities with status200; HEAD returns the same
status and headers with no body. Other methods return structured 405 method_not_allowed and
Allow: GET, HEAD. This behavior must hold in direct WAI tests as well as over Warp.

The body is computed once per server, not per request: `Capabilities` is a pure function of the
configuration and the providers, both fixed at start.

Now edit `kiroku-metrics/src/Kiroku/Metrics/Server.hs`. Import
`Kiroku.Metrics.Capabilities (Capabilities, ProviderPresence (..), WebSocketChannels,
capabilitiesApp, capabilitiesFor, capabilitiesPath, noWebSocketChannels, storeWebSocketChannels)`
and `Data.Maybe (isJust)`. Add the field to the record, after `deadLetters`, with Haddock:

```haskell
    , webSocketChannels :: !WebSocketChannels
    -- ^ Which channels 'webSocketServer' serves, reported by @GET /capabilities@.
    -- 'defaultServerProviders' declares none (the stub rejects every upgrade);
    -- 'storeServerProviders' declares both. A host that supplies its own
    -- 'WS.ServerApp' declares what it serves.
```

Set `webSocketChannels = noWebSocketChannels` in `defaultServerProviders` and
`webSocketChannels = storeWebSocketChannels` in `storeServerProviders`. Find every place a
`ServerProviders` value is built by record update from `defaultServerProviders` (the legacy
delegations) and leave them at the default except `startMetricsServerWithStore`, which installs
the real `websocketApp` and must therefore set `webSocketChannels = storeWebSocketChannels`.
Add a helper and the route arm:

```haskell
providerPresence :: ServerProviders -> ProviderPresence
providerPresence providers =
    ProviderPresence
        { hasSubscriptionStatus = isJust providers.subscriptionStatus
        , hasCheckpointInventory = isJust providers.checkpointInventory
        , hasBrowser = isJust providers.storeBrowsing
        , hasDeadLetters = isJust providers.deadLetters
        , presentWebSocketChannels = providers.webSocketChannels
        }
```

In `httpAppWithProviders`, bind `caps = capabilitiesFor cfg (providerPresence providers)` in a
`where` clause (or a `let` outside the request lambda so it is evaluated once) and add, as the
first arm before any `enable*`-guarded arm:

```haskell
        ["capabilities"] -> capabilitiesApp caps req respond
```

Nothing else in the router changes; the catch-all keeps `{"error":"Not found"}`. Update the
module header comment (the server reports its wiring at `/capabilities`) and the Haddock of
`ServerProviders`. Add `module Kiroku.Metrics.Capabilities` to `kiroku-metrics/src/Kiroku/Metrics.hs`
and `Kiroku.Metrics.Capabilities` to `exposed-modules`. Add to `kiroku-metrics/CHANGELOG.md`
under `## Unreleased`, `### New Features`: the route, the module, `webSocketChannels`, and
`kirokuMetricsVersion`. Because `ServerProviders` gains a field, add a `### Breaking Changes`
bullet regardless of whether local code constructs the record positionally; with the
`defaultServerProviders{...}` idiom the addition is source-compatible for record-update callers,
and the cohort is already a PVP major.

Create `kiroku-metrics/test/Test/CapabilitiesSpec.hs`, register it in `test/Main.hs` and in the
test-suite `other-modules`. Examples under `describe "Kiroku.Metrics.Capabilities"`:

1. Codec pin: build `Capabilities` with every route `True`, `corsIsEnabled = True`, and assert
   `toJSON` equals the literal `object [ "package" .= ("kiroku-metrics" :: Text), "version" .=
   kirokuMetricsVersion, "routes" .= object [ "metrics" .= True, "prometheus" .= True, "health"
   .= True, "subscriptions_live" .= True, "subscriptions_checkpoints" .= True, "dead_letters" .=
   True, "browse" .= True, "websocket_metrics" .= True, "websocket_events" .= True ], "cors" .=
   object ["enabled" .= True], "process_local" .= (["metrics", "health", "subscriptions_live",
   "websocket_metrics"] :: [Text]) ]`, and that `eitherDecode (encode caps) == Right caps`.
   Assert `kirokuMetricsVersion` is non-empty and contains a `.`.
2. Derivation: `capabilitiesFor defaultConfig presenceNone` (all `False`, `noWebSocketChannels`)
   yields `metrics`, `prometheus`, `health` `True` and the other six `False`;
   `capabilitiesFor defaultConfig presenceAll` (all `True`, `storeWebSocketChannels`) yields all
   nine `True`; `capabilitiesFor defaultConfig{enableJSON = False} presenceAll` yields `metrics`
   and `health` `False`; `capabilitiesFor defaultConfig{enableWebSocket = False} presenceAll`
   yields both websocket flags `False`; `capabilitiesFor defaultConfig{cors = corsAllowOrigins
   [o]} presenceNone` yields `corsIsEnabled = True`.
3. Standalone mount: `Warp.testWithApplication (pure (capabilitiesApp caps))`; `GET
   /capabilities` is 200 with the pinned body; `GET /capabilities/x` is 404 with
   `error.code == "not_found"`; `POST /capabilities` is 405 with `method_not_allowed`.
4. Plain server: `startMetricsServer (defaultConfig{port = 0}) m []` (no store); decode
   `/capabilities` into `Capabilities`; assert `subscriptionsLive`, `subscriptionsCheckpoints`,
   `deadLetters`, `browse`, `websocketMetrics`, `websocketEvents` are all `False`, `metrics`
   `True`, `corsIsEnabled` `False`.
5. Store-backed server: inside `withMigratedTestDatabase` and `withStore`, build providers
   with `storeServerProviders` and start `startMetricsServerWithProviders`; assert all nine
   routes `True`. Also `withMetricsServerWithStore`: assert `subscriptionsLive` is `False` and
   the other eight are `True` (this pins the legacy starter's declared channels).
6. `startMetricsServer (defaultConfig{port = 0, enableJSON = False}) m []`: `/capabilities`
   still answers 200 (the route is not gated) and reports `metrics = False`.

Build the `ProviderPresence` values directly in tests 2 and 3; for test 5 the providers come
from the real store. The test needs `warp`, `http-client`, `aeson`, `kiroku-store`,
`kiroku-test-support`, `text`, which the suite already lists.

Acceptance for Milestone 1: `cabal build kiroku-metrics` is warning-free;
`cabal test kiroku-metrics --test-options='--match Capabilities'` reports the examples above
passing; the whole suite passes with no assertion changes in any pre-existing spec.

### Milestone 2: the standalone executable

Scope: create `kiroku-metrics/src/Kiroku/Metrics/Standalone.hs`, the executable stanza and
`kiroku-metrics/app-inspect/Main.hs`, and tests that run the real code path in-process. At the
end, `cabal run kiroku-metrics:exe:kiroku-inspect -- --help` prints usage, a run against a
migrated database serves every store-backed route, and Nix builds the package.

Add `optparse-applicative >=0.19 && <0.20` to the library `build-depends` (the parser lives in
the library so it is testable, as `kiroku-cli` does). Write the module:

```haskell
{- | The @kiroku-inspect@ standalone inspection server.

Opens a 'KirokuStore' from a database URL, wires the metrics collector, and
serves the whole store-backed inspection surface (@/capabilities@, browse,
durable checkpoints, dead letters, the live registry of this process, health,
metrics, and the WebSocket channels) on one port, so a browser UI can be
pointed at an event store with no host program. This process runs no
subscriptions: @GET /subscriptions@ answers an empty list and the per-subscription
metrics are empty, while every route that reads the database is authoritative.
-}
{-# LANGUAGE NoFieldSelectors #-}

module Kiroku.Metrics.Standalone (
    -- * Options
    InspectOptions (..),
    inspectOptionsParser,
    inspectParserInfo,

    -- * Resolution
    InspectRuntime (..),
    resolveInspectOptions,

    -- * Running
    InspectHooks (..),
    runInspect,
    renderStartupBanner,
) where

-- | Parsed command-line options; 'Nothing' means "not given, consult the environment".
-- Do not derive Show: the database URL can contain credentials.
data InspectOptions = InspectOptions
    { databaseUrl :: !(Maybe Text)
    , schema :: !(Maybe Text)
    , poolSize :: !(Maybe Int)
    , port :: !(Maybe Int)
    , corsOrigins :: ![Text]
    , corsAllowCredentials :: !(Maybe Bool)
    , wsMaxConnections :: !(Maybe Int)
    }
    deriving stock (Eq)

-- | Everything 'runInspect' needs, fully resolved and validated.
data InspectRuntime = InspectRuntime
    { databaseUrl :: !Text
    , schema :: !Text
    , poolSize :: !Int
    , port :: !Int
    , cors :: !CorsPolicy
    , wsMaxConnections :: !Int
    }
    deriving stock (Eq)

data InspectHooks = InspectHooks
    { onListening :: !(Int -> Capabilities -> IO ())
    -- ^ Called once with the bound port after the server is up.
    , waitForShutdown :: !(IO ())
    -- ^ Returns when the server should stop; the store and server are then released.
    }
```

Build `inspectOptionsParser :: Parser InspectOptions` from optional text options for
database-url/schema, repeated cors-origin, and bounded numeric readers for pool-size, port
and ws-max-connections. Each reader parses Integer and checks its field's range before
converting to Int. The optional credential choice uses flag' True for
cors-allow-credentials or flag' False for no-cors-allow-credentials; conflicting flags fail.
`inspectParserInfo` includes helper, fullDesc and the standalone/read-only purpose.
There are eight option spellings, including the negative credential flag.

`resolveInspectOptions :: [(String, String)] -> InspectOptions -> Either Text InspectRuntime`
applies, in order: `databaseUrl` from the flag, else `DATABASE_URL`, else
`Left "kiroku-inspect: no database; pass --database-url or set DATABASE_URL (a libpq URI such as postgresql://user@host/db)"`;
`schema` from the flag, else `KIROKU_INSPECT_SCHEMA`, else `"kiroku"`; `poolSize` from the flag,
else `KIROKU_INSPECT_POOL_SIZE` parsed with `Text.Read.readMaybe` (a non-integer or a value below
1 is `Left` naming the variable), else 10; `port` likewise from `KIROKU_INSPECT_PORT`, default
9091, must be in `[0, 65535]`; origins are the flag list if non-empty, else
`KIROKU_INSPECT_CORS_ORIGINS` split on `,` and trimmed, each passed through `allowedOrigin`, any
`Left` becoming `Left` with the offending value and the rendered `OriginError` (so
`--cors-origin '*'` fails with a message that names the wildcard); `corsAllowCredentials` is the explicit optional flag value (including False), else the
environment value parsed strictly as true/false/1/0, else False;
`wsMaxConnections` from the flag, else `KIROKU_INSPECT_WS_MAX_CONNECTIONS`, default 100. The
policy is `corsDisabled` when no origins resolved, else
`(corsAllowOrigins origins){allowCredentials = ...}`. Empty environment values count as unset.

`runInspect :: InspectHooks -> InspectRuntime -> IO ()` is the example's wiring with the
providers from plan 88:

```haskell
runInspect hooks rt = do
    storeVar <- newTVarIO Nothing
    metrics <- newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)
    let settings =
            (defaultConnectionSettings rt.databaseUrl)
                { schema = rt.schema
                , poolSize = rt.poolSize
                , eventHandler = Just (metricsEventHandler metrics Nothing)
                , observationHandler = Just (metricsObservationHandler metrics Nothing)
                }
        cfg = defaultConfig{port = rt.port, cors = rt.cors, wsMaxConnections = rt.wsMaxConnections}
    withStore settings $ \store -> do
        atomically (writeTVar storeVar (Just store))
        providers <- storeServerProviders cfg metrics store
        withMetricsServerWithProviders cfg metrics [postgresPing store] providers $ \server -> do
            hooks.onListening server.serverPort (capabilitiesFor cfg (providerPresence providers))
            hooks.waitForShutdown
```

(`ConnectionSettingsM` has `DuplicateRecordFields`; with `OverloadedRecordDot` and record update
on a value of a known type this compiles; if GHC reports an ambiguous field, use the
`generic-lens` label form `& #schema .~ rt.schema` as `example/Main.hs` does.) `readPosition`
and `readSubscribers` are copied from the example. `renderStartupBanner :: InspectRuntime ->
Int -> Capabilities -> [Text]` produces the three lines shown in Purpose from the runtime, the
bound port, and `capabilitiesFor cfg (providerPresence ...)`; to avoid importing `Server`'s
private helper, compute the `Capabilities` inside `runInspect` from the providers you built (the
`providerPresence` function should be exported from `Server` for this; add it to the export list
in Milestone 1) and pass it to the banner, which `Main` prints from `onListening`. Keep printing
out of the library function itself so the test's hook can capture the port silently.

The executable stanza in `kiroku-metrics.cabal`, after the library and before the example:

```text
executable kiroku-inspect
  import:         common
  main-is:        Main.hs
  hs-source-dirs: app-inspect
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , base                  >=4.18 && <5
    , kiroku-metrics
    , optparse-applicative  >=0.19 && <0.20
    , text                  >=2.0  && <2.2
    , unix                  >=2.8  && <2.9
```

`kiroku-metrics/app-inspect/Main.hs` mirrors `kiroku-cli/app/Main.hs`:

```haskell
module Main (main) where

main :: IO ()
main = do
    opts <- execParser inspectParserInfo
    env <- getEnvironment
    case resolveInspectOptions env opts of
        Left err -> TIO.hPutStrLn stderr err >> exitWith (ExitFailure 2)
        Right rt -> do
            done <- newEmptyMVar
            for_ [sigINT, sigTERM] $ \s -> installHandler s (CatchOnce (void (tryPutMVar done ()))) Nothing
            let hooks = InspectHooks
                    { onListening = \port caps -> mapM_ TIO.putStrLn (renderStartupBanner rt port caps) >> hFlush stdout
                    , waitForShutdown = takeMVar done >> TIO.putStrLn "kiroku-inspect: shutting down"
                    }
            result <- tryJust synchronousException (runInspect hooks rt)
            case result of
                Left (_err :: SomeException) -> TIO.hPutStrLn stderr "kiroku-inspect: startup or server failure (details redacted)" >> exitFailure
                Right () -> pure ()
```

Define synchronousException to return Nothing for SomeAsyncException and Just for other
exceptions; cancellation must propagate. Supply only redacted diagnostics. The hook type is fixed as `Int -> Capabilities -> IO ()`, in the library, executable,
documentation and tests; do not leave `caps` free in the banner closure. Installing a `SIGINT`
handler replaces the RTS default that throws `UserInterrupt`; that is intended, so both signals
take the same clean path. Exit code 2 for a usage or resolution error, 1 for a runtime failure
(unreachable database, bind failure), 0 after a signalled shutdown.

Tests in `kiroku-metrics/test/Test/StandaloneSpec.hs` (register in `test/Main.hs` and
`other-modules`; the suite already depends on `optparse-applicative`? It does not: add
`optparse-applicative >=0.19 && <0.20` to the test-suite `build-depends`). Under
`describe "Kiroku.Metrics.Standalone (options)"`, parse with
`execParserPure defaultPrefs inspectParserInfo args` and `getParseResult`:

1. `["--database-url", "postgresql://x", "--port", "0", "--cors-origin", "http://a", "--cors-origin", "http://b"]`
   parses to the expected record; `[]` parses with every `Maybe` as `Nothing`.
2. Resolution with an empty environment and no URL is `Left` mentioning `--database-url` and
   `DATABASE_URL`; with `[("DATABASE_URL", "postgresql://env")]` it is `Right` with that URL and
   the defaults (`schema = "kiroku"`, `poolSize = 10`, `port = 9091`, `cors = corsDisabled`,
   `wsMaxConnections = 100`); a flag overrides the variable; `KIROKU_INSPECT_PORT=abc` is `Left`
   naming the variable; `--cors-origin '*'` is `Left` mentioning the wildcard;
   `KIROKU_INSPECT_CORS_ORIGINS=https://Ops.example.com/, http://localhost:5173` resolves to two
   normalized origins; `KIROKU_INSPECT_CORS_ALLOW_CREDENTIALS=true` sets `allowCredentials`.

Under `describe "Kiroku.Metrics.Standalone (end to end)"`, one example inside
`withMigratedTestDatabase $ \connStr -> ...`:

3. Resolve `InspectOptions` with `databaseUrl = Just connStr`, `port = Just 0`, and
   `corsOrigins = ["http://localhost:5173"]`; create `portVar <- newEmptyMVar` and
   `done <- newEmptyMVar`; `server <- async (runInspect hooks rt)` with hooks that `putMVar
   portVar` and `takeMVar done`; `port <- timeout 15_000_000 (takeMVar portVar)` must be `Just`.
   Through a second `withStore (defaultConnectionSettings connStr)` handle append three events
   to `orders-1`. Then assert over `http-client`: `/capabilities` decodes with `browse`,
   `subscriptionsCheckpoints`, `deadLetters`, `subscriptionsLive`, `websocketEvents` all `True`
   and `corsIsEnabled` `True`; `/streams` is 200 and its `items` contain `name == "orders-1"`;
   `/subscriptions` is 200 with body `[]`; `/subscription-checkpoints` is 200 with
   `store_position >= 3` and empty `checkpoints`; `/health/ready` is 200; `/metrics` with
   `Origin: http://localhost:5173` carries `access-control-allow-origin` equal to that origin, and
   with `Origin: http://evil.example` carries no `access-control-` header; a `/ws/events` client
   (`WS.runClient "127.0.0.1" port "/ws/events"` under `timeout 15_000_000`) sends
   `{"type":"subscribe_events"}`, waits for `event_stream_started`, then, after the second handle
   appends one more event, receives an `event` frame whose `event.eventType` matches. Finally
   `putMVar done ()` and `wait server` returns within the timeout (proving the shutdown path
   releases everything).

Acceptance for Milestone 2: `cabal build all` is warning-free; `cabal run
kiroku-metrics:exe:kiroku-inspect -- --help` prints the usage with every option above; running
it with no database prints the guidance line and exits 2; `cabal test kiroku-metrics
--test-options='--match Standalone'` passes; `cabal check` reports no error for the new stanza;
`cabal sdist kiroku-metrics` includes `app-inspect/Main.hs`; `nix build .#kiroku-metrics`
succeeds and `result/bin/kiroku-inspect --help` runs.

### Milestone 3: documentation, example, capability record, changelog

Scope: make both audiences able to build against the surface from documentation alone.

Write `docs/guides/building-an-inspection-ui.md` with these sections, in prose, each with the
route names and one short transcript where it helps: an introduction naming the two audiences
(the keiro runtime UI's `@keiro-ui/client-kiroku` package, and an independent Kiroku UI) and
stating that both talk to the same `kiroku-metrics` surface; "Start here: discovery" (`GET
/capabilities`, what each key means, `process_local`, why a client renders from it rather than
probing); "Two ways to run the surface" (embedded in a worker with `storeServerProviders` and
`withMetricsServerWithProviders`, which shows that process's live registry and metrics; or
standalone with `kiroku-inspect`, which runs no subscriptions, with the exact command and banner
from Purpose, and a sentence that keiro applications get the surface mounted behind a prefix by
keiro itself, per `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`); "Screen to
endpoint map": the stream browser (`GET /streams`, `GET /streams/<name>`, `GET
/streams/<name>/events`, `GET /categories`, `GET /categories/<name>/events`, `GET /events`, `GET
/events/<event_id>`, with the note that fan-in items carry `original_stream_name` resolved
server-side per [ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md)
and that per-stream reads report `globalPosition` `0`), the live tail (`/ws/events`,
`subscribe_events` with optional `from_position` and `category`, `event_stream_started`, `event`
frames in global-position order, the overflow `error` frame, and the rule that push is a hint
and the read routes are truth: on overflow or reconnect, re-read from the last seen
`globalPosition` with `GET /events?from=`; cite
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`), the subscriptions dashboard (`GET
/subscription-checkpoints` as the cross-process truth with `store_position`, `GET
/subscriptions` as this process's live annotation, `store_position - checkpoint_position` called
a position distance and never lag, `GET /subscriptions/<name>/dead-letters` with its opaque
`next_cursor` and JSON `reason`), and health and metrics (`/health/live`, `/health/ready`,
`/health`, `/metrics`, `/metrics/prometheus`, `/ws/metrics`, all per process); "Wire rules a
client must honour" (every documented shape is frozen and grows additively; new keys are
snake_case while the event object's camelCase keys are frozen; cursor pagination with exclusive
`from`, `limit`, `items`, `next_cursor` omitted on the last page, cursors echoed and never
computed; the structured error envelope with per-route-family codes listed by name and the
legacy string errors on the original routes; ignore unknown fields, frames, and vocabulary
members; cite ADR-9); "Reaching the server from a browser" (`--cors-origin` and the `cors`
configuration field, the credentials rule, and the reverse-proxy single-origin alternative with
no CORS at all); and "What this surface does not do" (no authentication, TLS, or rate limiting;
trusted network or an authenticating proxy, per the conventions' area 8; read-only; no bind
address option, so use a proxy or firewall to restrict the listener). Link the WebSocket
conformance mapping from plan 94 if `docs/user/metrics.md` has it. Add the guide to
`docs/guides/README.md` under "Available Guides" with a one-paragraph summary.

In `docs/user/metrics.md`: add Contents entries "Discovering the surface" and "Running the
standalone server"; add the two sections after the last endpoint section and before "Try it".
"Discovering the surface" shows the `curl` and the JSON from Purpose captured from a real run,
explains every key, states the derivation rule for the WebSocket flags (declared by the starter;
legacy starters with a caller-supplied app report none), lists `process_local`, and states that
the keys are published once released. "Running the standalone server" shows the command, the
banner, the full option and environment table (flag, variable, default, meaning), the exit codes,
the "runs no subscriptions" explanation with which routes are authoritative, the schema knob
for schema-per-tenant databases, and the missing bind option with the proxy or firewall advice.
In the configuration table add nothing (no new config field). In "Starting the server" add one
sentence pointing at `/capabilities`. Extend the deployment call-out to mention `kiroku-inspect`
listens on every interface.

In `docs/user/operator-cli.md`, after "Standalone Usage", add a short paragraph: the `kiroku`
binary is a remote client that opens no database; `kiroku-inspect` (from `kiroku-metrics`) is
the opposite, a server that opens a database and serves the inspection surface; link the metrics
guide section. In `docs/user/README.md`, extend the `metrics.md` summary line with "a discovery
route and the standalone `kiroku-inspect` server".

Extend `kiroku-metrics/example/Main.hs`: after the last existing HTTP step, GET `/capabilities`,
decode it, check `routes.browse`, `routes.subscriptions_checkpoints`, and
`routes.websocket_events` are `true` and `routes.subscriptions_live` is `false` (the example
uses `withMetricsServerWithStore`), and print `[k/N] GET /capabilities reports browse, checkpoints,
dead letters, and the event tail`. Renumber and mirror the line in "Try it". Run it with
`cabal run -fexample kiroku-metrics-example` (or the `--constraint='kiroku-metrics +example'`
form if cabal rejects the flag; record which worked).

Update CAP-17 (`docs/capabilities/operational-http-endpoints.md`): extend `description` to say
the surface is self-describing at `/capabilities` and self-hosting through `kiroku-inspect`;
add `Kiroku.Metrics.Capabilities` and `Kiroku.Metrics.Standalone` to `interface`; add `evidence`
entries for `kiroku-metrics/test/Test/CapabilitiesSpec.hs` (the discovery body reflects real
wiring) and `kiroku-metrics/test/Test/StandaloneSpec.hs` (a database URL alone serves the whole
store-backed surface); mention the executable in the body and drop or amend the "Limits" bullet
that says only the store-backed starter mounts the real WebSocket if plan 88 already changed it.
Add a dated `**Update**: CAP-17 ...` line to `docs/capabilities/log.md`. Run
`just capabilities-validate`.

Finalize this plan's bullets in the `## Unreleased` section of `kiroku-metrics/CHANGELOG.md`
under `### New Features` (the route, the module, the executable and its options, the
`webSocketChannels` field, `kirokuMetricsVersion`, `optparse-applicative` as a new library
dependency) and `### Other Changes` (the guide). Do not date the section or bump the version.

Acceptance for Milestone 3: `nix fmt` is a no-op; `cabal build all` and `cabal test all` pass;
`just capabilities-validate` passes; the example prints its new step and exits 0; `git diff
--check` is clean; the guide reads end to end without referring to any plan.

### Milestone 4: ADR distillation and close

Scope: record the durable boundaries this plan and its siblings establish, and close the plan.

Allocate the handle and write the record:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
```

Create `docs/adr/00NN-the-inspection-surface-is-composable-self-hosting-and-self-describing.md`
(use the printed number; `ADR-11` was next when this plan was written) with the frontmatter shape
of `docs/adr/0010-category-reads-use-a-denormalized-category-index-on-all-rows.md`
(`type: Architecture Decision Record`, `title`, one-sentence `description`, `generated.by` set to
your model actor string and `generated.at`, `docId: ADR-NN`, `status: Accepted`, `date`,
`timestamp`, `originatingPlan: docs/plans/95-serve-the-kiroku-inspection-surface-standalone-and-make-it-self-describing.md`).
The body: `# ADR-00NN: <title>`; a `- **Related:**` list citing ADR-9, ADR-1, ADR-6, this plan,
the MasterPlan, plans 87 through 90 and 94, IR-8 through IR-12, the keiro-ui handles ADR-1, ADR-3,
ADR-4, ADR-5, ADR-7 (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-N`), keiro IR-31, and the
conventions document (`mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`,
artifact-level URI pending); `## Context` (a library-only surface, four starters, the composed
deployment keiro mounts, and the store-only adopter with no host); `## Decision` in four numbered
parts: the server never holds the `KirokuStore` and every store-backed route enters through a
provider closure on the additive `ServerProviders` record, so a new route is a new field and a
host wires exactly what it wants; `combinedAppWithProviders` is the composable unit, a plain WAI
application with relative paths, wrapped in the host's CORS policy, which keiro mounts behind a
prefix and which must never emit an absolute URL; the surface is self-hosting through
`kiroku-inspect`, an executable in the sister package that depends only on published packages,
opens its own store, runs no subscriptions, and says so; and the surface is self-describing at
`GET /capabilities`, served regardless of the enable flags, with declared WebSocket channels and
a constant `process_local` list, its keys frozen under ADR-9; `## Consequences` (positive: one
wiring path for hosts, a UI that renders from a fact rather than probes, a store-only adopter
gets a UI backend from one binary; negative: an opaque `ServerApp` means channels are declared
not detected, `optparse-applicative` becomes a library dependency, the listener binds every
interface); `## Alternatives Considered` (a standalone server in `kiroku-cli`, rejected for the
dependency cycle; a new package, rejected for release cost; probing the WebSocket app at start,
rejected as fragile; reporting `enableWebSocket` alone, rejected as untrue for stub servers;
adding a `host` field, deferred to the MasterPlan as a shared-record change). Deliberate
exclusions stated in the record: no authentication, TLS, or rate limiting; no mutations; no bind
address option in this cohort.

Then:

```bash
okf log add docs/adr --kind Addition -m "ADR-NN records that store-backed kiroku-metrics routes enter through the additive ServerProviders record, that combinedAppWithProviders is the prefix-mountable unit keiro composes, and that the surface is self-hosting (kiroku-inspect) and self-describing (GET /capabilities)."
just adr-validate
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Add the catalog line to `docs/adr/index.md` in the same form as the existing lines. Then write
Outcomes & Retrospective (what shipped, what a UI author can now do, what the MasterPlan should
carry to plan 96), and record the closing provenance revision with
`bun agents/skills/exec-plan/record-provenance.ts revision --plan docs/plans/95-... --model <your-model-id> --harness claude-code --mode implement --note "..."`
once per session at the first write.

Acceptance for Milestone 4: the strict validation prints `OK: <N+1> concepts` for the bundle,
`just adr-validate` passes, the record is in `index.md` and `log.md`, and every Progress item
above is checked.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` inside the Nix dev
shell (`nix develop`, or the direnv-loaded shell from `.envrc`). There is no `curl` in that
shell; use it from a host shell when reproducing transcripts, or rely on the tests.

Milestone 0:

```bash
git status --short --branch
grep -n "data ServerProviders" -A 8 kiroku-metrics/src/Kiroku/Metrics/Server.hs
grep -n "corsMiddleware\|httpAppWithProviders\|combinedAppWithProviders" kiroku-metrics/src/Kiroku/Metrics/Server.hs
grep -n "^errorEnvelope\|^errorResponse" kiroku-metrics/src/Kiroku/Metrics/JSON.hs
ls kiroku-metrics/src/Kiroku/Metrics/
cabal build kiroku-metrics
cabal test kiroku-metrics
```

Expected: a clean tree on `master`, the five fields, both `...WithProviders` names, both JSON
helpers, the four sibling modules listed, and the suite green.

Milestone 1:

```bash
# edit kiroku-metrics/kiroku-metrics.cabal            (+ Paths_kiroku_metrics other/autogen; + exposed module; + test module)
# write kiroku-metrics/src/Kiroku/Metrics/Capabilities.hs
# edit kiroku-metrics/src/Kiroku/Metrics/Server.hs    (+ webSocketChannels; providerPresence; /capabilities arm; export providerPresence)
# edit kiroku-metrics/src/Kiroku/Metrics.hs           (+ module re-export)
# write kiroku-metrics/test/Test/CapabilitiesSpec.hs
# edit kiroku-metrics/test/Main.hs                    (+ CapabilitiesSpec.spec)
# edit kiroku-metrics/CHANGELOG.md                    (## Unreleased bullets)
nix fmt
cabal build kiroku-metrics
cabal test kiroku-metrics --test-options='--match Capabilities'
cabal test kiroku-metrics
```

Expected tail of the focused run:

```text
Kiroku.Metrics.Capabilities
  encodes the documented snake_case shape and decodes it back [✔]
  derives route availability from the configuration and the wired providers [✔]
  serves the body and structured 404/405 when mounted standalone [✔]
  reports no store-backed routes on a server started without a store [✔]
  reports every route on a store-backed server built with storeServerProviders [✔]
  reports no live registry on withMetricsServerWithStore [✔]
  answers even when the JSON endpoints are disabled [✔]

7 examples, 0 failures
```

Commit:

```text
feat(kiroku-metrics): add GET /capabilities and declared WebSocket channels

MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md
ExecPlan: docs/plans/95-serve-the-kiroku-inspection-surface-standalone-and-make-it-self-describing.md
Intention: intention_01m3t7a7jaeewbf71vqrzk4zd8
```

Milestone 2:

```bash
# edit kiroku-metrics/kiroku-metrics.cabal            (+ optparse-applicative in library and test; + executable kiroku-inspect)
# write kiroku-metrics/src/Kiroku/Metrics/Standalone.hs
# write kiroku-metrics/app-inspect/Main.hs
# edit kiroku-metrics/src/Kiroku/Metrics.hs           (+ module re-export)
# write kiroku-metrics/test/Test/StandaloneSpec.hs
# edit kiroku-metrics/test/Main.hs                    (+ StandaloneSpec.spec)
# edit kiroku-metrics/CHANGELOG.md
nix fmt
cabal build all
cabal run kiroku-metrics:exe:kiroku-inspect -- --help
cabal run kiroku-metrics:exe:kiroku-inspect ; echo "exit=$?"
cabal test kiroku-metrics --test-options='--match Standalone'
(cd kiroku-metrics && cabal check)
cabal sdist kiroku-metrics --list-only | grep app-inspect
nix build .#kiroku-metrics && ./result/bin/kiroku-inspect --help | head -3
```

Expected: the usage text listing `--database-url`, `--schema`, `--pool-size`, `--port`,
`--cors-origin`, `--cors-allow-credentials`, `--ws-max-connections`; the second run prints
`kiroku-inspect: no database; pass --database-url or set DATABASE_URL ...` and `exit=2`; the
focused tests pass; `cabal check` reports no error attributable to the new stanza (pre-existing
warnings may remain); the sdist lists `app-inspect/Main.hs`; the Nix build produces
`result/bin/kiroku-inspect`. A manual run against the dev-shell database (after `just up` and
`just init-schema`):

```bash
DATABASE_URL="$PG_CONNECTION_STRING" cabal run kiroku-metrics:exe:kiroku-inspect -- --port 9091 --cors-origin http://localhost:5173
```

```text
kiroku-inspect: connected to schema "kiroku"; listening on port 9091
kiroku-inspect: routes browse=on subscriptions_checkpoints=on dead_letters=on subscriptions_live=on websocket_events=on cors=on
kiroku-inspect: this process runs no subscriptions; /subscriptions, /metrics, and /health reflect only this process
```

and from a host shell `curl -s http://localhost:9091/capabilities | jq .routes.browse` prints
`true`; `Ctrl-C` prints `kiroku-inspect: shutting down` and exits 0. Commit as
`feat(kiroku-metrics): add the kiroku-inspect standalone inspection server` with the three
trailers.

Milestone 3:

```bash
# write docs/guides/building-an-inspection-ui.md
# edit docs/guides/README.md, docs/user/metrics.md, docs/user/operator-cli.md, docs/user/README.md
# edit kiroku-metrics/example/Main.hs
# edit docs/capabilities/operational-http-endpoints.md, docs/capabilities/log.md
# edit kiroku-metrics/CHANGELOG.md
cabal run -fexample kiroku-metrics-example
just capabilities-validate
nix fmt
cabal build all
cabal test all
git diff --check
```

Expected: the example transcript ends with its `all checks passed` line and includes the
`/capabilities` step; the validators pass. Commit as
`docs(kiroku-metrics): document discovery, the standalone server, and building a UI` with the
three trailers.

Milestone 4:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
# write docs/adr/00NN-the-inspection-surface-is-composable-self-hosting-and-self-describing.md
# edit docs/adr/index.md
okf log add docs/adr --kind Addition -m "ADR-NN records ..."
just adr-validate
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Expected last line of the strict run: `OK: <actual count> concepts (okf_version 0.2)`.
Do not assume a handle or count: ADR-15 already records the reviewed inspection constraints;
amend it if it covers the durable outcome instead of creating a duplicate. Commit as `docs(adr): record the composable,
self-hosting, self-describing inspection surface` with the three trailers, then update this
plan's living sections and record the provenance revision.


## Validation and Acceptance

The reviewed API, lifecycle and performance obligations in Context and Plan of Work are
mandatory in addition to the route-specific cases below. Historical transcripts are examples,
not evidence that the new tests have run; update counts from actual output at implementation.

The plan is complete when every item below is observable:

1. `GET /capabilities` on a server started with `withMetricsServerWithStore` returns HTTP 200
   and a body with exactly the keys `package`, `version`, `routes` (nine boolean keys), `cors`
   (`enabled`), and `process_local`; `routes.browse`, `routes.subscriptions_checkpoints`,
   `routes.dead_letters`, `routes.websocket_events` are `true` and `routes.subscriptions_live`
   is `false`; on `startMetricsServer` every store-backed flag is `false`; on
   `storeServerProviders` every flag is `true`; the route answers even with `enableJSON = False`
   (`CapabilitiesSpec`).
2. `kiroku-inspect --help` lists the eight options; a run without a database exits 2 with the
   guidance line; `--cors-origin '*'` exits 2 naming the wildcard; a run against a migrated
   database prints the three-line banner and serves `/capabilities`, `/streams`,
   `/subscriptions` (`[]`), `/subscription-checkpoints`, `/subscriptions/<name>/dead-letters`,
   `/health/ready`, and `/ws/events`, decorating responses for a configured origin
   (`StandaloneSpec`).
3. `SIGINT` or `SIGTERM` ends the process with exit 0 after `kiroku-inspect: shutting down`, and
   the in-process test's `wait` returns after the shutdown hook fires.
4. `nix build .#kiroku-metrics` succeeds and installs `bin/kiroku-inspect`; `cabal sdist`
   contains `app-inspect/Main.hs`.
5. `docs/guides/building-an-inspection-ui.md` exists, is indexed, and names every route a UI
   screen needs by path; `docs/user/metrics.md` documents the discovery route and the standalone
   server with the option table; CAP-17 lists the two modules and two spec files; the example
   prints its `/capabilities` step.
6. The new ADR validates strictly, is indexed and logged, and cites the handles listed in
   Milestone 4.
7. Every pre-existing `kiroku-metrics` spec passes without assertion changes, and `git diff`
   shows no change to any published body, frame, or status code.


## Idempotence and Recovery

All source, test, and documentation edits are additive and can be re-applied; `nix fmt`,
`cabal build`, `cabal test`, `okf validate`, and the example are safe to rerun. The new route is
read-only and the executable only reads; repeating a request, a test, or a run cannot change
store state. Tests use a fresh migrated database per example and OS-assigned ports.

If `cabal build` fails because `Paths_kiroku_metrics` is not found, the `autogen-modules` line
is missing or the package was not reconfigured; run `cabal build kiroku-metrics` again after the
cabal edit. If `nix build .#kiroku-metrics` fails resolving a dependency of the executable, a
non-published package crept into its `build-depends`; remove it (the executable needs only
`base`, `kiroku-metrics`, `optparse-applicative`, `text`, `unix`). If the end-to-end test hangs
at `takeMVar portVar`, `runInspect` threw before calling `onListening` (typically an unreachable
database); the `async` holds the exception, so wrap the wait in `timeout` and `waitCatch` the
server thread to surface it.

The ADR handle allocation is idempotent until the file exists; never fill a gap or reuse a
handle. If validation fails, fix the frontmatter it names and re-run. To roll back, revert the
milestone commits in reverse order; nothing outside the repository observes the change until
plan 96 releases the cohort.


## Interfaces and Dependencies

At the end of Milestone 1, `kiroku-metrics` exposes:

```haskell
-- Kiroku.Metrics.Capabilities (new module)
data WebSocketChannels = WebSocketChannels { metricsChannel :: !Bool, eventsChannel :: !Bool }
noWebSocketChannels, storeWebSocketChannels :: WebSocketChannels
data ProviderPresence = ProviderPresence
    { hasSubscriptionStatus, hasCheckpointInventory, hasBrowser, hasDeadLetters :: !Bool
    , presentWebSocketChannels :: !WebSocketChannels }
data RouteAvailability = RouteAvailability
    { metrics, prometheus, health, subscriptionsLive, subscriptionsCheckpoints
    , deadLetters, browse, websocketMetrics, websocketEvents :: !Bool }
data Capabilities = Capabilities
    { package :: !Text, version :: !Text, routes :: !RouteAvailability
    , corsIsEnabled :: !Bool, processLocal :: ![Text] }
-- ToJSON/FromJSON: package, version, routes{metrics, prometheus, health, subscriptions_live,
-- subscriptions_checkpoints, dead_letters, browse, websocket_metrics, websocket_events},
-- cors{enabled}, process_local
capabilitiesFor :: MetricsServerConfig -> ProviderPresence -> Capabilities
kirokuMetricsVersion :: Text
processLocalRoutes :: [Text]
capabilitiesPath :: [Text]                       -- ["capabilities"]
capabilitiesApp :: Capabilities -> Network.Wai.Application

-- Kiroku.Metrics.Server (additions)
data ServerProviders = ServerProviders { ..., webSocketChannels :: !WebSocketChannels }
providerPresence :: ServerProviders -> ProviderPresence
-- httpAppWithProviders serves ["capabilities"] before every other arm
```

At the end of Milestone 2:

```haskell
-- Kiroku.Metrics.Standalone (new module)
-- Do not derive Show: the database URL can contain credentials.
data InspectOptions = InspectOptions
    { databaseUrl :: !(Maybe Text), schema :: !(Maybe Text), poolSize :: !(Maybe Int)
    , port :: !(Maybe Int), corsOrigins :: ![Text], corsAllowCredentials :: !(Maybe Bool)
    , wsMaxConnections :: !(Maybe Int) }
inspectOptionsParser :: Options.Applicative.Parser InspectOptions
inspectParserInfo :: Options.Applicative.ParserInfo InspectOptions
data InspectRuntime = InspectRuntime
    { databaseUrl :: !Text, schema :: !Text, poolSize :: !Int, port :: !Int
    , cors :: !CorsPolicy, wsMaxConnections :: !Int }
resolveInspectOptions :: [(String, String)] -> InspectOptions -> Either Text InspectRuntime
data InspectHooks = InspectHooks
    { onListening :: !(Int -> Capabilities -> IO ()), waitForShutdown :: !(IO ()) }
runInspect :: InspectHooks -> InspectRuntime -> IO ()
renderStartupBanner :: InspectRuntime -> Int -> Capabilities -> [Text]
```

Command line and environment (flag wins):

```text
--database-url URL          DATABASE_URL                            required
--schema NAME               KIROKU_INSPECT_SCHEMA                   kiroku
--pool-size N               KIROKU_INSPECT_POOL_SIZE                10
--port N                    KIROKU_INSPECT_PORT                     9091 (0 = OS-assigned, printed)
--cors-origin ORIGIN ...    KIROKU_INSPECT_CORS_ORIGINS (comma)     none (CORS disabled)
--cors-allow-credentials / --no-cors-allow-credentials
                           KIROKU_INSPECT_CORS_ALLOW_CREDENTIALS   false
--ws-max-connections N      KIROKU_INSPECT_WS_MAX_CONNECTIONS       100
```

Exit codes: 0 after a signalled shutdown; 2 for a usage or resolution error; 1 for a runtime
failure.

Wire contract owned by this plan (frozen once released, per ADR-9): the `/capabilities` body
shown in Purpose, plus `404 {"error":{"code":"not_found","message":"Not found"}}` and
`405 {"error":{"code":"method_not_allowed","message":"..."}}` on that path.

Dependencies: the library gains `optparse-applicative >=0.19 && <0.20` and the generated
`Paths_kiroku_metrics` module; the executable depends on `base`, `kiroku-metrics`,
`optparse-applicative`, `text`, and `unix >=2.8 && <2.9`; the test suite gains
`optparse-applicative`. No change to `kiroku-store` or `kiroku-cli`. The only runtime service is
PostgreSQL with the existing Kiroku migrations. Locate dependency sources through
`mori registry show <project> --full` (for example `pcapriotti/optparse-applicative`,
`yesodweb/wai`, `haskell/aeson`) when behaviour is uncertain; do not inspect `/nix/store`.

Dependency direction is unchanged: `kiroku-metrics` depends on `kiroku-cli` and `kiroku-store`;
nothing depends on `kiroku-metrics`. Plan 96 releases the result as part of the cohort.


## API and performance review revision (2026-10-10)

Reviewed against repository HEAD `f1a0209` and the released typed-decoding implementation. Corrected integration contracts and made focused performance evidence a completion gate. Existing authorship history is preserved; this revision records no implemented milestone or accepted performance result. The active requirements above supersede incompatible September design decisions, not published wire contracts.


Revision (2026-10-11 implementation): EP-6 completes locally with pure discovery, the standalone executable, a complete UI guide, ADR-18 and retained correctness/packaging evidence. The release performance gate remains open; no version or publication change is made.
