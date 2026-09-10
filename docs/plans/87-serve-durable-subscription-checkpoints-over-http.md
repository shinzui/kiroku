---
id: 87
slug: serve-durable-subscription-checkpoints-over-http
title: "Serve durable subscription checkpoints over HTTP"
kind: exec-plan
created_at: 2026-09-10T02:45:19Z
intention: "intention_01m24k3bxye7cv6x088hpvs6ne"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-10T02:45:19Z
---

# Serve durable subscription checkpoints over HTTP

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan implements the improvement request
[IR-10, Serve durable subscription checkpoints over HTTP](../improvement-requests/serve-durable-subscription-checkpoints-over-http.md),
canonically `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-10`. The request was
filed by the keiro runtime UI initiative (`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`,
under `mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`),
which is building a browser UI over the keiro runtime stack and needs every subscription's
persisted position to be visible over HTTP. The library capability the endpoint wraps already
shipped: `subscriptionCheckpointInventory` has been public in `kiroku-store` since 0.4.0.0
(IR-2, [plan 69](69-expose-a-performant-durable-subscription-checkpoint-inventory.md)). This
plan adds only the missing HTTP surface in `kiroku-metrics`, its tests, its documentation, and
the release that makes it consumable. It is a single ExecPlan without a MasterPlan.


## Purpose / Big Picture

Kiroku's `kiroku-metrics` package already answers "what is running right now?" over HTTP:
`GET /subscriptions` returns the live subscription registry of whichever worker process the
request reaches. It cannot answer the question an operator dashboard actually needs: "where is
every subscription's durable, committed checkpoint?" A worker that has stopped disappears from
the live registry while its checkpoint row remains in PostgreSQL; a deployment with several
worker processes shows a different registry per process; and a process that never wired the
live status provider answers 404. The durable answer already exists in Haskell
(`subscriptionCheckpointInventory`) and in SQL (`kiroku.subscription_checkpoints_v1`), but a
browser speaks neither.

After this plan, any `kiroku-metrics` server started from a `KirokuStore` answers
`GET /subscriptions/checkpoints` with the durable inventory: the captured store position plus
one row per persisted checkpoint (subscription name, consumer-group member, exact persisted
position, last-update timestamp), in ascending (name, member) order, identical no matter which
process is asked. The existing live endpoint is untouched, so a UI can render "live cursor" and
"durable checkpoint" side by side and truthfully. Seeing it work is one request:

```bash
curl -s http://localhost:9091/subscriptions/checkpoints | jq .
```

```json
{
  "store_position": 42,
  "checkpoints": [
    {
      "subscription": "inventory-projection",
      "member": 0,
      "checkpoint_position": 40,
      "updated_at": "2026-09-10T02:41:07.512339Z"
    }
  ]
}
```

Stop the worker that runs `inventory-projection` and repeat the request: the row is still
there, with the same position, while `GET /subscriptions` no longer lists it. Ask a second
process that shares the database: the durable body is the same.


## Progress

- [ ] Milestone 1: `Kiroku.Metrics.Checkpoints` module with the provider type, the canonical
      store-backed provider, the wire types and their hand-written JSON codec, the
      `checkpointsApp` WAI application, and the pure codec test; IR-10 set to `in_progress`.
- [ ] Milestone 2: `MetricsProviders` record threaded through `Kiroku.Metrics.Server`;
      `/subscriptions/checkpoints` matched as a reserved segment ahead of the by-name live route;
      structured not-configured envelope; store-backed starters serve the durable route
      automatically; umbrella re-exports; existing suites green.
- [ ] Milestone 3: end-to-end `Test.CheckpointsSpec` coverage for every IR-10 acceptance item
      (stopped-worker retention versus live absence, ordering, two handles over one database,
      no live provider, empty store, not configured, provider failure, standalone 404).
- [ ] Milestone 4: `docs/user/metrics.md` section with transcript and the live-versus-durable
      explanation, cross-links from `docs/user/subscriptions.md` and `docs/user/operator-cli.md`,
      the self-verifying example extended, CAP-17 updated, changelog `Unreleased` entry, IR-10
      body updated with implementation evidence, all repository validations green.
- [ ] Milestone 5: `kiroku-metrics` 0.2.0.0 released after explicit user confirmation, IR-10
      set to `completed` with release evidence, ADR distillation pass performed, Outcomes written.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The route is `GET /subscriptions/checkpoints`, matched in the router as a reserved
  literal segment before the live by-name route `GET /subscriptions/<name>`.
  Rationale: It is the path the request suggests and the path the keiro-ui audit expects
  (`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`
  names it), and it reads as "the checkpoints of subscriptions". The router already reserves a
  literal segment under a name-parameterised prefix: `/metrics/prometheus` is matched before
  `/metrics/<name>` in `kiroku-metrics/src/Kiroku/Metrics/Server.hs`. The cost is that a
  subscription literally named `checkpoints` cannot be filtered by name on the live route; it
  still appears in the full `GET /subscriptions` listing, and the documentation states the
  reservation. Top-level `/checkpoints` and `/subscription-checkpoints` were considered and
  rejected as less discoverable and inconsistent with the request's wording. The future
  dead-letter route proposed by IR-9 (`/subscriptions/<name>/dead-letters`) has three segments
  and does not collide.
  Date: 2026-09-10

- Decision: The response is a JSON object, not an array: `{"store_position": N,
  "checkpoints": [ {"subscription", "member", "checkpoint_position", "updated_at"}, ... ]}`,
  with every key in snake_case, no `phase` field, no computed lag, and no visible head.
  Rationale: The request requires the durable shape to be visibly distinct from the live
  array of `{subscription, member, phase, global_position}`; an object with a captured
  `store_position` and a different position key (`checkpoint_position`) makes accidental
  conflation impossible while keeping `subscription` and `member` as join keys. The cross-project
  conventions (`mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`,
  artifact-level URI pending) require snake_case for new fields and forbid deriving "lag" from a
  position distance on the wire; consumers subtract `checkpoint_position` from `store_position`
  themselves and call it a position distance. The visible global head is a separate
  statement-time observation (ADR-4) and would not share the inventory's snapshot, so it is not
  added here; an additive field on a later plan remains possible.
  Date: 2026-09-10

- Decision: The server stays store-agnostic. Durable data arrives through a provider closure,
  `type CheckpointInventoryProvider = IO (Either StoreError SubscriptionCheckpointInventory)`,
  whose canonical implementation is `storeCheckpointInventory store = runStoreIO store
  subscriptionCheckpointInventory`. The two optional providers are grouped in a new record
  `MetricsProviders { subscriptionStatus, checkpointInventory }` that replaces the single
  `Maybe SubscriptionStatusProvider` argument of `startMetricsServerWith'`, `combinedApp`, and
  `httpApp`.
  Rationale: Plan 33 and plan 52 deliberately keep `KirokuStore` out of the server signature and
  supply store-specific behaviour as closures (`postgresPing`, `storeSubscriptionStatus`); this
  follows the same rule. A record rather than a second positional `Maybe` means the next
  store-backed routes (IR-8 browsing, IR-9 dead letters) can add a field without another
  positional signature change for callers that use record update. The `Either StoreError`
  result keeps database failures typed so the route can answer 503 with a structured envelope and
  mock providers can simulate failure.
  Date: 2026-09-10

- Decision: The change is a PVP major bump: `kiroku-metrics` 0.1.0.8 becomes 0.2.0.0.
  Rationale: `startMetricsServerWith'`, `combinedApp`, and `httpApp` are exported and their
  argument types change. No in-repository code outside `Server.hs` calls them, so the
  in-repository migration is internal; external callers adapt by replacing `Nothing`/`Just p`
  with `noProviders`/`noProviders{subscriptionStatus = Just p}`. `kiroku-store` does not change (the inventory API shipped in 0.4.0.0 and the current
  bound `^>=0.8` already admits it), and `kiroku-cli` does not change.
  Date: 2026-09-10

