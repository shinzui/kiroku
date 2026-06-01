---
id: 52
slug: remote-subscription-status-http-endpoint-and-kiroku-cli-remote-client
title: "Remote Subscription-Status HTTP Endpoint And Kiroku-CLI Remote Client"
kind: exec-plan
created_at: 2026-06-01T15:24:09Z
intention: "intention_01ks1saptfe6j8e98dvce7mvgf"
master_plan: "docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md"
---

# Remote Subscription-Status HTTP Endpoint And Kiroku-CLI Remote Client

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is the fifth child plan under the MasterPlan
`docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md`. It
**hard-depends on EP-2**
(`docs/plans/33-http-json-prometheus-and-health-endpoints-for-kiroku-metrics.md`),
which must be Complete first: this plan mounts a new HTTP route on the Warp
server and router (`Kiroku.Metrics.Server`) that EP-2 builds, and reuses EP-2's
`MetricsServerConfig`. It has no dependency on EP-3 (WebSocket) or EP-4 (docs).
EP-4 soft-depends on this plan: EP-4's user guide should document the
`/subscriptions` endpoint and the CLI remote command once they exist. This plan
owns the MasterPlan Integration Point IP-5 (the subscription-status wire JSON
contract).


## Purpose / Big Picture

Kiroku ships an embeddable operator CLI, the `kiroku-cli` package (library
modules under `Kiroku.Cli.*`, plus a `kiroku` executable). Its one command today,
`kiroku subscriptions status`, lists the live subscriptions running inside a
`KirokuStore` by reading the store's in-memory subscription registry through
`Kiroku.Store.Subscription.subscriptionStates`. The hard limitation, stated
verbatim in the CLI's own help text and output
(`kiroku-cli/src/Kiroku/Cli/Standalone.hs:58` and `:119`), is that this registry
is **process-local**: the standalone `kiroku` binary opens its *own* `KirokuStore`
against the database, so it sees only the subscriptions running *in that CLI
process* — which is none, because the CLI does not start subscriptions. It
**cannot inspect subscriptions running inside a separate, long-lived worker
service process**. An operator who wants to know "what is my running worker
actually doing right now — which subscriptions are live, catching up, paused,
reconnecting, and at what global position?" has no way to ask.

After this plan, an operator can ask exactly that, over the network:

- A worker process that already runs a `kiroku-metrics` HTTP server (from EP-2)
  exposes a new endpoint, `GET /subscriptions`, returning the worker's **live
  subscription registry** as JSON — each subscription's name, consumer-group
  member index, current FSM phase (`catching_up`, `live`, `paused`,
  `reconnecting`, `retrying`), and current global cursor position.
  `GET /subscriptions/<name>` returns just the rows for one subscription name
  (one row per consumer-group member).
- The standalone `kiroku` binary becomes a **pure remote client**:
  `kiroku subscriptions status --remote-url http://worker-host:9091` (or with
  `KIROKU_REMOTE_URL` set) issues the `GET /subscriptions` request to that running
  worker and renders the result with the *same* table/JSON renderer the in-process
  command already uses. No `KirokuStore` is ever opened by the standalone binary.

The standalone binary's previous **local mode is removed**, not merely augmented.
That mode opened the binary's *own* `KirokuStore` against the database and read
*that* store's registry — but the `kiroku` process runs no subscriptions, so the
registry was always empty and the command was useless (its own help text in
`kiroku-cli/src/Kiroku/Cli/Standalone.hs` said as much). This plan rips out the
store-opening path from the standalone binary entirely, including the
`--database-url`/`--schema`/`--pool-size` options, so the binary is unambiguously a
remote operator client.

The **embeddable library** in-process path is the opposite case and stays
untouched: `Kiroku.Cli.Run.renderKirokuCommandWithStore` is handed the *host
worker's own* `KirokuStore`, so reading that worker's live registry in-process is
correct and is the entire point of the embeddable design. (It also gains the
optional `--remote-url` override for hosts that prefer to query a sibling worker
over HTTP.)

You can *see it working* by starting a worker (a `KirokuStore` with one or more
subscriptions plus a `kiroku-metrics` server) in one terminal, then running
`kiroku subscriptions status --remote-url http://localhost:9091` in another and
watching it print the worker's live subscriptions — phases and positions that
change as events flow. Transcripts are in Validation and Acceptance.

The data source is the **live registry**, not the EP-1 callback-collector
snapshot. The registry (`subscriptionStates`) reads each worker's live
`TVar SubscriptionState` cell, which the worker writes on *every* FSM transition,
so it reports the *current* phase and cursor of every running subscription. This
is richer and more current than the EP-1 `MetricsSnapshot.subscriptions` map
(which observes positions only at lifecycle callback points and is shaped for
lag/health metrics). The two are complementary: `/metrics` answers "how is the
store performing and is it healthy?"; `/subscriptions` answers "what is running
right now and in what state?". See the Decision Log.


## Progress

- [ ] M1: `GET /subscriptions` and `GET /subscriptions/<name>` served by the
      `kiroku-metrics` Warp server, reading the live registry through an optional
      provider closure; verified with `curl` against a running worker.
