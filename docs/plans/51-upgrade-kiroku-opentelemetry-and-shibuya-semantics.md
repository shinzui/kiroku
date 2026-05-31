---
id: 51
slug: upgrade-kiroku-opentelemetry-and-shibuya-semantics
title: "Upgrade Kiroku OpenTelemetry and Shibuya semantics"
kind: exec-plan
created_at: 2026-05-31T23:10:39Z
intention: "intention_01kt04pxy7erqtzywqq7d83w4g"
---

# Upgrade Kiroku OpenTelemetry and Shibuya semantics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku currently carries trace context and emits subscription lifecycle spans through `kiroku-otel`, but that package still depends on the pre-1.0 `hs-opentelemetry-api` and W3C propagator packages. The Shibuya adapter also declares `shibuya-core >=0.5 && <0.6`, while the registered Shibuya source is now `shibuya-core-0.6.0.0` and already uses `hs-opentelemetry-api ^>=1.0`, `hs-opentelemetry-propagator-w3c ^>=1.0`, and generated semantic-convention keys from `hs-opentelemetry-semantic-conventions ^>=1.40`.

After this change, `kiroku-otel` and `shibuya-kiroku-adapter` build together against the same OpenTelemetry 1.0 ecosystem and the latest Shibuya API. A user can see the result by running the Kiroku OTel and Shibuya adapter test suites: trace context still round-trips through Kiroku event metadata, subscription spans still export with the expected attributes, and Shibuya process spans receive Kiroku event attributes using current OpenTelemetry messaging semantic-convention names rather than stale handwritten strings.


## Progress

- [x] Research the current Kiroku package layout, dependency registry entries, `kiroku-otel` modules, Shibuya adapter modules, and the registered dependency sources with `mori`. Completed 2026-05-31T23:10:00Z.
- [x] Confirm that the new plan is associated with `intention_01kt04pxy7erqtzywqq7d83w4g`. Completed 2026-05-31T23:10:39Z.
- [x] Confirm the exact latest usable `shibuya-core` source for Kiroku, preferring Hackage if `0.6.0.0` is published and otherwise pinning the registered source commit `1b86540beae8c483a302cc121032504dce8a3601`. Completed 2026-05-31T23:32:00Z.
- [x] Update Cabal and Nix dependency declarations so `kiroku-otel`, `shibuya-kiroku-adapter`, and the Shibuya overhead benchmark resolve against OpenTelemetry 1.0 and Shibuya 0.6. Completed 2026-05-31T23:45:00Z.
- [x] Migrate `kiroku-otel` source and tests to the OpenTelemetry 1.0 API shape. Completed 2026-05-31T23:55:00Z.
- [x] Replace Kiroku-owned span and envelope semantic keys with generated `OpenTelemetry.SemanticConventions` keys where a current standard key exists, keeping `kiroku.*` only for domain-specific concepts. Completed 2026-05-31T23:55:00Z.
- [x] Update user documentation and changelogs to describe the new dependency versions and semantic-convention behavior. Completed 2026-05-31T23:59:00Z.
- [x] Run focused and full validation, then record outcomes here. Completed 2026-06-01T00:31:00Z.


## Surprises & Discoveries

- Discovery: `mori show --full` reports this repository as `shinzui/kiroku` with packages `kiroku-store`, `shibuya-kiroku-adapter`, and `kiroku-otel`, and dependencies including `iand675/hs-opentelemetry` and `shinzui/shibuya`.
  Evidence: `mori show --full` listed `kiroku-otel` as "OpenTelemetry W3C trace-context helpers for Kiroku event metadata" and `shibuya-kiroku-adapter` as "Shibuya adapter for Kiroku event store subscriptions."
  Date: 2026-05-31