- Decision: The store-backed starters `startMetricsServerWithStore` and
  `withMetricsServerWithStore` wire the durable provider automatically from the store they
  already receive, and do not start wiring the live status provider.
  Rationale: The request says any process with store access must be able to serve the durable
  inventory without a status provider, and these starters own a `KirokuStore`. Wiring the live
  provider there too would flip `GET /subscriptions` from 404 to 200 for existing call sites,
  which contradicts the request's "existing endpoints unchanged" acceptance. A worker that wants
  both routes uses `startMetricsServerWith'` with `storeProviders store`, which the user guide
  shows.
  Date: 2026-09-10

- Decision: The new route reports errors with the structured envelope
  `{"error": {"code": "<snake_case>", "message": "<sentence>"}}` (404
  `checkpoint_inventory_not_configured`, 503 `checkpoint_inventory_unavailable`, 404 `not_found`
  when mounted standalone), while every existing endpoint keeps its published
  `{"error": "<string>"}` body.
  Rationale: The cross-project conventions require the envelope for new endpoints and freeze
  shipped shapes. The envelope helper lives in `Kiroku.Metrics.JSON` so IR-8 and IR-9 reuse it.
  Date: 2026-09-10

- Decision: The wire types and codec live in `kiroku-metrics`
  (`Kiroku.Metrics.Checkpoints`), not in `kiroku-cli`, and no CLI command is added.
  Rationale: Plan 52 put the live row codec in `kiroku-cli` because the CLI remote client decodes
  it. IR-10 asks for the HTTP surface only. Keeping the codec in the serving package avoids a
  `kiroku-cli` release for a type nothing in that package uses; the `FromJSON` instance is
  still provided so tests round-trip and a future client can decode. If a
  `kiroku subscriptions checkpoints --remote-url` command is wanted later, a follow-up plan can
  move the codec down to `kiroku-cli` and re-export it from `kiroku-metrics`, which is a
  non-breaking change for HTTP consumers.
  Date: 2026-09-10