- [ ] M2: `kiroku subscriptions status --remote-url URL` (or `KIROKU_REMOTE_URL`)
      fetches and renders the endpoint over HTTP, reusing the existing table/JSON
      renderer; verified end to end against a running worker. The standalone binary
      is converted to a pure remote client (store-opening path and
      `--database-url`/`--schema`/`--pool-size` options removed); the embeddable
      in-process API keeps reading the host store and gains an optional
      `--remote-url` override.
- [ ] M3: Round-trip + end-to-end tests — server encode ⇄ CLI decode of the wire
      shape, and an integration test that boots a store with a subscription,
      starts the server, and asserts the CLI remote command reports the live
      subscription.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Serve subscription status from the **live registry**
  (`Kiroku.Store.Subscription.subscriptionStates`), not from the EP-1
  `MetricsSnapshot.subscriptions` map.
  Rationale: The registry reads each worker's live `TVar SubscriptionState` cell,
  written on every FSM transition, so it reports the *current* phase
  (`catching_up`/`live`/`paused`/`reconnecting`/`retrying`) and current cursor of
  every running subscription, keyed by `(SubscriptionName, member)`. The
  collector snapshot observes positions only at lifecycle callback points and is
  shaped for lag/health, not for "what is running right now". The operator
  question this plan answers is the latter.
  Date: 2026-06-01

- Decision: Keep the wire shape identical to the CLI's existing local-status JSON
  (`{subscription, member, phase, global_position}`), make `SubscriptionStatusRow`
  the single source of truth for it (it already lives in
  `Kiroku.Cli.Subscription.Status`), and have `kiroku-metrics` **depend on
  `kiroku-cli`** to reuse the row type and its encoder for the endpoint.
  Rationale: One JSON contract, one encoder, no drift; the local and remote CLI
  commands render through the exact same `renderSubscriptionStatusRows`. The
  dependency direction `kiroku-metrics → kiroku-cli → kiroku-store` has no cycle
  (`kiroku-cli` does not depend on `kiroku-metrics`). `kiroku-cli` stays web-free:
  its remote client adds only a light `http-client` dependency and a `FromJSON`
  instance, not a web server. See IP-5 in the MasterPlan.
  Date: 2026-06-01

- Decision: The metrics server stays store-agnostic; the subscription-status data
  is supplied as an **optional provider closure** (`IO [SubscriptionStatusRow]`),
  not by passing the `KirokuStore` into the server.
  Rationale: EP-2 deliberately keeps `KirokuStore` out of the server signature
  (plan 33 Decision Log) — store-specific behavior is captured in closures the
  caller builds (as `postgresPing` does). The provider is
  `subscriptionStatusRows <$> subscriptionStates store`, wired by the caller who
  owns the store. When no provider is wired, `/subscriptions` returns 404 with a
  clear "subscription status not configured" body, so EP-2's existing
  `startMetricsServer` call sites keep compiling unchanged.
  Date: 2026-06-01


- Decision: Convert the standalone `kiroku` binary to a **pure remote client** and
  **remove** its local store-opening mode (and the
  `--database-url`/`--schema`/`--pool-size` options), rather than keeping local
  mode alongside `--remote-url`.
  Rationale: The standalone binary runs no subscriptions, so opening its own store
  and reading the registry always returned an empty result — the mode was useless
  (its own help text admitted it). Making the binary remote-only removes a
  confusing dead path and a foot-gun. The legitimate in-process case lives in the
  **embeddable library** (`renderKirokuCommandWithStore`), which is handed the host
  worker's own store; that path is unchanged. `app/Main.hs` is untouched because
  `resolveStandaloneOptions`/`runStandaloneCommand`/`standaloneParserInfo` keep
  their signatures. The endpoint resolves from `--remote-url` or the new
  `KIROKU_REMOTE_URL` env var (mirroring the removed `KIROKU_DATABASE_URL`).
  Date: 2026-06-01


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan touches two packages: `kiroku-metrics` (the server side; created by EP-1
and extended by EP-2) and `kiroku-cli` (the client side; already in the repo). It
reads one public function from `kiroku-store`. Nothing in `kiroku-store` changes.

### The live subscription registry in `kiroku-store` (the data source)