- Discovery: The registered Shibuya source is already on the OpenTelemetry 1.0 ecosystem.
  Evidence: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/shibuya-core.cabal` declares version `0.6.0.0` and dependencies `hs-opentelemetry-api ^>=1.0`, `hs-opentelemetry-propagator-w3c ^>=1.0`, and `hs-opentelemetry-semantic-conventions ^>=1.40`.
  Date: 2026-05-31

- Discovery: `kiroku-otel` is still on pre-1.0 OpenTelemetry bounds.
  Evidence: `kiroku-otel/kiroku-otel.cabal` declares `hs-opentelemetry-api >=0.3 && <0.4` and `hs-opentelemetry-propagator-w3c >=0.1 && <0.2`, while its test suite depends on unbounded `hs-opentelemetry-api`, `hs-opentelemetry-exporter-in-memory`, and `hs-opentelemetry-sdk`.
  Date: 2026-05-31

- Discovery: The upstream OpenTelemetry semantic-conventions documentation is currently newer than the local Haskell generated package.
  Evidence: the official OpenTelemetry site labels the docs as "Semantic conventions 1.41.0"; the local `hs-opentelemetry-semantic-conventions.cabal` in the registered hs-opentelemetry corpus is version `1.40.0.0` and its generated module says it is based on semantic-conventions v1.40.
  Date: 2026-05-31

- Discovery: Hackage has all target versions needed for this migration.
  Evidence: `cabal list` reported `hs-opentelemetry-api 1.0.0.0`, `hs-opentelemetry-propagator-w3c 1.0.0.0`, `hs-opentelemetry-sdk 1.0.0.0`, `hs-opentelemetry-exporter-in-memory 1.0.0.0`, `hs-opentelemetry-semantic-conventions 1.40.0.0`, and `shibuya-core 0.6.0.0`.
  Date: 2026-05-31

- Discovery: OpenTelemetry 1.0's exported `ImmutableSpan` no longer exposes pure `spanName`, `spanAttributes`, or `spanEvents` selectors.
  Evidence: `cabal build kiroku-otel` failed with "Variable not in scope: spanName", "spanAttributes", and "spanEvents". The local 1.0 source shows `ImmutableSpan` now stores mutable span fields in `spanHot :: IORef SpanHot`, whose `hotName`, `hotAttributes`, and `hotEvents` fields hold the ended span details.
  Date: 2026-05-31

- Discovery: Running two Cabal builds against the same workspace in parallel can corrupt the in-place build step.
  Evidence: the parallel `cabal build shibuya-kiroku-adapter` run failed with `ghc-pkg-9.12.2: cannot create ... package.conf.inplace already exists` while `cabal build kiroku-otel` was configuring the same local dependency. Rerunning serially avoided the conflict.
  Date: 2026-05-31

- Discovery: The Nix package set resolved older OpenTelemetry packages until explicit overrides were added.
  Evidence: `nix build .#shibuya-kiroku-adapter` initially failed with missing generated semantic-convention identifiers such as `Sem.messaging_operation_type` and with `Ctx.detachContext` type mismatches. Overriding `hs-opentelemetry-api`, `hs-opentelemetry-propagator-w3c`, `hs-opentelemetry-semantic-conventions`, and their required support packages fixed the Nix build.
  Date: 2026-05-31

- Discovery: `hs-opentelemetry-api-1.0.0.0` requires `thread-utils-context-0.4.1.0` in this Nix environment.
  Evidence: the Nix build failed with missing `ensureRef`, `ensureRefFast`, and `lookupRefFast` identifiers until `thread-utils-context` was also overridden.
  Date: 2026-05-31

- Discovery: `callHackageDirect` hashes are the hashes Nix reports for the fetched Hackage source, not the raw tarball hashes produced by a manual prefetch.
  Evidence: the initial overlay hashes for OpenTelemetry packages were rejected by Nix, and the build succeeded after replacing them with the hashes in Nix's "got" output.
  Date: 2026-05-31

- Discovery: The real `$all` OpenTelemetry test could append live events before the subscription had fully crossed into live mode.
  Evidence: after the OpenTelemetry 1.0 test refactor, `cabal test kiroku-otel` intermittently observed no live deliver span even though catch-up delivery succeeded. Waiting for `KirokuEventSubscriptionCaughtUp` before appending live events made the test deterministic.
  Date: 2026-05-31