- Decision: IR-10's `status` moves from `proposed` to `accepted` when this plan is created
  (with the request's Status section linking the plan), to `in_progress` when Milestone 1
  starts, and to `completed` (with `completedAt`) only after the release evidence exists; the
  release itself requires explicit user confirmation through the repository `release` skill.
  Rationale: This is the lifecycle plans 69 and 72 followed, using Mori's closed vocabulary
  (`proposed`, `accepted`, `in_progress`, `completed`, `declined`, `superseded`); plan 72's use
  of `implemented` was later corrected. Earlier requests stayed `proposed` at planning time only
  because they were filed together with their plans; IR-10 predates its plan, so acceptance is
  a distinct, recordable step. Publishing is irreversible and the request leaves version bumps
  "at kiroku's discretion", so a human confirms.
  Date: 2026-09-10

- Decision: No new ADR is planned up front. The distillation pass at completion decides whether
  the reserved-segment and envelope decisions deserve a record; IR-13 (wire-format stability
  ADR) is separate work and this plan neither pre-empts nor blocks it.
  Rationale: The durable-versus-live separation is already recorded by ADR-4 and IR-2; the
  routing and envelope choices are package-local until IR-13 records the HTTP stability
  contract. This plan's user documentation states the durable route's stability promise in
  prose so a client has something to cite meanwhile.
  Date: 2026-09-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### Terms used in this plan

A **subscription** is a named consumer of Kiroku's event log that receives events in global
position order and periodically persists how far it has got. A **checkpoint** is that persisted
progress: one row per `(subscription_name, consumer_group_member)` in the `subscriptions` table
of the `kiroku` schema, holding the exact `GlobalPosition` (`last_seen`) and the time of the last
successful write (`updated_at`). A **consumer-group member** is one of N workers sharing a
subscription name; a subscription that is not grouped is member `0`, and a row alone cannot say
which case it is. The **global position** is the monotonically increasing sequence number of an
event in the store-wide `$all` log. The **store position** (also called the authoritative append
frontier) is the greatest global position ever allocated; it is read from the `$all` stream row
and never decreases, even after hard deletion. The **visible global head** is a different value,
the greatest position still present in `$all`, which can regress; this plan does not serve it.

The **live registry** is an in-memory map on one `KirokuStore` handle, read through
`Kiroku.Store.Subscription.subscriptionStates`, listing the workers running in that process with
their current finite-state-machine phase and cursor. A stopped worker is absent. The **durable
inventory** is the database fact, read through the mockable `Store` effect operation
`Kiroku.Store.Subscription.subscriptionCheckpointInventory`, and lists every persisted checkpoint
regardless of which process wrote it or whether its worker still runs.

A **WAI `Application`** is the standard Haskell value a web server such as Warp runs: a function
from a request to a response. `kiroku-metrics` builds one router application from small
per-route applications and mounts it on Warp. A **provider closure** is an `IO` action the host
supplies so the server can fetch store-backed data without holding the `KirokuStore` itself.
**PVP** is the Haskell Package Versioning Policy: a change to an exported function's type is a
major bump (`0.1.x` to `0.2.0.0`); an addition is a minor bump.

### The library API this endpoint wraps (unchanged)

`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` defines the two public result types:

```haskell
data SubscriptionCheckpoint = SubscriptionCheckpoint
    { subscriptionName :: !SubscriptionName
    , consumerGroupMember :: !Int32
    , checkpointPosition :: !GlobalPosition
    , checkpointUpdatedAt :: !UTCTime
    }

data SubscriptionCheckpointInventory = SubscriptionCheckpointInventory
    { storePosition :: !GlobalPosition
    , checkpoints :: !(Vector SubscriptionCheckpoint)
    }
```

`kiroku-store/src/Kiroku/Store/Subscription.hs` exports
`subscriptionCheckpointInventory :: (HasCallStack, Store :> es) => Eff es SubscriptionCheckpointInventory`
and its Haddock fixes the semantics this plan must carry to the wire: the position and rows come
from one SQL statement snapshot and one round trip; an empty vector means no checkpoint has been
written, not that no subscription exists; stopped subscriptions remain; rows are sorted by name
then member; a fresh call is needed to observe later commits; a live worker's cursor may be ahead
of its durable row; member zero does not reveal group membership; `checkpointUpdatedAt` is a write
time, not proof of advance; and `storePosition - checkpointPosition` is a position distance, not
an exact backlog for category, filtered, or sharded consumers. `Kiroku.Store` (the umbrella
module) re-exports all of this together with `runStoreIO :: KirokuStore -> Eff '[Store, Error
StoreError, IOE] a -> IO (Either StoreError a)` (defined in
`kiroku-store/src/Kiroku/Store/Effect.hs`) and `StoreError` (defined in
`kiroku-store/src/Kiroku/Store/Error.hs`, whose constructors include `ConnectionError !Text`,
useful for a failing test provider). `SubscriptionName` is a newtype over `Text`;
`GlobalPosition` is a newtype over `Int64` (`kiroku-store/src/Kiroku/Store/Types.hs`).

The store-level behaviour is proven by `kiroku-store/test/Test/SubscriptionCheckpointInventory.hs`.
That file also shows how a test seeds checkpoint rows without running a worker:
`Kiroku.Store.SQL` is an exposed module and
`saveCheckpointMemberStmt :: Statement (Text, Int32, Int64) ()` is executed with
`Pool.use store.pool (Session.statement (name, member, position) SQL.saveCheckpointMemberStmt)`.
The `pool` field is public on `KirokuStore` (the metrics health check in
`kiroku-metrics/src/Kiroku/Metrics/Health.hs` uses `store.pool` the same way).

### The metrics server today (where the route mounts)

Everything below is under `kiroku-metrics/`, version 0.1.0.8 in `kiroku-metrics.cabal`. The
package's `common` stanza enables `DuplicateRecordFields`, `OverloadedRecordDot`,
`OverloadedStrings`, `RecordWildCards`, `LambdaCase`, `DerivingStrategies`, and builds with
`-Wall -Werror=incomplete-patterns`.

`src/Kiroku/Metrics/Server.hs` holds the router and the lifecycle. Its HTTP router is:

```haskell
httpApp cfg m deps mProvider req respond =
    case pathInfo req of
        ["metrics", "prometheus"] | cfg.enablePrometheus -> prometheusApp m req respond
        ["metrics"] | cfg.enableJSON -> jsonApp m req respond
        ["metrics", _] | cfg.enableJSON -> jsonApp m req respond
        ["subscriptions"] -> subscriptionsRoute
        ["subscriptions", _] -> subscriptionsRoute
        ["health"] | cfg.enableJSON -> ...
        ["health", "live"] | cfg.enableJSON -> ...
        ["health", "ready"] | cfg.enableJSON -> ...
        ["ws"] | cfg.enableWebSocket -> ...
        _ -> respond (jsonResponse status404 (encode (object ["error" .= ("Not found" :: Text)])))
  where
    subscriptionsRoute = case mProvider of
        Just provider -> subscriptionsApp provider req respond
        Nothing -> respond $ jsonResponse status404
            (encode (object ["error" .= ("subscription status not configured" :: Text)]))
```

The starters are `startMetricsServer` (stub WebSocket, no provider), `startMetricsServerWith`
(explicit WebSocket app, no provider), `startMetricsServerWith'` (explicit WebSocket app and
`Maybe SubscriptionStatusProvider`; the one that actually binds Warp, using an OS-assigned port
when `cfg.port == 0`), `startMetricsServerWithStore` (real WebSocket app built from a
`KirokuStore`, no provider), and the bracketed `withMetricsServer`, `withMetricsServerWithStore`,
`withMetricsServerSubscriptions`. `combinedApp` composes the WebSocket app and `httpApp` with
`websocketsOr`.

`src/Kiroku/Metrics/Subscriptions.hs` is the model for the new module: it defines
`type SubscriptionStatusProvider = IO [SubscriptionStatusRow]`, the canonical
`storeSubscriptionStatus :: KirokuStore -> SubscriptionStatusProvider`, and
`subscriptionsApp :: SubscriptionStatusProvider -> Application`, which matches
`["subscriptions"]` and `["subscriptions", name]` and answers `404 {"error":"Not found"}` for
anything else when mounted standalone. Its row type and JSON codec come from
`kiroku-cli/src/Kiroku/Cli/Subscription/Status.hs` (keys `subscription`, `member`, `phase`,
`global_position`), shared with the CLI remote client.

`src/Kiroku/Metrics/JSON.hs` exports `jsonResponse :: Status -> LBS.ByteString -> Response`
(sets `application/json`). `src/Kiroku/Metrics.hs` is the umbrella module that re-exports every
submodule. `src/Kiroku/Metrics/Config.hs` holds `MetricsServerConfig` and `defaultConfig`
(port 9091); no configuration field changes in this plan.

The test suite is Hspec, entered from `test/Main.hs`, which wraps every spec in
`withSharedMigratedPostgres` from `kiroku-test-support` (`Kiroku.Test.Postgres`); individual
tests call `withMigratedTestDatabase :: (Text -> IO a) -> IO a` to get a fresh migrated database
connection string. `test/Test/SubscriptionsSpec.hs` is the closest precedent: it boots a store,
subscribes with `defaultSubscriptionConfig name AllStreams (\_ -> pure Continue)`, waits for the
`live` phase by polling `subscriptionStates`, starts a server on `port = 0`, and issues raw
`http-client` GETs. Existing test dependencies already include `aeson`, `hasql`, `hasql-pool`,
`http-client`, `http-types`, `lens`, `generic-lens`, `kiroku-cli`, `kiroku-store`,
`kiroku-test-support`, `warp`, `text`, `containers`; they do not include `time` or `vector`,
which Milestone 3 adds.

`example/Main.hs` is the self-verifying example (`cabal run kiroku-metrics-example`, cabal flag
`example`, off by default for the published package) whose transcript `docs/user/metrics.md`
quotes; it appends three events to `orders-1` and checks every endpoint over real HTTP.

### Documentation and knowledge bundles touched

`docs/user/metrics.md` is the package user guide, with sections "Wiring the collector",
"Starting the server", "HTTP endpoints", "Subscription status over HTTP", and "Try it".
`docs/user/subscriptions.md` has a "Reading Durable Checkpoints" section that lists the three
durable-and-live surfaces (`subscriptionStates`, `subscriptionCheckpointInventory`,
`kiroku.subscription_checkpoints_v1`); the new HTTP surface becomes a fourth entry.
`docs/user/operator-cli.md` explains the `/subscriptions` remote client and notes that it
reports live cursors, not durable checkpoints.

`docs/capabilities/operational-http-endpoints.md` is capability `CAP-17` in the profile-governed
`capabilities` OKF bundle (validated by `just capabilities-validate`); its `description`,
`interface`, `evidence`, and body must mention the new route, and `docs/capabilities/log.md`
receives a dated `Update` entry. Earlier updates (CAP-4 on 2026-08-12, CAP-1 on 2026-08-13)
changed body and description and added a log entry without altering `generated.at`.

`docs/improvement-requests/serve-durable-subscription-checkpoints-over-http.md` is IR-10 in the
`improvement-requests` OKF bundle governed by `mori/improvement-requests-profile.dhall`
(okf-profiles v0.5.0 `coordination.improvementRequests`). Its frontmatter carries `timestamp`,
`requestId: IR-10`, `status: accepted` (set when this plan was created; its Status section
links back here), and `origin: mori://shinzui/keiro-ui`. Status changes must advance
`timestamp`, add a dated entry to `docs/improvement-requests/log.md`, and pass the strict
validation command in Concrete Steps.

`agents/skills/release/SKILL.md` is the release procedure (independent per-package PVP versions,
tags named `<package>-v<version>`, publish order `kiroku-store`, `kiroku-store-migrations`,
`kiroku-otel`, `kiroku-cli`, `kiroku-metrics`, `shibuya-kiroku-adapter`). Only `kiroku-metrics`
is released by this plan.

### Relevant architecture decisions

Local ADRs read for this plan (others were scanned by heading and are not relevant):

- [ADR-4, Subscription checkpoint initialization is explicit and reset is a separate transaction operation](../adr/0004-explicit-subscription-checkpoint-lifecycle.md):
  a checkpoint row is created at worker startup by an explicit policy (`FromBeginning` inserts
  position zero), existing rows always win, ordinary saves are monotonic, and the authoritative
  append frontier reported as `storePosition` is distinct from the regressing visible head. The
  endpoint therefore serves rows that exist before a worker has processed anything, and never
  substitutes the visible head for `store_position`.
- [ADR-6, Versioned public SQL relations are owner-published and frozen](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md):
  `kiroku.subscription_checkpoints_v1` is the SQL-native equivalent of this endpoint and is
  frozen; the HTTP body mirrors its row contract (name, member, position, updated time) and adds
  the same-snapshot `store_position` the view cannot carry. The stability posture of a published
  surface applies to the new route: fields are never removed or re-typed.
- [ADR-2, Consumer groups are static, hash-partitioned competing consumers](../adr/0002-static-hash-partitioned-consumer-groups.md):
  one durable row per member explains why the response is keyed by `(subscription, member)`.

Cross-repository decisions, cited by the canonical handles the keiro-ui bundle publishes:

- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1` (inspection endpoints live in the project
  that owns the concept) is why this endpoint is kiroku's to build, and
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7` (read-only first, with owning-repository
  gates) is why it is read-only.
- The shared wire conventions are `mori://shinzui/keiro-ui`,
  `docs/architecture/inspection-api-conventions.md` (artifact-level URI pending). The rules that
  bind here: snake_case new fields (section 2), the structured error envelope for new endpoints
  with frozen legacy string errors (section 4), published shapes are frozen (section 9), and the
  vocabulary rule that a distance from the store position is a position distance, never "lag"
  (section 10). Section 8 also requires this plan's documentation to restate that the server has
  no authentication and assumes a trusted network or an authenticating proxy.

`mori path` may report these handles as not found because registry observation lags fresh
commits (plan 69 recorded the same); per repository policy the canonical URIs are retained.


## Plan of Work

### Milestone 1: the durable checkpoints module and its wire codec

Scope: create `kiroku-metrics/src/Kiroku/Metrics/Checkpoints.hs`, a self-contained module that
turns a provider closure into a WAI application serving `GET /subscriptions/checkpoints`, and
prove its JSON shape with a pure test. At the end of this milestone the module compiles, is
exported from the package, can be mounted standalone with `Warp.testWithApplication`, and the
exact wire keys are locked by a test. Nothing in the router changes yet.

First move IR-10 from `accepted` to `in_progress`: in
`docs/improvement-requests/serve-durable-subscription-checkpoints-over-http.md` set
`status: in_progress`, advance `timestamp` to the current UTC time, and under `## Status`
change the acceptance paragraph (which already links this plan) to say implementation is under
way. Add a dated `**Implementation**` entry to `docs/improvement-requests/log.md` and run the
strict bundle validation from Concrete Steps.

Then add a reusable error-envelope helper to `kiroku-metrics/src/Kiroku/Metrics/JSON.hs` and
export it:

```haskell
-- | The structured error body used by endpoints added from IR-10 onwards:
-- @{"error":{"code":"...","message":"..."}}@. Existing endpoints keep their
-- published @{"error":"<string>"}@ bodies; do not migrate them.
errorEnvelope :: Text -> Text -> Value
errorEnvelope code message =
    object ["error" .= object ["code" .= code, "message" .= message]]
```

Write the new module. The provider type and canonical provider mirror
`Kiroku.Metrics.Subscriptions`, but the result keeps the store error because the database can be
unavailable:

```haskell
{- | The @GET /subscriptions/checkpoints@ HTTP endpoint (IR-10).

Serves the __durable__ subscription checkpoint inventory: the captured store
position and every persisted @(subscription, member)@ checkpoint row, read
through the public 'Kiroku.Store.Subscription.subscriptionCheckpointInventory'
operation. Unlike @GET /subscriptions@ (the process-local live registry), the
answer is identical from every process that shares the database, stopped
subscriptions remain present, and no status provider is required.
-}
module Kiroku.Metrics.Checkpoints (
    CheckpointInventoryProvider,
    storeCheckpointInventory,
    CheckpointInventoryResponse (..),
    CheckpointRow (..),
    checkpointInventoryResponse,
    checkpointsApp,
    checkpointsPath,
) where

type CheckpointInventoryProvider = IO (Either StoreError SubscriptionCheckpointInventory)

storeCheckpointInventory :: KirokuStore -> CheckpointInventoryProvider
storeCheckpointInventory store = runStoreIO store subscriptionCheckpointInventory
```

Define the wire types with plain `Int64`/`Int32`/`Text`/`UTCTime` fields so the JSON shape is
independent of `kiroku-store` newtypes, and a pure mapping from the library type:

```haskell
data CheckpointRow = CheckpointRow
    { subscription :: !Text
    , member :: !Int32
    , checkpointPosition :: !Int64
    , updatedAt :: !UTCTime
    }
    deriving stock (Eq, Show)

data CheckpointInventoryResponse = CheckpointInventoryResponse
    { storePosition :: !Int64
    , checkpoints :: ![CheckpointRow]
    }
    deriving stock (Eq, Show)

checkpointInventoryResponse :: SubscriptionCheckpointInventory -> CheckpointInventoryResponse
checkpointInventoryResponse (SubscriptionCheckpointInventory (GlobalPosition position) rows) =
    CheckpointInventoryResponse position (map toRow (V.toList rows))
  where
    toRow (SubscriptionCheckpoint (SubscriptionName name) memberIndex (GlobalPosition cp) updatedAt) =
        CheckpointRow name memberIndex cp updatedAt
```

Write the `ToJSON` and `FromJSON` instances by hand (the package's existing types do the same so
the wire shape is explicit and stable). The keys are exactly `store_position`, `checkpoints`,
`subscription`, `member`, `checkpoint_position`, `updated_at`. `UTCTime` encodes through aeson's
instance as an RFC 3339 UTC string such as `"2026-09-10T02:41:07.512339Z"`. Preserve the
library's row order; do not sort in the mapping.

The application matches the exact path and delegates everything else to a structured 404:

```haskell
checkpointsPath :: [Text]
checkpointsPath = ["subscriptions", "checkpoints"]

checkpointsApp :: CheckpointInventoryProvider -> Application
checkpointsApp provider req respond
    | pathInfo req == checkpointsPath = do
        result <- provider
        respond $ case result of
            Right inventory ->
                jsonResponse status200 (encode (checkpointInventoryResponse inventory))
            Left err ->
                jsonResponse status503 $ encode $ errorEnvelope
                    "checkpoint_inventory_unavailable"
                    ("could not read the durable checkpoint inventory: " <> T.pack (show err))
    | otherwise =
        respond (jsonResponse status404 (encode (errorEnvelope "not_found" "Not found")))
```

Do not restrict the HTTP method; the sibling applications do not, and adding method checks to
one route would be an inconsistent surface. Exceptions thrown by a provider propagate to Warp
exactly as they do for the sibling routes; only a returned `Left` is mapped to 503.

Register the module: add `Kiroku.Metrics.Checkpoints` to `exposed-modules` in
`kiroku-metrics/kiroku-metrics.cabal` (the library already depends on `aeson`, `text`, `time`,
`vector`, `wai`, `http-types`, `kiroku-store`) and add `module Kiroku.Metrics.Checkpoints` to the
export list and import list of `kiroku-metrics/src/Kiroku/Metrics.hs`. Add an `## Unreleased`
section at the top of `kiroku-metrics/CHANGELOG.md` with a `### New Features` bullet describing
the route; Milestone 2 adds the `### Breaking Changes` bullet.

Create `kiroku-metrics/test/Test/CheckpointsSpec.hs`, register it in `kiroku-metrics/test/Main.hs`
(import it and call `CheckpointsSpec.spec` inside the `hspec` block) and in the test-suite
`other-modules` of the cabal file, and add `time >=1.12 && <1.15` and `vector >=0.13 && <0.14`
to the test-suite `build-depends`. The first test is pure: build a
`SubscriptionCheckpointInventory` with `storePosition = GlobalPosition 17` and two rows (for
example `("beta", 1, 11)` and `("alpha", 0, 7)` with `updatedAt = UTCTime (fromGregorian 2026 9 10) 0`),
map it, and assert `Aeson.toJSON` equals the literal
`Aeson.object ["store_position" .= (17 :: Int), "checkpoints" .= [ ... ]]` with the exact keys
above and `"updated_at" .= ("2026-09-10T00:00:00Z" :: Text)`, then assert
`Aeson.eitherDecode (Aeson.encode response) == Right response`. A second pure test mounts
`checkpointsApp (pure (Right inventory))` with `Warp.testWithApplication` and checks a GET on
`/subscriptions/checkpoints` returns 200 with the same body, and a GET on `/definitely/not`
returns 404 with `{"error":{"code":"not_found","message":"Not found"}}`.

Acceptance for Milestone 1: `cabal build kiroku-metrics` succeeds, and
`cabal test kiroku-metrics --test-options='--match Checkpoints'` reports the two new examples
passing.

### Milestone 2: mount the route in the server without touching the live route

Scope: introduce `MetricsProviders`, thread it through the router and the starters, match the
reserved segment ahead of the by-name live route, answer a structured 404 when no durable
provider is configured, and make store-backed starters serve the route automatically. At the end
a server started with `withMetricsServerWithStore` answers `/subscriptions/checkpoints` while
`/subscriptions` still answers its configured 404, and every pre-existing test passes unchanged
except for the mechanical provider-argument update.

In `kiroku-metrics/src/Kiroku/Metrics/Server.hs` add and export:

```haskell
-- | The optional store-backed data sources a server may serve. Both default to
-- 'Nothing'; the routes they back answer a configured-404 until wired.
data MetricsProviders = MetricsProviders
    { subscriptionStatus :: !(Maybe SubscriptionStatusProvider)
    -- ^ Backs @GET /subscriptions@ (live, process-local registry).
    , checkpointInventory :: !(Maybe CheckpointInventoryProvider)
    -- ^ Backs @GET /subscriptions/checkpoints@ (durable, cross-process inventory).
    }

noProviders :: MetricsProviders
noProviders = MetricsProviders Nothing Nothing

-- | Wire both providers from one store: the common case for a worker that
-- wants live and durable subscription introspection.
storeProviders :: KirokuStore -> MetricsProviders
storeProviders store =
    MetricsProviders
        { subscriptionStatus = Just (storeSubscriptionStatus store)
        , checkpointInventory = Just (storeCheckpointInventory store)
        }
```

Change the fourth parameter of `startMetricsServerWith'`, `combinedApp`, and `httpApp` from
`Maybe SubscriptionStatusProvider` to `MetricsProviders`. In `httpApp` insert the reserved
segment match immediately before the two live matches, and add its handler next to
`subscriptionsRoute`:

```haskell
        ["subscriptions", "checkpoints"] -> checkpointsRoute
        ["subscriptions"] -> subscriptionsRoute
        ["subscriptions", _] -> subscriptionsRoute
  ...
  where
    checkpointsRoute = case providers.checkpointInventory of
        Just provider -> checkpointsApp provider req respond
        Nothing ->
            respond $ jsonResponse status404 $ encode $ errorEnvelope
                "checkpoint_inventory_not_configured"
                "durable checkpoint inventory not configured: start the server from a KirokuStore (startMetricsServerWithStore) or set MetricsProviders.checkpointInventory"
    subscriptionsRoute = case providers.subscriptionStatus of
        ...  -- unchanged body, including its published string error
```

Update the delegating starters so their public behaviour is unchanged except where this plan
adds the route: `startMetricsServer` and `startMetricsServerWith` pass `noProviders`;
`withMetricsServerSubscriptions cfg m deps provider` passes
`noProviders{subscriptionStatus = Just provider}`; `startMetricsServerWithStore cfg m store deps`
passes `noProviders{checkpointInventory = Just (storeCheckpointInventory store)}` together with
the real WebSocket app, so `withMetricsServerWithStore` inherits the route. Update the module
header comment and the Haddocks of the changed functions to describe both providers. Re-export
`MetricsProviders (..)`, `noProviders`, and `storeProviders` through the umbrella module (they
are in `Kiroku.Metrics.Server`, which the umbrella already re-exports wholesale).

No in-repository code outside `Server.hs` calls `startMetricsServerWith'`, `combinedApp`, or
`httpApp` directly (verified at planning time with
`grep -rn "startMetricsServerWith'\|combinedApp\|httpApp" kiroku-metrics --include='*.hs'`,
which finds only a Haddock mention in `Subscriptions.hs`); the existing tests and the example use
`startMetricsServer`, `startMetricsServerWithStore`, `withMetricsServerWithStore`, and
`withMetricsServerSubscriptions`, whose signatures do not change. Re-run the search before
committing in case that has changed, and update any caller it finds.

Add the `### Breaking Changes` bullet to the `## Unreleased` changelog section: the three
functions take `MetricsProviders`; replace `Nothing` with `noProviders` and `Just p` with
`noProviders{subscriptionStatus = Just p}`; store-backed starters now also serve
`/subscriptions/checkpoints`.

Acceptance for Milestone 2: `cabal build kiroku-metrics` and `cabal test kiroku-metrics` pass
(the pre-existing example counts plus the two Milestone 1 examples). Behaviourally, in a
`cabal repl kiroku-metrics` session (or a scratch executable) start
`withMetricsServerWithStore (defaultConfig{port = 9091}) m store []` against any migrated store
and from another shell observe:

```bash
curl -s -i http://localhost:9091/subscriptions/checkpoints | head -1
curl -s http://localhost:9091/subscriptions/checkpoints
curl -s -i http://localhost:9091/subscriptions | head -1
```

```text
HTTP/1.1 200 OK
{"store_position":0,"checkpoints":[]}
HTTP/1.1 404 Not Found
```

There is no `curl` in the Nix dev shell (plan 52 noted this); the same three observations are
made by Milestone 3's tests, which are the authoritative check.

### Milestone 3: end-to-end tests for every acceptance item

Scope: extend `kiroku-metrics/test/Test/CheckpointsSpec.hs` with real-store tests that map
one-to-one onto IR-10's acceptance list. Reuse the helper shapes of
`test/Test/SubscriptionsSpec.hs`: a `get :: Manager -> String -> IO (Int, ByteString)` that does
not throw on non-2xx, an `ev :: Text -> EventData` builder, and a `waitUntilPhase` poll over
`subscriptionStates`. Add a `waitUntilAbsent` poll (same shape, succeeds when the key is missing)
and a `seedCheckpoint :: KirokuStore -> Text -> Int32 -> Int64 -> IO ()` that runs
`SQL.saveCheckpointMemberStmt` through `Pool.use store.pool`, exactly as the store suite does.
Decode durable bodies with `Aeson.eitherDecode` into `CheckpointInventoryResponse` and compare
projected triples `(subscription, member, checkpointPosition)`.

Write these examples, each inside `withMigratedTestDatabase` and `withStore
(defaultConnectionSettings connStr)` unless stated otherwise, each server on `port = 0` with a
short `threadDelay 200_000` after start as the sibling specs do:

1. Durable versus live (acceptance 1). Append three events to one stream; subscribe with
   `defaultSubscriptionConfig (SubscriptionName "durable-vs-live") AllStreams (\_ -> pure Continue)`;
   `waitUntilPhase` for `live`; `cancel handle`, `wait handle`, then `waitUntilAbsent`. Start
   `startMetricsServerWith' (defaultConfig{port = 0}) m [] (storeProviders store) stubWebSocketApp`.
   Assert `GET /subscriptions` is 200 with body `[]`, and `GET /subscriptions/checkpoints` is 200
   with `storePosition == 3` and rows `[("durable-vs-live", 0, 3)]`. The checkpoint equals the
   store position because the worker persists each batch's checkpoint before it publishes the
   `live` transition (plan 69 recorded this ordering); if the persisted value differs, record the
   observed value in Surprises & Discoveries and assert the invariant `checkpointPosition ==
   storePosition` after a clean stop instead.
2. Same-snapshot store position and ordering (acceptance 2). Append twenty events, then seed
   `("zeta", 2, 7)`, `("alpha", 10, 3)`, `("alpha", 2, 5)`. Assert `storePosition == 20` and rows
   in exactly the order `[("alpha", 2, 5), ("alpha", 10, 3), ("zeta", 2, 7)]` (numeric member
   order, not lexical).
3. Two handles over one database (acceptance 3). Open two `withStore` handles over the same
   connection string (two independent registries and pools, the closest in-process model of two
   worker processes). Append events and run a live subscription on handle A only; seed one extra
   row through handle B. Start one server per handle with `storeProviders`. Assert the two
   `GET /subscriptions` bodies differ (A lists the running subscription, B returns `[]`) and the
   two decoded `CheckpointInventoryResponse` values are equal with `shouldBe` (equality includes
   `updatedAt`, so this proves identical rows, not merely identical keys).
4. No status provider (acceptance 4). `withMetricsServerWithStore (defaultConfig{port = 0}) m
   store []`: `GET /subscriptions` is 404 with the published body
   `{"error":"subscription status not configured"}`; `GET /subscriptions/checkpoints` is 200.
5. Empty store (acceptance 5). A fresh migrated database with no appends and no seeds:
   `GET /subscriptions/checkpoints` returns exactly `{"store_position":0,"checkpoints":[]}`.
6. Not configured. `startMetricsServer (defaultConfig{port = 0}) m []`:
   `GET /subscriptions/checkpoints` is 404 and the decoded body's `error.code` is
   `checkpoint_inventory_not_configured`.
7. Provider failure. Mount `checkpointsApp (pure (Left (ConnectionError "simulated outage")))`
   with `Warp.testWithApplication`: the response is 503 and `error.code` is
   `checkpoint_inventory_unavailable`.
8. Existing endpoints unchanged (acceptance 6) is proven by the whole suite: `ServerSpec`,
   `SubscriptionsSpec`, `WebSocketSpec`, `IntegrationSpec`, and `CollectorSpec` keep passing
   with no assertion changes.

Acceptance for Milestone 3: `cabal test kiroku-metrics` is green with the new examples listed
under `Kiroku.Metrics.Checkpoints (/subscriptions/checkpoints)`, and `nix fmt` leaves the tree
unchanged.

### Milestone 4: documentation, example, capability, changelog, and request evidence

Scope: make the endpoint discoverable and its semantics unambiguous, and record implementation
evidence in the bundles that track this work. At the end, a reader of `docs/user/metrics.md` can
wire, call, and interpret the route without reading code, and every repository validation passes.

In `docs/user/metrics.md`: add `/subscriptions/checkpoints` to the deployment-assumption note
(the surface has no authentication; conventions section 8); add a Contents entry "Durable
subscription checkpoints over HTTP"; in "Wiring the collector" and "Starting the server" mention
that store-backed starters serve the durable route automatically and show
`startMetricsServerWith' cfg metrics deps (storeProviders store) wsApp` for a worker that wants
both routes; in "HTTP endpoints" list the new route; and add a new section after "Subscription
status over HTTP" containing: the request and the response transcript from Purpose (copied from a
real test run, with a real timestamp); a field-by-field description (`store_position` is the
authoritative append frontier captured in the same SQL snapshot as the rows; `checkpoint_position`
is the exact persisted position; `updated_at` is the last successful checkpoint write, not proof
of advance; `member` zero is ambiguous between an ungrouped subscription and member zero of a
group); an explicit live-versus-durable explanation (values are exact persisted checkpoints,
stopped subscriptions remain present, a live worker's cursor may be ahead, the answer is
identical from every process, and no status provider is required); the reserved-segment note (a
subscription named `checkpoints` cannot be filtered by name on the live route); the error
vocabulary (`checkpoint_inventory_not_configured` 404, `checkpoint_inventory_unavailable` 503,
`not_found` 404 when mounted standalone) and the statement that this route uses the structured
envelope while older routes keep their string errors; the vocabulary rule that
`store_position - checkpoint_position` is a position distance, not lag, and why it is not an
exact backlog for category, filtered, or grouped consumers; pointers to the Haskell API
(`subscriptions.md#reading-durable-checkpoints`) and the SQL relation
(`schema.md#subscription_checkpoints_v1`); and a one-paragraph stability statement (fields are
never removed or re-typed; additions are optional fields) so a client has something to cite
before IR-13 records the ADR.