The store holds every running subscription in an in-memory `TVar`, exposed
through one public function. Full paths under
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src`:

- `Kiroku/Store/Connection.hs` — the `KirokuStore` record carries
  `subscriptionRegistry :: !(TVar (Map (SubscriptionName, Int32) (Unique, TVar SubscriptionState)))`.
  The key is `(subscription name, consumer-group member)` (member is `0` for a
  non-group subscription). The value pairs a `Unique` token (so a stale worker's
  cleanup cannot evict a newer worker's entry) with the worker's live state cell.
  Created empty in `withStore`. Process-local; never persisted.

- `Kiroku/Store/Subscription.hs` — exports the reader and its view type:

  ```haskell
  data SubscriptionStateView = SubscriptionStateView
    { subscriptionName :: !SubscriptionName
    , member           :: !Int32
    , state            :: !SubscriptionState   -- the live FSM value
    , statePhase       :: !Text                -- low-cardinality label from stateName
    , cursor           :: !GlobalPosition      -- current position from the state cell
    }
    deriving stock (Show, Generic)

  subscriptionStates
    :: KirokuStore -> IO (Map (SubscriptionName, Int32) SubscriptionStateView)
  ```

  `subscriptionStates` snapshots the registry by reading each entry's state cell
  outside a single STM transaction (so a busy worker writing its cell does not
  stall the reader). A *stopped* subscription is **absent** from the map (the
  worker's `finally` cleanup removes its entry); there is no `"stopped"` row.

- `Kiroku/Store/Subscription/Fsm.hs` — `SubscriptionState` and `stateName`:

  ```haskell
  stateName :: SubscriptionState -> Text
  stateName = \case
    CatchingUp{}   -> "catching_up"
    Live{}         -> "live"
    Paused{}       -> "paused"
    Reconnecting{} -> "reconnecting"
    Retrying{}     -> "retrying"
    Stopped{}      -> "stopped"   -- never observed via the registry (absent instead)
  ```

- `Kiroku/Store/Subscription/Types.hs` —
  `newtype SubscriptionName = SubscriptionName Text` (`Eq, Ord, Show`).
- `Kiroku/Store/Types.hs` — `newtype GlobalPosition = GlobalPosition Int64`
  (unwrapped to `Int64` for the wire).

### The CLI today (the client side, already present)

Full paths under
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-cli`:

- `kiroku-cli.cabal` — `library` exposes `Kiroku.Cli`, `Kiroku.Cli.Command`,
  `Kiroku.Cli.Parser`, `Kiroku.Cli.Run`, `Kiroku.Cli.Standalone`,
  `Kiroku.Cli.Subscription.Status`. Library deps: `aeson`, `base`, `bytestring`,
  `containers`, `generic-lens`, `kiroku-store ^>=0.2`, `lens`,
  `optparse-applicative`, `text`. The `kiroku` executable depends on
  `kiroku-cli`.

- `src/Kiroku/Cli/Command.hs` — the command algebra:

  ```haskell
  data KirokuCommand = KirokuNoCommand | KirokuSubscriptions SubscriptionCommand
  data SubscriptionCommand = SubscriptionStatus StatusOptions
  newtype StatusOptions = StatusOptions { outputFormat :: OutputFormat }
  data OutputFormat = OutputTable | OutputJson
  ```

- `src/Kiroku/Cli/Parser.hs` — `statusOptionsParser` builds `StatusOptions` from a
  `--format table|json` option (default `table`). `subscriptionCommandParser`
  wires the `status` subcommand under `subscriptions`.

- `src/Kiroku/Cli/Subscription/Status.hs` — the shared status row and renderer:

  ```haskell
  data SubscriptionStatusRow = SubscriptionStatusRow
    { subscription   :: !Text
    , member         :: !Int32
    , phase          :: !Text
    , globalPosition :: !Int64
    }
    deriving stock (Generic, Eq, Show)

  subscriptionStatusRows
    :: Map (SubscriptionName, Int32) SubscriptionStateView -> [SubscriptionStatusRow]
  renderSubscriptionStatusRows :: OutputFormat -> [SubscriptionStatusRow] -> Text
  ```

  `renderJson` (the `OutputJson` branch) already emits a JSON **array** of objects
  with keys `subscription`, `member`, `phase`, `global_position`. This exact shape
  is the wire contract (IP-5). The module has no `ToJSON`/`FromJSON` instance for
  the row yet — it hand-builds the array in `renderJson`. This plan introduces the
  instances so server and client share one codec.

- `src/Kiroku/Cli/Run.hs` — `renderKirokuCommandWithStore :: KirokuStore ->
  KirokuCommand -> IO Text` runs the command against a supplied store
  (`subscriptionStates store` → rows → render).

- `src/Kiroku/Cli/Standalone.hs` — `StandaloneOptions`/`StandaloneRuntime`, the
  standalone parser, `resolveStandaloneOptions`, and `runStandaloneCommand`, which
  opens a store with `withStore` and renders. Lines 58 and 119 carry the
  process-local caveat this plan removes for the remote case.

### The metrics server from EP-2 (where the endpoint mounts)

EP-2 (`docs/plans/33-...`) builds, in `kiroku-metrics`:

- `Kiroku.Metrics.Config` — `MetricsServerConfig` (fields incl. `port`,
  `enableJSON`, `enablePrometheus`, `enableWebSocket`, `ws*`, lag/liveness
  thresholds) and `defaultConfig` (`port = 9091`).
- `Kiroku.Metrics.Server` — the combined WAI app
  `combinedApp :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> WS.ServerApp -> Application`
  built with `Network.Wai.Handler.WebSockets.websocketsOr`, the HTTP router
  `httpApp` (matching on `Network.Wai.pathInfo`), the `MetricsServer` handle, and
  the lifecycle functions `startMetricsServer`, `startMetricsServerWith`,
  `stopMetricsServer`, `withMetricsServer`. The router already returns a JSON
  `{"error":"Not found"}` 404 for unmatched paths and uses a `jsonResponse ::
  Status -> LBS.ByteString -> Response` helper (in `Kiroku.Metrics.JSON`).

EP-2 keeps `KirokuStore` out of the server signature on purpose (plan 33 Decision
Log); store-specific behavior is supplied as closures. This plan follows that rule
exactly: the subscription-status data arrives as a closure, not a store.