## Decision Log

- Decision: Treat this as a coordinated dependency and telemetry-semantic migration, not only a Cabal bound bump.
  Rationale: `kiroku-otel` directly imports OpenTelemetry API and propagator modules, builds a real `TracerProvider` in tests, and exports attribute constants. A pure dependency bump could compile after local tweaks while leaving stale attribute names or untested propagation behavior.
  Date: 2026-05-31

- Decision: Target OpenTelemetry 1.0 package bounds for every direct Kiroku OpenTelemetry dependency.
  Rationale: The user explicitly asked for `hs-opentelemetry 1.0` and current Shibuya 0.6 already depends on the 1.0 ecosystem. Keeping Kiroku on `>=0.3 && <0.4` would force an impossible shared dependency set once the adapter moves to Shibuya 0.6.
  Date: 2026-05-31

- Decision: Target `shibuya-core >=0.6 && <0.7` for `shibuya-kiroku-adapter` and the `kiroku-shibuya-overhead` benchmark.
  Rationale: The registered `shinzui/shibuya` source is version `0.6.0.0` and is the first observed Shibuya version already aligned to `hs-opentelemetry-api ^>=1.0` and current messaging semantic-convention keys. The bound should be narrow so a future Shibuya 0.7 API change requires deliberate review.
  Date: 2026-05-31

- Decision: Use generated `OpenTelemetry.SemanticConventions` keys for standard attributes instead of hand-typed standard strings.
  Rationale: Shibuya 0.6 uses `AttributeKey` values from `hs-opentelemetry-semantic-conventions`; when upstream renames keys, compilation fails instead of silently emitting stale wire names. Kiroku should use the same pattern for standard messaging and database attributes.
  Date: 2026-05-31

- Decision: Keep `kiroku.*` attributes only for Kiroku-specific concepts that have no current OpenTelemetry standard key.
  Rationale: OpenTelemetry semantic conventions standardize common cross-system fields such as `messaging.operation.type`, `messaging.destination.name`, `messaging.message.id`, `messaging.consumer.group.name`, `messaging.batch.message_count`, `db.system.name`, `db.namespace`, and `db.operation.name`. Kiroku-specific fields such as `kiroku.subscription.name`, `kiroku.subscription.state`, `kiroku.checkpoint.global_position`, and `kiroku.dead_letter.reason` describe event-store concepts that are not generic OpenTelemetry attributes.
  Date: 2026-05-31

- Decision: Use Hackage packages for OpenTelemetry 1.0 and Shibuya 0.6 instead of source-repository pins.
  Rationale: Hackage now publishes all required target versions, including `shibuya-core-0.6.0.0`; keeping source pins would preserve old workaround complexity without improving reproducibility for this workspace.
  Date: 2026-05-31

- Decision: Add standard attributes alongside, not instead of, existing `kiroku.*` attributes.
  Rationale: The `kiroku.*` names are part of the existing package's documented observability surface. Adding standard `messaging.*` and `db.*` keys gives current OpenTelemetry backend compatibility without breaking downstream users already querying `kiroku.batch.rows`, `kiroku.subscription.name`, or related fields.
  Date: 2026-05-31

- Decision: Keep the Nix overlay on Hackage releases rather than source pins, but override the exact OpenTelemetry 1.0 package family required by this workspace.
  Rationale: Cabal can solve the published versions directly, while the existing Nix package set lagged behind the new semantic-conventions API. Small `callHackageDirect` overrides preserve the repository's current overlay style and avoid reintroducing git pins for packages that are already published.
  Date: 2026-05-31

- Decision: Synchronize the real `$all` subscription test on `KirokuEventSubscriptionCaughtUp` before appending live events.
  Rationale: The test is intended to validate live-delivery tracing, not race the transition from catch-up to live mode. Waiting on the emitted observability event keeps the test tied to the worker's actual state machine.
  Date: 2026-05-31