In `docs/user/subscriptions.md` "Reading Durable Checkpoints", extend the list of surfaces with
the HTTP route and link to the new section. In `docs/user/operator-cli.md`, where the guide says
the remote client reports live cursors rather than durable checkpoints, add one sentence pointing
at `GET /subscriptions/checkpoints` for the durable view.

Extend `kiroku-metrics/example/Main.hs`: after the health checks, GET
`/subscriptions/checkpoints`, check status 200, decode the body, and check `store_position >= 3`
and an empty `checkpoints` array (the example runs no subscription, so the store has no
checkpoint rows; say so in the step text). Renumber the transcript steps and update the quoted
transcript in the "Try it" section of `docs/user/metrics.md`. The executable is behind the
manual cabal flag `example` (default off, and no project file turns it on: the untracked
`cabal.project.local` only adds a sibling package), so run it as
`cabal run -fexample kiroku-metrics-example` from the repository root inside the dev shell; if
cabal reports the flag as unknown for another local package, use
`cabal run --constraint='kiroku-metrics +example' kiroku-metrics-example` instead and record
which form worked in Surprises & Discoveries.

Update `docs/capabilities/operational-http-endpoints.md` (CAP-17): extend `description` and the
body to name the durable checkpoint inventory endpoint and its cross-process semantics, add
`Kiroku.Metrics.Checkpoints` to `interface`, add an `evidence` entry for
`kiroku-metrics/test/Test/CheckpointsSpec.hs` proving the durable-versus-live and two-handle
behaviour, and add a dated `**Update**: CAP-17 ...` entry to `docs/capabilities/log.md`. Do not
change `generated.at`, `since`, or `capabilityId`. Run `just capabilities-validate`.