### The model to copy: `message-db-hs` and `shibuya-metrics`

Two sister projects expose "what's running" the same way; read them before coding.

- `message-db-hs` (on disk at
  `/Users/shinzui/Keikaku/work/libraries/haskell/message-db-hs-master`) holds
  running subscriptions in `Map Text (TVar SubscriptionContext)` and serves them
  with `jsonMetricsApp` (`GET /metrics`, all subscriptions) and
  `jsonSubscriptionApp` (`GET /metrics/<name>`, one) in
  `message-db-metrics/src/MessageDb/Metrics/Server.hs`. The handlers just
  `traverse readTVarIO` the registry into immutable snapshots and `encode` them.
  Its `SubscriptionJSON` (name, status, positions, lag) is the precedent for a
  flat per-subscription JSON row. This plan mirrors that handler shape with our
  `/subscriptions` path and our `SubscriptionStatusRow`.

- `shibuya-metrics` (on disk at
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-metrics`) keeps a
  registry of running processors and serves `GET /metrics` / `GET /metrics/:id`
  from it (`src/Shibuya/Metrics/JSON.hs`), reading the live state on demand. Same
  registry → snapshot → HTTP-handler flow.

The only structural difference here: our registry reader is a single public
function (`subscriptionStates store`), and our per-row key is
`(SubscriptionName, member)`.

### Web/HTTP libraries

- Server (already in `kiroku-metrics` via EP-2): `wai` (`Application`,
  `pathInfo`), `http-types` (`status200`, `status404`). No new server library is
  needed; the new route is added to the existing `httpApp`.
- Client (new in `kiroku-cli`): `http-client` (the request/response/manager API:
  `Network.HTTP.Client`) and `http-client-tls`
  (`Network.HTTP.Client.TLS.tlsManagerSettings`) so an `https://` endpoint works.
  Both are common packages in the GHC 9.12 set used elsewhere in the tree. If
  either is missing from the Nix package set on `nix build`, add a
  `callHackageDirect`/`doJailbreak` entry in `nix/haskell-overlay.nix` mirroring
  the existing entries, and note it in Surprises & Discoveries.


## Plan of Work

Three milestones: the server endpoint (M1), the CLI remote client (M2), the tests
(M3). M1 and M2 are independently verifiable with `curl` and the CLI; M3 locks the
shared wire contract.

### Milestone M1 — `GET /subscriptions` on the metrics server

Scope: make `SubscriptionStatusRow` round-trippable JSON, add a
`Kiroku.Metrics.Subscriptions` module serving `/subscriptions` and
`/subscriptions/<name>` from an optional provider closure, and wire it into
EP-2's router and lifecycle. At the end, a worker that wires the provider answers
both routes over HTTP.

1. **Wire codec (in `kiroku-cli`).** In
   `kiroku-cli/src/Kiroku/Cli/Subscription/Status.hs`, give `SubscriptionStatusRow`
   `ToJSON`/`FromJSON` instances that match the existing `renderJson` shape exactly
   — keys `subscription`, `member`, `phase`, `global_position`. Then refactor
   `renderJson` to encode `[SubscriptionStatusRow]` via the new `ToJSON` (so there
   is one encoder). Export the instances (they come with the already-exported
   type). Add `aeson` is already a dep; no cabal change here.

   ```haskell
   instance Aeson.ToJSON SubscriptionStatusRow where
     toJSON row =
       Aeson.object
         [ "subscription"    Aeson..= subscription row
         , "member"          Aeson..= member row
         , "phase"           Aeson..= phase row
         , "global_position" Aeson..= globalPosition row
         ]

   instance Aeson.FromJSON SubscriptionStatusRow where
     parseJSON = Aeson.withObject "SubscriptionStatusRow" $ \o ->
       SubscriptionStatusRow
         <$> o Aeson..: "subscription"
         <*> o Aeson..: "member"
         <*> o Aeson..: "phase"
         <*> o Aeson..: "global_position"
   ```

2. **Server depends on the CLI library.** In
   `kiroku-metrics/kiroku-metrics.cabal`, add `kiroku-cli ^>=0.1` to the `library`
   `build-depends`, and add `Kiroku.Metrics.Subscriptions` to `exposed-modules`.
   (This is the only new inter-package dependency; it is acyclic — `kiroku-cli`
   does not depend on `kiroku-metrics`.)

3. **New module `Kiroku.Metrics.Subscriptions`.** A provider type and two
   handlers, mirroring `message-db-hs`'s `jsonMetricsApp`/`jsonSubscriptionApp`:

   ```haskell
   -- A closure the caller supplies; it reads the live registry on demand.
   type SubscriptionStatusProvider = IO [SubscriptionStatusRow]

   -- The canonical provider, built by a caller who owns the store:
   --   storeSubscriptionStatus store = subscriptionStatusRows <$> subscriptionStates store
   storeSubscriptionStatus :: KirokuStore -> SubscriptionStatusProvider

   -- GET /subscriptions            -> 200, JSON array of all rows
   -- GET /subscriptions/<name>     -> 200, JSON array of rows for that name (possibly empty)
   subscriptionsApp :: SubscriptionStatusProvider -> Application
   ```

   `subscriptionsApp` matches `pathInfo`: `["subscriptions"]` → run the provider,
   `jsonResponse status200 (encode rows)`; `["subscriptions", name]` → run the
   provider, filter `rows` to those whose `subscription == name`, return 200 with
   the (possibly empty) filtered array. Reuse `jsonResponse` from
   `Kiroku.Metrics.JSON` (export it from there if not already exported). Put
   `storeSubscriptionStatus` here so the caller has a one-liner.

4. **Wire into the server (`Kiroku.Metrics.Server`).** Thread an optional provider
   through without breaking EP-2's existing entry points:

   - Add `Maybe SubscriptionStatusProvider` as a parameter to `httpApp` and
     `combinedApp`. In `httpApp`, before the final 404, add:
     `["subscriptions"]` and `["subscriptions", _]` → if the provider is `Just p`,
     delegate to `subscriptionsApp p req respond`; if `Nothing`, return a 404 with
     `{"error":"subscription status not configured"}`.
   - Add a new lifecycle entry point that accepts the provider, leaving the
     existing ones working by defaulting it to `Nothing`:

     ```haskell
     startMetricsServerWith
       :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck]
       -> Maybe SubscriptionStatusProvider -> WS.ServerApp -> IO MetricsServer
     -- EP-2's 4-arg startMetricsServerWith (no provider) becomes:
     --   startMetricsServerWith cfg m deps = startMetricsServerWith' cfg m deps Nothing
     ```

     Concretely: rename EP-2's provider-less `startMetricsServerWith` body to a new
     `startMetricsServerWith'` (the 5-arg form including the provider), and keep
     `startMetricsServerWith cfg m deps wsApp = startMetricsServerWith' cfg m deps
     Nothing wsApp` plus
     `startMetricsServer cfg m deps = startMetricsServerWith' cfg m deps Nothing
     stubWebSocketApp` so all EP-2 call sites compile unchanged. Add a convenience
     `withMetricsServerSubscriptions :: MetricsServerConfig -> KirokuMetrics ->
     [DependencyCheck] -> SubscriptionStatusProvider -> (MetricsServer -> IO a) ->
     IO a` for the common case (a worker that wants subscription status but uses
     the stub WebSocket app).
   - Re-export `subscriptionsApp`, `storeSubscriptionStatus`,
     `SubscriptionStatusProvider`, and the new starters from the umbrella
     `Kiroku.Metrics` module.

   > This honors IP-3's rule that EP-3 needs no new *required* config field: the
   > provider is a function argument, not a `MetricsServerConfig` field, and it is
   > optional. EP-3's WebSocket seam and this plan's provider seam are independent.

5. Build: `cabal build kiroku-cli kiroku-metrics`.

Acceptance M1: start a worker in `ghci` (a real `withStore` that starts at least
one subscription, then `withMetricsServerSubscriptions defaultConfig m []
(storeSubscriptionStatus store) $ \_ -> ...`), and from another terminal:

```bash
curl -s http://localhost:9091/subscriptions | jq .
curl -s http://localhost:9091/subscriptions/<known-name> | jq .
```

The first prints a JSON array with one object per `(subscription, member)`; the
second prints just that subscription's rows. Phases change (`catching_up` →
`live`) and `global_position` advances as events are appended. A server started
*without* a provider returns `404 {"error":"subscription status not configured"}`
on `/subscriptions`.