## Outcomes & Retrospective

The migration is complete. `kiroku-otel` now depends on `hs-opentelemetry-api ^>=1.0`, `hs-opentelemetry-propagator-w3c ^>=1.0`, and `hs-opentelemetry-semantic-conventions ^>=1.40`; its tests use the 1.0 SDK and in-memory exporter. `shibuya-kiroku-adapter` and the Shibuya overhead benchmark now target `shibuya-core >=0.6 && <0.7`. Hackage provides the target package versions, so the old hs-opentelemetry source pins were removed from `cabal.project`; Nix uses matching Hackage overrides for Shibuya 0.6 and the OpenTelemetry 1.0 package family.

The implementation now emits generated semantic-convention keys for standard messaging and database attributes. Subscription spans include `messaging.system`, `messaging.destination.name`, `messaging.operation.type`, and `messaging.batch.message_count` where applicable, while database error spans include `db.system.name` and `db.operation.name`. Shibuya envelopes now include the standard Kiroku messaging identity attributes alongside the existing `kiroku.*` attributes. Existing Kiroku-specific keys remain in place for compatibility and for concepts that OpenTelemetry does not standardize.

Validation completed on 2026-05-31:

- `nix fmt`: passed.
- `cabal test kiroku-otel`: passed, 17 examples and 0 failures.
- `cabal test shibuya-kiroku-adapter`: passed, 20 examples and 0 failures.
- `cabal build all`: passed after rerunning serially to avoid a concurrent Cabal `package.conf.inplace` collision.
- `nix build .#shibuya-kiroku-adapter`: passed.

The only semantic-convention compromise is version freshness: the current published Haskell generated package is `hs-opentelemetry-semantic-conventions-1.40.0.0`, while the official OpenTelemetry documentation is already at semantic conventions 1.41.0. The code uses generated v1.40 keys so that future key drift is caught by compilation and tests rather than hidden in handwritten strings.


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. It is a Haskell Cabal workspace using GHC 9.12.2. The root `cabal.project` currently includes local packages `kiroku-store`, `kiroku-store-migrations`, `kiroku-test-support`, `shibuya-kiroku-adapter`, `kiroku-otel`, `kiroku-jitsurei`, and `kiroku-cli`.

`kiroku-store` is the core event store package. It deliberately does not depend on `hs-opentelemetry`; it exposes operational events through `Kiroku.Store.Observability.KirokuEvent` and subscription streams through `Kiroku.Store.Subscription.Stream`.

`kiroku-otel` is the optional observability package in `kiroku-otel/`. Its public modules are `Kiroku.Otel.TraceContext` and `Kiroku.Otel.Subscription`. `Kiroku.Otel.TraceContext` writes W3C `traceparent` and `tracestate` strings into the JSON `metadata` field of `Kiroku.Store.Types.EventData`, then reads them back from `Kiroku.Store.Types.RecordedEvent`. `Kiroku.Otel.Subscription` converts Kiroku subscription worker events into OpenTelemetry spans using `OpenTelemetry.Trace.Core.Tracer`.

`shibuya-kiroku-adapter` is the Shibuya integration package in `shibuya-kiroku-adapter/`. `Shibuya.Adapter.Kiroku` starts an ack-coupled Kiroku subscription and exposes it as a Shibuya `Adapter es RecordedEvent`. `Shibuya.Adapter.Kiroku.Convert` converts each `RecordedEvent` into a Shibuya `Envelope`; this is where trace headers and Kiroku event attributes are attached to the Shibuya process span.

The local dependency registry is authoritative for source lookup. Running `mori registry show iand675/hs-opentelemetry --full` points to `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`. The packages relevant to this plan are `hs-opentelemetry-api`, `hs-opentelemetry-propagator-w3c`, `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-in-memory`, and `hs-opentelemetry-semantic-conventions`.