Update IR-10's body (status stays `in_progress`): add an "Implementation Evidence" section
naming the module, the route, the response shape, the test file, and the example, mirroring the
completed IR-2 and IR-4 documents; advance `timestamp`; add a log entry; validate.

Finalize the `## Unreleased` changelog section so it is ready to be dated at release: Breaking
Changes (the `MetricsProviders` signature change and the migration hint), New Features (the
route, the module, `storeProviders`, `noProviders`, the error envelope helper), and a note that
`kiroku-store` and `kiroku-cli` bounds are unchanged.

Acceptance for Milestone 4: `nix fmt` is a no-op, `cabal build all`, `cabal test all`, and
`nix build .#kiroku-metrics` succeed, `just capabilities-validate` and the strict
improvement-request validation pass, `git diff --check` is clean, and the example prints its
full passing transcript.

### Milestone 5: release `kiroku-metrics` 0.2.0.0 and complete IR-10

Scope: publish the package so the keiro-ui initiative can consume the route, then close the
request with evidence. Nothing in this milestone may run before the user explicitly confirms the
release in the implementation session.

Follow `agents/skills/release/SKILL.md` for `kiroku-metrics` with bump level `major`. Immediately
before proposing, re-check the authoritative current version on Hackage and the latest
`kiroku-metrics-v*` tag (`git tag --list 'kiroku-metrics-v*' | sort -V | tail -1`; at planning
time it is `kiroku-metrics-v0.1.0.8`); if it moved, recompute the next major from the then-current
version. Explain in the proposal that the exported signature change, not the read-only route,
drives the major bump. The release skill's own ordering governs the version edit, the changelog
dating (`## 0.2.0.0 -- <date>`), `cabal check`, sdist, tests, commit, annotated tag, push,
Hackage upload, documentation upload, and GitHub release. No other package is bumped:
`kiroku-store` did not change, `kiroku-cli` did not change, and nothing in the repository depends
on `kiroku-metrics`.