### Milestone M2 — `kiroku subscriptions status --remote-url URL`

Scope: add the remote option to the CLI command algebra and parser, add an HTTP
fetch+decode that reuses the wire codec and the existing renderer, and branch the
runners so remote mode opens no local store. At the end the `kiroku` binary
queries a running worker.

1. **Command algebra (`Kiroku.Cli.Command`).** Add a remote endpoint to the status
   options:

   ```haskell
   newtype RemoteEndpoint = RemoteEndpoint Text deriving stock (Eq, Show)

   data StatusOptions = StatusOptions
     { outputFormat :: !OutputFormat
     , endpoint     :: !(Maybe RemoteEndpoint)   -- Nothing = local (in-process registry)
     }
     deriving stock (Eq, Show)
   ```

   Export `RemoteEndpoint(..)`. (The record gains a field; update construction
   sites in the parser accordingly — Step 2.)

2. **Parser (`Kiroku.Cli.Parser`).** In `statusOptionsParser`, add an optional
   `--remote-url URL` flag producing `Maybe RemoteEndpoint`:

   ```haskell
   <*> optional
         ( RemoteEndpoint . T.pack
             <$> strOption
                   ( long "remote-url"
                       <> metavar "URL"
                       <> help "Query a running worker's kiroku-metrics /subscriptions endpoint \
                               \(e.g. http://worker:9091) instead of this process's local registry."
                   )
         )
   ```