The OpenTelemetry 1.0 W3C propagator still exports `decodeSpanContext :: Maybe ByteString -> Maybe ByteString -> Maybe SpanContext`, but `encodeSpanContext` now takes a `Span`, not a bare `SpanContext`: `encodeSpanContext :: Span -> IO (ByteString, ByteString)`. To encode an existing `SpanContext`, call `OpenTelemetry.Trace.Core.wrapSpanContext` first. This is the same conceptual pattern already used in `kiroku-otel/src/Kiroku/Otel/TraceContext.hs`, but it must be revalidated against the 1.0 package.

The registered Shibuya source is `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, commit `1b86540beae8c483a302cc121032504dce8a3601`, with `shibuya-core/shibuya-core.cabal` version `0.6.0.0`. Its telemetry modules are important examples for this migration: `Shibuya.Telemetry.Semantic` obtains standard attribute key strings with `OpenTelemetry.Attributes.AttributeKey (unkey)` and `OpenTelemetry.SemanticConventions`, and `Shibuya.Runner.Supervised.processOne` emits a Consumer span with `messaging.system`, `messaging.destination.name`, `messaging.operation.type`, and `messaging.message.id`.

The official OpenTelemetry semantic-conventions documentation says database spans are stable and require `db.system.name`; it also documents the migration from old `db.system` to `db.system.name`. Messaging spans use operation type `process` with span kind `CONSUMER`. The registered local Haskell semantic-conventions package is generated from semantic-conventions v1.40. The official site is already at v1.41.0, so implementation must prefer generated keys present locally and include tests that make future generated-key drift visible.


## Plan of Work

Milestone 1 confirms dependency targets. The implementer checks Hackage and the local registry for `shibuya-core`, `hs-opentelemetry-api`, `hs-opentelemetry-propagator-w3c`, `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-in-memory`, and `hs-opentelemetry-semantic-conventions`. At the end of the milestone, the plan records whether `shibuya-core-0.6.0.0` is available from Hackage. If it is available, Cabal and Nix should use Hackage. If it is not yet available, Cabal should use a pinned `source-repository-package` for `shibuya-core` at commit `1b86540beae8c483a302cc121032504dce8a3601`, and Nix should use the same commit with the existing Cabal-version patching pattern if needed. Acceptance is a recorded target source for Shibuya 0.6 and OpenTelemetry 1.0.

Milestone 2 updates package dependencies. Edit `cabal.project`, `kiroku-otel/kiroku-otel.cabal`, `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`, and `kiroku-store/kiroku-store.cabal`. `kiroku-otel` must depend on `hs-opentelemetry-api ^>=1.0`, `hs-opentelemetry-propagator-w3c ^>=1.0`, and `hs-opentelemetry-semantic-conventions ^>=1.40`; its tests must use `hs-opentelemetry-sdk ^>=1.0` and `hs-opentelemetry-exporter-in-memory ^>=1.0`. `shibuya-kiroku-adapter` and the benchmark must depend on `shibuya-core >=0.6 && <0.7` and `hs-opentelemetry-api ^>=1.0`. Acceptance is that `cabal build kiroku-otel shibuya-kiroku-adapter` starts solving the intended versions instead of selecting OpenTelemetry 0.3 or Shibuya 0.5.

Milestone 3 migrates `kiroku-otel` source. Update imports and any changed API calls in `kiroku-otel/src/Kiroku/Otel/TraceContext.hs` and `kiroku-otel/src/Kiroku/Otel/Subscription.hs`. Preserve the public API unless OpenTelemetry 1.0 makes that impossible: `injectTraceContext :: SpanContext -> EventData -> EventData`, `extractTraceContext :: RecordedEvent -> Maybe SpanContext`, and `subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())` should remain. Acceptance is that the package compiles and the trace-context tests still prove `traceparent` and `tracestate` round-trip.

Milestone 4 aligns telemetry semantics. Add a small internal helper module or local helper functions in `Kiroku.Otel.Subscription` and `Shibuya.Adapter.Kiroku.Convert` that obtain standard attribute names through `OpenTelemetry.SemanticConventions` and `AttributeKey.unkey`. Use standard keys where they fit: `messaging.system = "kiroku"` for Kiroku subscription delivery spans, `messaging.operation.type = "process"` for per-batch or per-message processing, `messaging.destination.name` for subscription target or processor destination, `messaging.consumer.group.name` when a consumer group is present, `messaging.batch.message_count` for delivered batch size, `messaging.message.id` for event id on Shibuya envelopes, and `db.system.name = "postgresql"` plus `db.operation.name` or `db.namespace` only for spans that truly represent database calls. Keep existing `kiroku.*` keys for Kiroku-only state and checkpoint information. Acceptance is that tests assert the emitted wire keys through exported constants or span attributes and fail if a standard key regresses to an old spelling such as `messaging.operation` or `db.system`.

Milestone 5 updates tests. Extend `kiroku-otel/test/Main.hs` so the subscription span tests check the standard semantic-convention attributes on at least one deliver span and one database-error span. Extend `shibuya-kiroku-adapter/test/Main.hs` so `toEnvelope` asserts standard Shibuya process-span attributes are supplied using current names where the adapter is responsible for them, and keep assertions for Kiroku-specific attributes. If Shibuya 0.6 changed `Envelope`, `Adapter`, `runApp`, `ProcessorId`, or tracing APIs, adjust the tests and adapter source to the actual 0.6 types read from the sibling source. Acceptance is that both test suites pass.

Milestone 6 updates docs and release notes. Edit `docs/user/opentelemetry.md` to replace the old dependency section with OpenTelemetry 1.0 bounds and explain which attributes are standard OpenTelemetry keys versus Kiroku-specific keys. Edit `docs/user/shibuya-adapter.md` if it names Shibuya versions or attribute keys. Add concise changelog entries to `kiroku-otel/CHANGELOG.md` and `shibuya-kiroku-adapter/CHANGELOG.md`. Acceptance is that docs no longer mention `hs-opentelemetry-api >=0.3 && <0.4` or `hs-opentelemetry-propagator-w3c >=0.1 && <0.2`.

Milestone 7 validates the workspace. Run focused tests first, then the broader build. Acceptance is that `kiroku-otel-test` and `shibuya-kiroku-adapter-test` pass, `cabal build all` succeeds, and the Nix target for the adapter still builds or the plan records the exact Nix blocker and the retry path.


## Concrete Steps

Run all commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

Confirm project and dependency metadata:

```bash
mori show --full
mori registry show iand675/hs-opentelemetry --full
mori registry docs iand675/hs-opentelemetry
mori registry show shinzui/shibuya --full
```

Expected evidence includes the local hs-opentelemetry corpus at `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project` and the local Shibuya repository at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

Confirm the latest published packages before editing dependency sources:

```bash
cabal list hs-opentelemetry-api --simple-output
cabal list hs-opentelemetry-propagator-w3c --simple-output
cabal list hs-opentelemetry-sdk --simple-output
cabal list hs-opentelemetry-exporter-in-memory --simple-output
cabal list hs-opentelemetry-semantic-conventions --simple-output
cabal list shibuya-core --simple-output
```

If `cabal list shibuya-core --simple-output` does not include `shibuya-core 0.6.0.0`, use the registered source commit for this plan:

```bash
git -C /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya rev-parse HEAD
```

Expected output at plan creation time:

```text
1b86540beae8c483a302cc121032504dce8a3601
```

Inspect the OpenTelemetry 1.0 APIs before changing source:

```bash
rg -n "decodeSpanContext|encodeSpanContext|wrapSpanContext|SpanContext" \
  /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/api \
  /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/propagators/w3c \
  -g '*.hs'