After the Hackage index refreshes, verify from a clean temporary Cabal project (outside the
working tree) that `kiroku-metrics ==0.2.0.0` resolves and that a small program importing
`Kiroku.Metrics` compiles a call to `storeProviders` and `startMetricsServerWith'`. Record the
Hackage URL, the tag and commit, and the clean-consumer output in this plan.

Only then set IR-10 to `status: completed`, add `completedAt`, refresh `timestamp`, rewrite the
`## Status` paragraph to say which version shipped the route and cite this plan, add a
`**Completion**` log entry, and validate strictly. Do not edit anything in the keiro-ui
repository; the initiative tracks adoption on its own plans and cites the request's completion.

Finally perform the ADR distillation pass required by PLANS.md: reread the Decision Log and
Surprises & Discoveries and decide whether the reserved-segment convention, the providers record,
or the envelope boundary is durable project context. If so, allocate a record with `okf id next
docs/adr --profile docs/adr/profile.dhall ADR`, write it, add the bundle log entry, and run
`just adr-validate`; if not, record in Outcomes why no ADR was needed and note the items IR-13's
future ADR should absorb. Write Outcomes & Retrospective.

Acceptance for Milestone 5: Hackage lists `kiroku-metrics-0.2.0.0`, the tag
`kiroku-metrics-v0.2.0.0` exists upstream with a GitHub release, the clean consumer compiles,
IR-10 is `completed` and the bundle validates, and this plan's Progress shows every item checked.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` inside the Nix dev
shell (`nix develop`, or the direnv-loaded shell from `.envrc`).