3. **Remote fetch + decode (`Kiroku.Cli.Subscription.Status`).** Add a function
   that GETs `<base>/subscriptions`, decodes `[SubscriptionStatusRow]` via the
   `FromJSON` from M1, and returns either an error message or the rows:

   ```haskell
   fetchRemoteSubscriptionStatusRows :: RemoteEndpoint -> IO (Either Text [SubscriptionStatusRow])
   ```

   Implement with `http-client` + `http-client-tls`: build a manager
   (`newManager tlsManagerSettings`), parse `<base>` joined with `/subscriptions`
   (trim a trailing slash on the base), `httpLbs` it, and on a 2xx
   `Aeson.eitherDecode` the body; map non-2xx and decode failures to a `Left` with
   a readable message (include status code / URL). Add a small
   `renderRemoteSubscriptionStatus :: RemoteEndpoint -> OutputFormat -> IO Text`
   that runs the fetch and either renders rows with the existing
   `renderSubscriptionStatusRows` or returns the error text.

4. **Cabal (`kiroku-cli.cabal`).** Add `http-client >=0.7 && <0.8` and
   `http-client-tls >=0.3 && <0.4` to the `library` `build-depends`. Add the same
   two to the `test-suite` deps (M3 needs them).

5. **Embeddable runner (`Kiroku.Cli.Run`).** Keep the in-process path and add the
   optional remote override. In `renderKirokuCommandWithStore`: when
   `endpoint == Just ep`, call `renderRemoteSubscriptionStatus ep format` (ignoring
   the store); when `Nothing`, keep today's `subscriptionStates store` path. This
   path is **not** useless — the host passes its own running store — so it stays.

6. **Convert the standalone binary to a pure remote client
   (`Kiroku.Cli.Standalone`).** This is the deliberate removal of the useless
   local mode (see the Decision Log). Rework the module so the standalone binary
   never opens a store:

   - `StandaloneOptions`: **drop** the `databaseUrl`, `schema`, and `poolSize`
     fields. What remains is the parsed `command :: KirokuCommand` (which already
     carries the `--remote-url` endpoint inside `StatusOptions`). The
     `standaloneOptionsParser` reduces to wrapping `kirokuCommandParser`; remove
     the `--database-url`/`--schema`/`--pool-size` option parsers.
   - `StandaloneRuntime`: **drop** the `settings :: ConnectionSettings` field. It
     now carries the resolved command with a concrete endpoint (e.g.
     `{ endpoint :: RemoteEndpoint, format :: OutputFormat }`, or just the command
     with its `endpoint` filled in).
   - `resolveStandaloneOptions :: [(String, String)] -> StandaloneOptions ->
     Either Text StandaloneRuntime` (signature unchanged so `app/Main.hs` keeps
     compiling): resolve the endpoint as the command's `--remote-url` **or** the
     `KIROKU_REMOTE_URL` env var; if neither is present, return `Left` with a clear
     message — e.g. *"kiroku: no worker endpoint; pass --remote-url or set
     KIROKU_REMOTE_URL. The standalone binary inspects a running worker over HTTP;
     it cannot see in-process subscriptions because it runs none."* Remove the
     existing `KIROKU_DATABASE_URL`/pool-size validation entirely.
   - `runStandaloneCommand :: StandaloneRuntime -> IO Text` (signature unchanged):
     render remotely via `renderRemoteSubscriptionStatus`; delete the `withStore`
     call and the `renderStandaloneCommand`-over-store path, including the
     "No live subscriptions in this process-local registry…" empty-message branch
     (now unreachable and obsolete).
   - Update `standaloneParserInfo`'s `progDesc`/`header` to describe a remote
     operator client (drop the "reads this process-local live registry" wording).
   - Remove the now-unused imports (`withStore`, `defaultConnectionSettings`,
     `ConnectionSettings`, `KirokuStore`, `subscriptionStates`, and the store-side
     lens plumbing) from `Standalone.hs`.

   `app/Main.hs` is unchanged: it still calls `standaloneParserInfo`,
   `resolveStandaloneOptions env opts`, and `runStandaloneCommand runtime`, whose
   signatures are preserved.

7. Build: `cabal build kiroku-cli`.

Acceptance M2: with the M1 worker still running,

```bash
cabal run kiroku -- subscriptions status --remote-url http://localhost:9091
cabal run kiroku -- subscriptions status --remote-url http://localhost:9091 --format json
```

The first prints the live subscriptions as a table (the same columns the
in-process command prints); the second prints the JSON array. `KIROKU_REMOTE_URL`
works as a fallback for `--remote-url`. Running the standalone binary with **no**
endpoint (`cabal run kiroku -- subscriptions status` with `KIROKU_REMOTE_URL`
unset) exits non-zero with the guidance message and never tries to open a database.
Pointing `--remote-url` at a dead port prints a clear connection-error message
(returns the `Left` text), not a Haskell exception dump.

### Milestone M3 — Round-trip and end-to-end tests

Scope: lock the wire contract and prove the remote path end to end. At the end
`cabal test kiroku-cli` and `cabal test kiroku-metrics` are green with the new
tests.

1. **Codec round-trip (`kiroku-cli/test`).** A property/unit test:
   `decode (encode rows) == Right rows` for representative
   `[SubscriptionStatusRow]` (multiple members, every phase string, large
   positions). Also assert the *exact* JSON keys (`subscription`, `member`,
   `phase`, `global_position`) so a rename can't silently break the contract.