rg -n "messaging_operation_type|messaging_batch_messageCount|db_system_name|db_operation_name|db_namespace" \
  /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs
```

Edit `cabal.project`. Replace the existing hs-opentelemetry `source-repository-package` blocks pinned to `adc464b0a45e56a983fa1441be6e432b50c29e0e` with blocks only if Hackage cannot provide OpenTelemetry 1.0 under GHC 9.12.2. If blocks are needed, include all direct packages used by Kiroku from the same commit or tag: `api`, `propagators/w3c`, `sdk`, `exporters/in-memory`, and `semantic-conventions`. If `shibuya-core-0.6.0.0` is not on Hackage, add:

```cabal
source-repository-package
  type: git
  location: https://github.com/shinzui/shibuya
  tag: 1b86540beae8c483a302cc121032504dce8a3601
  subdir: shibuya-core
```

Edit `kiroku-otel/kiroku-otel.cabal`. The library dependency block should include:

```cabal
, hs-opentelemetry-api                   ^>=1.0
, hs-opentelemetry-propagator-w3c        ^>=1.0
, hs-opentelemetry-semantic-conventions  ^>=1.40
```

The test-suite dependency block should include:

```cabal
, hs-opentelemetry-api
, hs-opentelemetry-exporter-in-memory  ^>=1.0
, hs-opentelemetry-sdk                 ^>=1.0
```

Edit `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`. In both library and test-suite dependencies, use:

```cabal
, hs-opentelemetry-api  ^>=1.0
, shibuya-core          >=0.6 && <0.7
```

Edit the `kiroku-shibuya-overhead` benchmark dependencies in `kiroku-store/kiroku-store.cabal` so `shibuya-core` is also:

```cabal
, shibuya-core          >=0.6 && <0.7
```

Migrate `kiroku-otel/src/Kiroku/Otel/TraceContext.hs`. Keep `injectTraceContext` pure if the OpenTelemetry 1.0 encoder remains observably pure for `wrapSpanContext`, but update the comment to cite the 1.0 type:

```haskell
encodeSpanContext :: Span -> IO (ByteString, ByteString)
```

Migrate `kiroku-otel/src/Kiroku/Otel/Subscription.hs`. Add imports similar to:

```haskell
import OpenTelemetry.Attributes (Attribute, AttributeKey (..), ToAttribute (toAttribute))
import OpenTelemetry.SemanticConventions qualified as Sem
```

For standard keys, define constants by unwrapping generated keys:

```haskell
attrMessagingSystem :: Text
attrMessagingSystem = unkey Sem.messaging_system