Establish a clean baseline first:

```bash
git status --short --branch
cabal build kiroku-metrics
cabal test kiroku-metrics
```

Expected: a clean tree on `master`, and the existing suite passing (fifteen or more examples,
zero failures). If the baseline fails, stop and record it before changing anything.

Milestone 1 edits and checks:

```bash
# edit docs/improvement-requests/serve-durable-subscription-checkpoints-over-http.md  (status: in_progress, timestamp, Status paragraph)
# edit docs/improvement-requests/log.md                                              (dated Implementation entry)
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
# edit kiroku-metrics/src/Kiroku/Metrics/JSON.hs           (+ errorEnvelope)
# write kiroku-metrics/src/Kiroku/Metrics/Checkpoints.hs
# edit kiroku-metrics/src/Kiroku/Metrics.hs                (+ module re-export)
# edit kiroku-metrics/kiroku-metrics.cabal                 (+ exposed module; test other-modules; test deps time, vector)
# write kiroku-metrics/test/Test/CheckpointsSpec.hs        (pure codec + standalone app tests)
# edit kiroku-metrics/test/Main.hs                         (+ CheckpointsSpec.spec)
# edit kiroku-metrics/CHANGELOG.md                         (## Unreleased / ### New Features)
nix fmt
cabal build kiroku-metrics
cabal test kiroku-metrics --test-options='--match Checkpoints'
```

Expected tail of the focused run:

```text
Kiroku.Metrics.Checkpoints (/subscriptions/checkpoints)
  encodes the documented snake_case shape and decodes it back [✔]
  serves the inventory and a structured 404 when mounted standalone [✔]

Finished in 0.4 seconds
2 examples, 0 failures
```

Commit with the plan trailer and the intention trailer:

```text
feat(kiroku-metrics): add the durable checkpoint inventory route module

ExecPlan: docs/plans/87-serve-durable-subscription-checkpoints-over-http.md
Intention: intention_01m24k3bxye7cv6x088hpvs6ne
```

Milestone 2 edits and checks:

```bash
# edit kiroku-metrics/src/Kiroku/Metrics/Server.hs   (MetricsProviders, noProviders, storeProviders; router; starters)
grep -rn "startMetricsServerWith'\|combinedApp\|httpApp" kiroku-metrics --include='*.hs'   # expect no callers outside Server.hs
# edit kiroku-metrics/CHANGELOG.md                     (### Breaking Changes)
nix fmt
cabal build kiroku-metrics
cabal test kiroku-metrics
```

Expected: every pre-existing example plus the two new ones pass. Commit:

```text
feat(kiroku-metrics)!: serve GET /subscriptions/checkpoints from MetricsProviders

BREAKING CHANGE: startMetricsServerWith', combinedApp, and httpApp take a
MetricsProviders record instead of Maybe SubscriptionStatusProvider.

ExecPlan: docs/plans/87-serve-durable-subscription-checkpoints-over-http.md
Intention: intention_01m24k3bxye7cv6x088hpvs6ne
```

Milestone 3 edits and checks:

```bash
# edit kiroku-metrics/test/Test/CheckpointsSpec.hs   (seven real-store examples)
nix fmt
cabal test kiroku-metrics --test-options='--match Checkpoints'
cabal test kiroku-metrics
```

Expected focused tail:

```text
Kiroku.Metrics.Checkpoints (/subscriptions/checkpoints)
  encodes the documented snake_case shape and decodes it back [✔]
  serves the inventory and a structured 404 when mounted standalone [✔]
  keeps a stopped subscription in the durable inventory after it leaves the live registry [✔]
  captures the same-snapshot store position and orders rows by name then numeric member [✔]
  returns the same durable inventory from two store handles over one database [✔]
  serves the durable inventory when no live status provider is wired [✔]
  returns position zero and no rows for an empty store [✔]
  answers a structured 404 when no checkpoint provider is configured [✔]
  answers a structured 503 when the provider fails [✔]

9 examples, 0 failures
```

Commit as `test(kiroku-metrics): cover the durable checkpoint route end to end` with both
trailers.

Milestone 4 edits and checks:

