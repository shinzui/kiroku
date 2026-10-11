---
type: Architecture Decision Record
title: The inspection surface is composable, self-hosting and self-describing
description: "Compose inspection through declared providers, host it standalone in the sister package and discover actual wiring without reading the store."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-11T02:48:40Z"
docId: ADR-18
status: Accepted
date: 2026-10-11
timestamp: "2026-10-11T02:48:40Z"
originatingPlan: docs/plans/95-serve-the-kiroku-inspection-surface-standalone-and-make-it-self-describing.md
---

# ADR-0018: The inspection surface is composable, self-hosting and self-describing

- **Related:** [ADR-9](0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md),
  [ADR-1](0001-resolve-stream-names-via-lookup-not-recordedevent-field.md),
  [ADR-6](0006-versioned-public-sql-relations-are-owner-published-and-frozen.md),
  [ADR-15](0015-inspection-observers-preserve-wire-contracts-and-bound-shared-work.md),
  [MasterPlan 13](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md),
  [plan 95](../plans/95-serve-the-kiroku-inspection-surface-standalone-and-make-it-self-describing.md),
  [plan 87](../plans/87-serve-durable-subscription-checkpoints-over-http.md),
  [plan 88](../plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md),
  [plan 89](../plans/89-expose-a-public-dead-letter-read-api.md),
  [plan 90](../plans/90-add-configurable-cors-support-to-kiroku-metrics.md),
  [plan 94](../plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md).
  Related requests are local IR-8 through IR-12; cross-project authorities are
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`,
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`,
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`,
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-5`,
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7`,
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`, and
  `mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`
  (artifact-level URI pending).

## Context

An embedded worker owns the store and collector. Keiro's composed host needs a
plain WAI application behind a prefix, whereas an adopter of only Kiroku needs a
backend without writing a host. The inspection surface grew from metrics and
health into durable progress, bounded history, dead letters and event tails.
Opaque provider functions and process-local worker registries make configuration
flags alone insufficient to explain which screens a server supports.
ADR-15 already constrains compatibility, lifecycle and shared-resource cost;
this record fixes hosting, discovery and provider ownership.

## Decision

1. The shared server holds provider closures rather than a `KirokuStore`.
   Store-backed behavior enters through the additive `ServerProviders` record:
   live status, durable checkpoints, `storeBrowsing`, dead letters and a
   WebSocket app. New routes extend this composition boundary; hosts choose
   their providers. Legacy signatures and legacy unconfigured responses remain.
2. `combinedAppWithProviders` is the composable unit: a plain WAI application
   wrapped once in the host's CORS policy, using mount-relative HTTP and
   WebSocket dispatch. Hosts strip their prefix from `pathInfo`. Responses do
   not embed absolute URLs, and clients retain the configured base path.
3. `kiroku-inspect` lives in `kiroku-metrics`, depends on published packages,
   opens a migrated store and collector, then uses that same provider wiring.
   It runs no subscriptions and says so. An empty live registry and metrics
   map describe this process; durable reads describe the database. Validated
   flags override environment values, including explicit credentials False.
   Startup succeeds only after binding; signal shutdown releases bracketed
   resources. Diagnostics never print a connection string.
4. `GET`/`HEAD /capabilities` describes actual wiring regardless of enable
   switches, with no database reads. It publishes the compiled package version,
   nine route booleans, CORS enablement and a fixed `process_local` list including
   Prometheus. WebSocket flags combine explicit channel declarations with the
   enable switch; an opaque caller-supplied app is conservatively undeclared
   through legacy starters. Custom hosts declare their channels. These new keys
   join ADR-9's frozen contract when released. Availability is not health.

No authentication, TLS, rate limiting, operator mutation, static UI hosting or
bind-address option is added in this cohort. Starters bind all interfaces; a
controlled network/firewall or authenticating proxy supplies access restriction.
CORS remains browser policy. This child adds no store SQL, index or publisher
work; cumulative performance acceptance and publication remain with plan 96.

## Consequences

One wiring path supports an application, composed host and standalone operator.
Clients can distinguish absent providers from an empty process-local registry
and build screens from discovery. The standalone binary needs no custom host.

Channel declarations are the host's responsibility; they cannot be inferred
from an opaque function. `optparse-applicative` becomes a library dependency.
Record labels remain ambiguous even under NoFieldSelectors when multiple record
types use `port` or `cors`; consumers should qualify configuration updates.
The listener binds all interfaces and the standalone process is not a view of
other processes' live workers. Durable inventory remains the shared authority.

## Alternatives considered

A standalone server in `kiroku-cli` would reverse its existing dependency from
metrics and form a cycle. A new package adds release overhead for one binary.
Probing a WebSocket application during startup exercises connection limits and
is fragile; reporting the enable switch alone falsely advertises stub servers.
Adding a host field broadens a shared configuration API and is deferred.
Copying or aggregating durable state creates another authority and contradicts
the direct-client convention. Broad per-child statistical experiments are
unnecessary for pure startup/discovery metadata; release retains the cumulative
observer-under-append gate without inferring acceptance from local checks.