attrMessagingOperationType :: Text
attrMessagingOperationType = unkey Sem.messaging_operation_type

attrMessagingBatchMessageCount :: Text
attrMessagingBatchMessageCount = unkey Sem.messaging_batch_messageCount
```

Do not remove the existing Kiroku-specific exported constants unless the implementation deliberately makes a breaking API change and records that decision. Prefer adding standard constants and keeping aliases for compatibility.

After source edits, run focused builds:

```bash
cabal build kiroku-otel
cabal build shibuya-kiroku-adapter
```

Then run focused tests:

```bash
cabal test kiroku-otel
cabal test shibuya-kiroku-adapter
```

Run broader validation:

```bash
cabal build all
nix build .#shibuya-kiroku-adapter
```

If formatting changes are required, run the repository formatter:

```bash
nix fmt
```

Every implementation commit made under this plan must use a Conventional Commit message and include both trailers:

```text
ExecPlan: docs/plans/51-upgrade-kiroku-opentelemetry-and-shibuya-semantics.md
Intention: intention_01kt04pxy7erqtzywqq7d83w4g
```


## Validation and Acceptance

The migration is accepted when the following commands succeed from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`:

```bash
cabal build kiroku-otel
cabal test kiroku-otel
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter
cabal build all
```

`kiroku-otel-test` must still prove that a constructed `SpanContext` round-trips through `EventData.metadata` and `RecordedEvent.metadata`: the extracted `traceId`, `spanId`, and `traceFlags` must equal the injected values. It must also prove that subscription spans export with Kiroku-specific attributes and current standard attributes.