2. **Cross-package shape check.** In `kiroku-metrics/test`, encode rows via the
   server path (`subscriptionStatusRows` over a hand-built
   `Map (SubscriptionName, Int32) SubscriptionStateView`, then the M1 `ToJSON`)
   and assert the bytes `Aeson.eitherDecode` back into the same rows the CLI's
   `FromJSON` would produce. (Both sides import `kiroku-cli`'s codec, so this
   guards against accidental local re-encoding.)

3. **End-to-end (`kiroku-metrics/test`).** Reusing EP-1's `withTestStore`
   (ephemeral Postgres) and EP-2's server harness: start a subscription on the
   store, append events, start the server with
   `storeSubscriptionStatus store` as the provider on an ephemeral port, then call
   `fetchRemoteSubscriptionStatusRows` (the real CLI client) against it and assert
   the returned rows include the subscription with a sane phase
   (`catching_up`/`live`) and a `globalPosition` that matches what was appended.
   Also assert `/subscriptions/<unknown>` returns an empty array and a server with
   `Nothing` provider yields the configured-404 `Left`.

Acceptance M3: `cabal test kiroku-cli` and `cabal test kiroku-metrics` are green,
including the three new tests; `nix build .#kiroku-cli` and
`nix build .#kiroku-metrics` succeed.


## Concrete Steps

Run from the repository root inside `nix develop`.

1. M1 — codec + endpoint:

   ```bash
   # edit kiroku-cli/src/Kiroku/Cli/Subscription/Status.hs (ToJSON/FromJSON + renderJson refactor)
   # edit kiroku-metrics/kiroku-metrics.cabal (+ kiroku-cli dep, + Kiroku.Metrics.Subscriptions)
   # write kiroku-metrics/src/Kiroku/Metrics/Subscriptions.hs
   # edit kiroku-metrics/src/Kiroku/Metrics/Server.hs (thread Maybe provider; new starters)
   cabal build kiroku-cli kiroku-metrics
   ```

   Smoke-test the endpoint (one terminal runs a worker in `ghci`; another):

   ```bash
   curl -s http://localhost:9091/subscriptions | jq .
   curl -i http://localhost:9091/subscriptions   # 404 if no provider wired
   ```

   Expected (provider wired, one live subscription):

   ```json
   [
     { "subscription": "inventory-projection", "member": 0, "phase": "live", "global_position": 42 }
   ]
   ```

2. M2 — CLI remote command:

   ```bash
   # edit kiroku-cli/src/Kiroku/Cli/Command.hs (RemoteEndpoint + endpoint field)
   # edit kiroku-cli/src/Kiroku/Cli/Parser.hs (--remote-url)
   # edit kiroku-cli/src/Kiroku/Cli/Subscription/Status.hs (fetch + render)
   # edit kiroku-cli/kiroku-cli.cabal (+ http-client, http-client-tls)
   # edit kiroku-cli/src/Kiroku/Cli/Run.hs (keep in-process; add --remote-url override)
   # edit kiroku-cli/src/Kiroku/Cli/Standalone.hs (gut to pure remote client; drop DB options/store)
   cabal build kiroku-cli
   cabal run kiroku -- subscriptions status --remote-url http://localhost:9091
   cabal run kiroku -- subscriptions status --remote-url http://localhost:9091 --format json
   KIROKU_REMOTE_URL=http://localhost:9091 cabal run kiroku -- subscriptions status
   cabal run kiroku -- subscriptions status   # no endpoint -> guidance error, exit 1, no DB opened
   ```

   Expected (table):

   ```text
   SUBSCRIPTION          MEMBER  PHASE  GLOBAL_POSITION
   inventory-projection  0       live   42
   ```

3. M3 — tests:

   ```bash
   cabal test kiroku-cli
   cabal test kiroku-metrics
   nix build .#kiroku-cli .#kiroku-metrics
   ```

4. Commit after each milestone with all three trailers:

   ```text
   feat(kiroku-metrics): serve live subscription status over HTTP

   MasterPlan: docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md
   ExecPlan: docs/plans/52-remote-subscription-status-http-endpoint-and-kiroku-cli-remote-client.md
   Intention: intention_01ks1saptfe6j8e98dvce7mvgf
   ```


## Validation and Acceptance

Complete when:

1. `cabal build kiroku-cli kiroku-metrics` and
   `nix build .#kiroku-cli .#kiroku-metrics` succeed.
2. `cabal test kiroku-cli` and `cabal test kiroku-metrics` are green, including
   the round-trip, cross-package shape, and end-to-end tests.
3. Behavioral, observable against a running worker (a `KirokuStore` with at least
   one subscription plus a `kiroku-metrics` server wired with
   `storeSubscriptionStatus store`):
   - `GET /subscriptions` → 200, JSON array, one object per
     `(subscription, member)`, with `phase` one of
     `catching_up|live|paused|reconnecting|retrying` and a numeric
     `global_position` that advances as events are appended.
   - `GET /subscriptions/<known>` → 200 with that subscription's rows;
     `GET /subscriptions/<unknown>` → 200 with `[]`.
   - A server started without a provider → `GET /subscriptions` returns
     `404 {"error":"subscription status not configured"}`.
   - `kiroku subscriptions status --remote-url http://localhost:9091` prints the
     live subscriptions as a table identical in columns to the local command;
     `--format json` prints the array.
   - `--remote-url` against an unreachable host prints a readable error, not an
     exception dump.
   - The standalone binary opens no database: with no `--remote-url` and no
     `KIROKU_REMOTE_URL`, `kiroku subscriptions status` exits non-zero with the
     guidance message; `--database-url`/`--schema`/`--pool-size` no longer exist.