```bash
# edit docs/user/metrics.md, docs/user/subscriptions.md, docs/user/operator-cli.md
# edit kiroku-metrics/example/Main.hs
# edit docs/capabilities/operational-http-endpoints.md, docs/capabilities/log.md
# edit docs/improvement-requests/serve-durable-subscription-checkpoints-over-http.md, docs/improvement-requests/log.md
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

Expected example transcript (port varies):

```text
[1/7] ephemeral postgres ready
[2/7] store + collector + metrics server on port 57277
[3/7] appended 3 events to orders-1
[4/7] HTTP /metrics, /prometheus, /health/live, /health/ready all OK
[5/7] GET /subscriptions/checkpoints store_position=3 with no durable checkpoints (this example runs no subscription)
[6/7] WebSocket /ws/events received event eventType=OrderRefunded
[7/7] kiroku-metrics-example: all checks passed (snapshot global position = 4)
```

Commit as `docs(kiroku-metrics): document durable subscription checkpoints over HTTP` with both
trailers (one commit for docs and example, one for the bundles is also fine).

Milestone 5, only after explicit confirmation:

```bash
git tag --list 'kiroku-metrics-v*' | sort -V | tail -1
# follow agents/skills/release/SKILL.md for kiroku-metrics major
```

Then the clean-consumer check in a scratch directory outside the repository (for example under
the session scratchpad):

```bash
mkdir -p "$SCRATCH/metrics-consumer" && cd "$SCRATCH/metrics-consumer"
cabal update
# write a one-module executable importing Kiroku.Metrics and referencing storeProviders
# with `build-depends: base, kiroku-metrics ==0.2.0.0, kiroku-store` in its .cabal
cabal build
```

Expected: the solver downloads `kiroku-metrics-0.2.0.0` from Hackage and the build succeeds.
Return to the repository, complete IR-10, validate the bundle, run `just adr-validate` if an
ADR was added, and commit as `docs(improvement-requests): complete IR-10` with both trailers.


## Validation and Acceptance

The plan is accepted when all of the following are observable:

1. With one subscription checkpointed and its worker stopped, `GET /subscriptions/checkpoints`
   returns HTTP 200 with that subscription's row while `GET /subscriptions` returns `[]`
   (test 1 in Milestone 3; IR-10 acceptance 1).
2. The body carries `store_position` from the same snapshot as the rows, and rows are in
   ascending `(subscription, member)` order with numeric member ordering (test 2; acceptance 2).
3. Two store handles over one database return equal durable bodies while their live bodies
   differ (test 3; acceptance 3).
4. A server started with `withMetricsServerWithStore` and no status provider answers the durable
   route with 200 and the live route with the published 404 string body (test 4; acceptance 4).
5. An empty store returns `{"store_position":0,"checkpoints":[]}` (test 5; acceptance 5).
6. Every pre-existing endpoint, WebSocket frame, and JSON body is unchanged: the existing specs
   pass without assertion edits, and `git diff` shows no change under
   `kiroku-metrics/src/Kiroku/Metrics/{Subscriptions,WebSocket,Prometheus,Health,Types,Collector,Config}.hs`
   (acceptance 6).
7. A server with no durable provider answers 404 with the structured envelope code
   `checkpoint_inventory_not_configured`, and a failing provider answers 503 with
   `checkpoint_inventory_unavailable` (tests 6 and 7).
8. `docs/user/metrics.md` contains the request/response transcript, the live-versus-durable
   explanation, the error vocabulary, and the position-distance wording; CAP-17 and IR-10 are
   updated and their bundles validate; the example prints the seven-step transcript.
9. `kiroku-metrics` 0.2.0.0 is on Hackage with its tag and GitHub release, a clean consumer
   compiles against it, and IR-10 is `completed`.


## Idempotence and Recovery

All source and documentation edits are additive or mechanical and can be re-applied; `nix fmt`,
`cabal build`, `cabal test`, `okf validate`, and the example are safe to rerun. The endpoint is
read-only: it never writes to the store, the registry, or the database, so repeating a request or
a test is always safe. Tests use a fresh migrated database per example and OS-assigned ports, so
reruns cannot collide. If a test seeds checkpoint rows with `saveCheckpointMemberStmt`, the
statement is an upsert with `GREATEST`, so a repeated seed cannot move a row backwards.

The IR and capability bundle edits are validated by strict profile checks; if validation fails
after an edit, the message names the offending field (typically a `timestamp` that did not
advance or a missing dated log entry) and the fix is local. Keep `status: in_progress` until the
release evidence exists; never set `completed` on the strength of a local build.

Publishing is not idempotent. Before retrying a partially failed release, inspect Hackage, local
and upstream tags, and `git status` to see which step succeeded, and follow the release skill's
recovery guidance; never reuse a version for different contents or move a pushed tag (plan 69
recorded the `kiroku-metrics-v0.1.0.2` incident that established this rule). If the release is
declined or deferred, Milestones 1 to 4 remain complete and valid on `master`, the changelog
section stays `## Unreleased`, and IR-10 stays `in_progress` with its evidence.


## Interfaces and Dependencies

At the end of Milestone 1, `kiroku-metrics` exposes:

```haskell
-- Kiroku.Metrics.JSON (addition)
errorEnvelope :: Text -> Text -> Data.Aeson.Value

-- Kiroku.Metrics.Checkpoints (new module)
type CheckpointInventoryProvider = IO (Either StoreError SubscriptionCheckpointInventory)
storeCheckpointInventory :: KirokuStore -> CheckpointInventoryProvider

data CheckpointRow = CheckpointRow
    { subscription :: !Text, member :: !Int32, checkpointPosition :: !Int64, updatedAt :: !UTCTime }
data CheckpointInventoryResponse = CheckpointInventoryResponse
    { storePosition :: !Int64, checkpoints :: ![CheckpointRow] }
-- ToJSON/FromJSON for both, keys: store_position, checkpoints, subscription, member,
-- checkpoint_position, updated_at

checkpointInventoryResponse :: SubscriptionCheckpointInventory -> CheckpointInventoryResponse
checkpointsPath :: [Text]              -- ["subscriptions", "checkpoints"]
checkpointsApp :: CheckpointInventoryProvider -> Network.Wai.Application
```

At the end of Milestone 2, `Kiroku.Metrics.Server` exposes (changed signatures marked):

```haskell
data MetricsProviders = MetricsProviders
    { subscriptionStatus :: !(Maybe SubscriptionStatusProvider)
    , checkpointInventory :: !(Maybe CheckpointInventoryProvider)
    }
noProviders :: MetricsProviders
storeProviders :: KirokuStore -> MetricsProviders

startMetricsServerWith' ::                      -- changed: MetricsProviders
    MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> MetricsProviders -> WS.ServerApp -> IO MetricsServer
combinedApp ::                                  -- changed: MetricsProviders
    MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> MetricsProviders -> WS.ServerApp -> Application
httpApp ::                                      -- changed: MetricsProviders
    MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> MetricsProviders -> Application

-- unchanged signatures, behaviour noted:
startMetricsServer          -- noProviders
startMetricsServerWith      -- noProviders
startMetricsServerWithStore -- durable provider wired from the store; live provider not wired
withMetricsServer, withMetricsServerWithStore, withMetricsServerSubscriptions, stopMetricsServer
```

Wire contract owned by this plan (frozen once released):

```json
{
  "store_position": 42,
  "checkpoints": [
    { "subscription": "inventory-projection", "member": 0, "checkpoint_position": 40, "updated_at": "2026-09-10T02:41:07.512339Z" }
  ]
}
```

Error bodies on this route: `404 {"error":{"code":"checkpoint_inventory_not_configured","message":"..."}}`,
`503 {"error":{"code":"checkpoint_inventory_unavailable","message":"..."}}`, and, standalone
only, `404 {"error":{"code":"not_found","message":"Not found"}}`.

Dependencies: no new library dependency. The library already depends on `aeson`, `text`, `time`,
`vector`, `wai`, `http-types`, `kiroku-store ^>=0.8`, and `kiroku-cli ^>=0.2`; the test suite
gains `time` and `vector`. `kiroku-store` and `kiroku-cli` are unchanged and unreleased by this
plan. The only runtime service is PostgreSQL with the existing Kiroku migrations. Locate
dependency sources through `mori registry show <project> --full` (for example `hasql/hasql`,
`yesodweb/wai`, `haskell/aeson`) when behaviour is uncertain; do not inspect `/nix/store`.

Dependency direction is unchanged: `kiroku-metrics` depends on `kiroku-cli` and `kiroku-store`;
nothing depends on `kiroku-metrics`.


## Revision Notes

- 2026-09-10: Linked IR-10 to this plan in the same session the plan was created. The request's
  frontmatter now reads `status: accepted` with its Status section citing this plan, the
  improvement-request bundle log records the acceptance, and Milestone 1, Context and
  Orientation, and the status-lifecycle decision were reworded so the plan starts from
  `accepted` rather than `proposed`. No implementation scope changed.