`shibuya-kiroku-adapter-test` must still prove that `toEnvelope` copies string `traceparent` and `tracestate` metadata into Shibuya `traceContext`, rejects absent or non-string `traceparent`, and stamps Kiroku event identity attributes. If the adapter adds standard message attributes, the test must assert their exact current wire keys.

The semantic-convention acceptance criterion is explicit: no emitted standard attribute may use known stale names where current generated keys exist. In particular, tests or compile-time constants must protect `messaging.operation.type` instead of `messaging.operation`, `messaging.batch.message_count` instead of a hand-typed `kiroku.batch.rows` replacement for the standard count, and `db.system.name` instead of `db.system` on spans that represent PostgreSQL database work.

The Shibuya acceptance criterion is that Cabal resolves `shibuya-core >=0.6 && <0.7` for the adapter and benchmark. If Hackage has not yet published 0.6, the workspace may pin the registered Git commit, but it must not silently fall back to `shibuya-core-0.5.0.0`.

The Nix acceptance criterion is `nix build .#shibuya-kiroku-adapter`. If Nix fails only because pinned Nix tooling cannot parse a dependency's Cabal file, update `nix/haskell-overlay.nix` with the smallest source-equivalent Cabal-version patch and record the exact failure and patch in Surprises & Discoveries.


## Idempotence and Recovery

The research commands are read-only and can be repeated. Cabal builds and tests can be rerun safely.

Dependency edits are recoverable by reading the relevant `.cabal` file and restoring the intended bounds from this plan. Do not use `git reset --hard` or `git checkout --` to recover unless the user explicitly asks for destructive cleanup; the working tree may contain unrelated user changes.

If Cabal solving fails after adding all OpenTelemetry 1.0 packages, inspect the solver output and keep every hs-opentelemetry package on the same source family. Mixing a Hackage 1.0 `api` with an older pinned `sdk` or `exporter-in-memory` is not acceptable. Either all direct hs-opentelemetry packages come from compatible Hackage releases, or all direct packages are pinned to one compatible upstream commit.

If `shibuya-core-0.6.0.0` is not on Hackage, pin the Git source at the recorded commit and add a Decision Log entry explaining why the plan uses a source repository package. When Hackage later publishes 0.6, the source pin can be removed in a follow-up change after the same tests pass.

If OpenTelemetry 1.0 changes a public type enough that preserving `injectTraceContext :: SpanContext -> EventData -> EventData` is impossible, stop and update this ExecPlan before changing the public API. That would be a breaking change for `kiroku-otel` users and must be called out in the changelog.


## Interfaces and Dependencies

At completion, `kiroku-otel/kiroku-otel.cabal` must depend on:

```cabal
hs-opentelemetry-api                   ^>=1.0
hs-opentelemetry-propagator-w3c        ^>=1.0
hs-opentelemetry-semantic-conventions  ^>=1.40
```

Its test suite must use compatible 1.0 SDK/exporter packages:

```cabal
hs-opentelemetry-sdk                 ^>=1.0
hs-opentelemetry-exporter-in-memory  ^>=1.0
```

`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` and `kiroku-store/kiroku-store.cabal` must require:

```cabal
shibuya-core >=0.6 && <0.7
```

The public `kiroku-otel` interfaces should remain:

```haskell
injectTraceContext :: SpanContext -> EventData -> EventData
extractTraceContext :: RecordedEvent -> Maybe SpanContext
subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())
```

The implementation should import OpenTelemetry 1.0 APIs from these modules:

```haskell
OpenTelemetry.Trace.Core
OpenTelemetry.Propagator.W3CTraceContext
OpenTelemetry.Attributes
OpenTelemetry.SemanticConventions
```

Standard attribute names should come from `OpenTelemetry.SemanticConventions` with `AttributeKey.unkey`. Kiroku-specific attributes should remain under the `kiroku.*` namespace and Shibuya-specific attributes under `shibuya.*`, matching Shibuya 0.6's approach.
