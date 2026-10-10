---
type: Architecture Decision Record
title: Browser inspection access is explicit and default off
description: "Apply validated explicit-origin CORS at the composed WAI boundary, preserving disabled behavior and enforcing origin policy before WebSocket upgrades."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-10T16:08:26Z"
docId: ADR-16
status: Accepted
date: 2026-10-10
timestamp: "2026-10-10T16:08:26Z"
originatingPlan: docs/plans/90-add-configurable-cors-support-to-kiroku-metrics.md
---

# ADR-0016: Browser inspection access is explicit and default off

## Context

Browser inspection clients can be served independently of the Haskell process.
[ADR-9](0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
freezes published bodies and frames, while
[ADR-15](0015-inspection-observers-preserve-wire-contracts-and-bound-shared-work.md)
requires disabled observer work to stay off existing paths. The cross-project conventions
at `mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`
(artifact-level URI pending), require explicit default-off browser access.

## Decision

A host opts in through the `cors` policy in `MetricsServerConfig`. An empty origin
list returns the original WAI application directly. Enabled middleware captures its
normalized allowlist once at application construction, without database calls or threads.
Origins are validated HTTP(S) scheme/host/port triples, accepting ASCII DNS, IPv4 and
bracketed IPv6. Wildcards, opaque origins, user information and malformed authorities
cannot be configured. Configuration normalization does not excuse malformed or duplicate
request origins.

Apply the policy outside combined HTTP/WebSocket dispatch. Every new starter and route
inherits that composition boundary. Hosts using the bare HTTP application must wrap it
explicitly. Enabled ordinary HTTP responses always vary on Origin, including ungranted
responses; preserve existing Vary tokens and wildcard variation. Only allowed origins
receive grants. Preflight validates read methods and HTTP header tokens before reflecting
them and varies on those inputs. The credentials switch cannot enable wildcard grants.

Browsers do not apply HTTP CORS rules to WebSocket handshakes. Enforce the same origin
allowlist at the WAI boundary before upgrade, refusing malformed, duplicate or disallowed
origins with HTTP 403 `origin_not_allowed`. Absent origins remain usable by nonbrowser
clients. Disabled policy retains the previously open upgrades. Preserve raw upgrade
responses and published legacy bodies. New errors use the shared structured error helpers.

CORS is browser response access policy, not authentication. Deployment still requires
trusted network access or an authenticating TLS proxy. A same-origin UI and API proxy is
a supported alternative requiring no CORS configuration.

## Consequences

Later inspection routes and embedded or standalone hosts inherit one policy rather than
implementing it independently. Existing defaultConfig record updates continue to work;
complete and positional constructor callers must supply the new field under the PVP.
Unreleased tests in `kiroku-metrics/test/Test/CorsSpec.hs` verify disabled identity,
validation, cache variation, preflight errors and real store-backed WebSocket enforcement.
The cohort release remains responsible for cumulative performance and publication evidence.

## Alternatives considered

Per-route CORS and WebSocket-only origin checks were rejected because a new route or
starter could bypass them. Wildcard grants and permissive authority splitting were rejected
because they weaken explicit-origin configuration. A mandatory proxy-only deployment was
rejected because independently hosted clients need a supported cross-origin option.