4. The embeddable in-process path is unchanged:
   `renderKirokuCommandWithStore store (subscriptions status)` (no `--remote-url`)
   still reads the host store's in-process registry exactly as before, and accepts
   `--remote-url` as an optional override.


## Idempotence and Recovery

All edits are additive. Re-running `cabal build`/`cabal test` is harmless. The
endpoint and the CLI command are read-only — they never write to the store, the
registry, or the database; repeating a query is always safe. If a web dependency
(`http-client`, `http-client-tls`) is missing under Nix, add an overlay entry in
`nix/haskell-overlay.nix` mirroring existing ones and re-run `nix build`; record
it in Surprises & Discoveries. The end-to-end test uses an ephemeral database and
an OS-assigned port (`port = 0`) to avoid collisions on repeat runs.


## Interfaces and Dependencies

New/changed in `kiroku-cli`:

- `Kiroku.Cli.Command` — add `RemoteEndpoint(..)`; add `endpoint :: Maybe
  RemoteEndpoint` to `StatusOptions`.
- `Kiroku.Cli.Parser` — `statusOptionsParser` gains `--remote-url URL`.
- `Kiroku.Cli.Subscription.Status` — add `ToJSON`/`FromJSON SubscriptionStatusRow`
  (the IP-5 wire codec, single source of truth); refactor `renderJson` onto the
  `ToJSON`; add `fetchRemoteSubscriptionStatusRows :: RemoteEndpoint -> IO (Either
  Text [SubscriptionStatusRow])` and `renderRemoteSubscriptionStatus ::
  RemoteEndpoint -> OutputFormat -> IO Text`.
- `Kiroku.Cli.Run` — keep the in-process path; branch on `endpoint` so a host can
  pass `--remote-url` as an override (remote → HTTP fetch, no store; `Nothing` →
  existing `subscriptionStates store` path). Signature unchanged.
- `Kiroku.Cli.Standalone` — **gutted to a pure remote client.** Drop the
  `databaseUrl`/`schema`/`poolSize` fields from `StandaloneOptions` and the
  `settings :: ConnectionSettings` field from `StandaloneRuntime`; drop the
  `--database-url`/`--schema`/`--pool-size` parsers; `resolveStandaloneOptions`
  resolves the endpoint from `--remote-url` or `KIROKU_REMOTE_URL` and errors if
  absent; `runStandaloneCommand` renders remotely with no `withStore`. Signatures
  of `standaloneParserInfo`/`resolveStandaloneOptions`/`runStandaloneCommand` are
  preserved so `app/Main.hs` is untouched. Remove now-unused `kiroku-store`
  imports.
- `kiroku-cli.cabal` — add `http-client`, `http-client-tls` (library + test). The
  `kiroku-store` dependency stays (the library still uses its types via the
  embeddable `Kiroku.Cli.Run` path and `SubscriptionStatusRow` mapping).

New/changed in `kiroku-metrics`:

- `Kiroku.Metrics.Subscriptions` (new) — `type SubscriptionStatusProvider = IO
  [SubscriptionStatusRow]`, `storeSubscriptionStatus :: KirokuStore ->
  SubscriptionStatusProvider`, `subscriptionsApp :: SubscriptionStatusProvider ->
  Application` (routes `/subscriptions` and `/subscriptions/<name>`).
- `Kiroku.Metrics.Server` — thread `Maybe SubscriptionStatusProvider` through
  `httpApp`/`combinedApp`; add the 5-arg `startMetricsServerWith'`, keep EP-2's
  `startMetricsServer`/`startMetricsServerWith` working (provider defaults to
  `Nothing`), add `withMetricsServerSubscriptions`.
- `Kiroku.Metrics` (umbrella) — re-export the new server starters,
  `subscriptionsApp`, `storeSubscriptionStatus`, `SubscriptionStatusProvider`.
- `Kiroku.Metrics.JSON` — ensure `jsonResponse` is exported for reuse.
- `kiroku-metrics.cabal` — add `kiroku-cli ^>=0.1`; add
  `Kiroku.Metrics.Subscriptions` to `exposed-modules`.

Reused from `kiroku-store` (unchanged): `KirokuStore`,
`Kiroku.Store.Subscription.subscriptionStates`, `SubscriptionStateView`. Reused
from `kiroku-cli` by `kiroku-metrics`: `SubscriptionStatusRow`,
`subscriptionStatusRows`, and the wire codec.

Dependency direction (no cycle): `kiroku-metrics → kiroku-cli → kiroku-store`.
`kiroku-cli` does not depend on `kiroku-metrics`.

Integration point owned: **IP-5** — the subscription-status wire JSON contract
(a JSON array of `{subscription, member, phase, global_position}`), defined by
`SubscriptionStatusRow`'s codec in `kiroku-cli`, encoded by `kiroku-metrics`'s
`/subscriptions`, decoded by `kiroku-cli`'s remote command.
