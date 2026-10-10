---
type: Improvement Request
title: Add configurable CORS support to kiroku-metrics
description: >-
  Add host-configured, default-off CORS support to kiroku-metrics — an explicit allowed-origins
  list applied to HTTP responses, preflight requests, and WebSocket upgrades — so a browser UI
  served from another origin can call the inspection endpoints at all.
generated:
  by: anthropic/claude-fable-5
  at: "2026-08-19T00:00:00Z"
timestamp: "2026-10-10T16:10:46Z"
requestId: IR-11
status: in_progress
origin: mori://shinzui/keiro-ui
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-10-10T16:10:46Z"
    document_timestamp: "2026-10-10T16:10:46Z"
    scope: authoring-metadata
    outcome: comments
    provider: openai
    model: gpt-6.1-sol
    context: >-
      Checked the required title, description, request identity, lifecycle, origin and
      timestamp metadata against the bundle profile. This is an authoring-metadata
      review only; source claims, implementation acceptance and release evidence were
      not reviewed here.
---

# Improvement Request: Add Configurable CORS Support to kiroku-metrics

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`). This
is the enabling request for every browser consumer of kiroku-metrics: without it, none of the
other endpoints requested by the initiative are reachable from a browser page on a different
origin. Implementation is kiroku's own downstream work under kiroku's plans.

Accepted by kiroku on 2026-09-10. Implementation is planned by
[ExecPlan 90, Add configurable CORS support to kiroku-metrics](../plans/90-add-configurable-cors-support-to-kiroku-metrics.md)
(`mori://shinzui/kiroku/plans/90-add-configurable-cors-support-to-kiroku-metrics`), which adds a
`cors` policy field to `MetricsServerConfig` (default off; an explicit allowed-origins list with
the wildcard unrepresentable) and applies it as a WAI middleware to HTTP responses, preflight
requests, and WebSocket upgrades.

Since 2026-09-30 that plan is EP-1 of
[MasterPlan 13, Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md)
(`mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`),
which coordinates IR-8 through IR-12 as one cohort and lands this plan first because every
browser consumer depends on it. The release moved out of plan 90: the request moves to
`in_progress` when plan 90's first milestone starts and to `completed` once the cohort release
(a `kiroku-metrics` major, forecast 0.3.0.0), performed by
[ExecPlan 96](../plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md),
is published.

Implementation began on 2026-10-10. Local implementation evidence remains separate from
the cohort release and completion in plan 96.

## Context

CORS (Cross-Origin Resource Sharing) is the browser mechanism that blocks a web page served
from one origin from calling an HTTP API on another origin unless the API opts in via response
headers. `kiroku-metrics` sends no CORS headers anywhere (verified 2026-08-19 at commit
`c2d0328`: zero matches for CORS handling under `kiroku-metrics/src`), so a browser app served
from anywhere other than the metrics server itself cannot call `GET /metrics`,
`GET /subscriptions`, or any future browsing endpoint, and cannot complete a cross-origin
WebSocket handshake policy check.

The cross-project conventions the initiative defined
(`mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`, artifact-level URI
pending, area 7) set the posture: an explicit allowed-origins list configured by the host
application, disabled by default, and no wildcard origin when credentials are involved. The
conventions also note the zero-server-change alternative — serving the UI and reverse-proxying
the APIs from one origin — which remains a legitimate deployment; the configuration hook is
still required because the composed UI will typically face several backends, not all behind one
proxy.

## Requested Change

1. `MetricsConfig` (`kiroku-metrics/src/Kiroku/Metrics/Config.hs`) gains a CORS setting: an
   explicit list of allowed origins, default empty. With the default, behavior is today's —
   no CORS headers are emitted anywhere.
2. When origins are configured, HTTP responses to requests from an allowed origin carry the
   appropriate CORS headers, and preflight `OPTIONS` requests are answered correctly for the
   methods and headers the server actually supports.
3. WebSocket upgrade requests validate the `Origin` header against the same configuration:
   allowed origins upgrade as today, disallowed browser origins are rejected before the
   protocol starts.
4. The configuration API makes the forbidden combination unrepresentable or rejected: no
   wildcard origin together with credentialed requests.
5. Requests from origins not on the list receive no CORS headers (the browser blocks them);
   non-browser clients (no `Origin` header) are unaffected in all configurations.

## Boundaries

This request is CORS only. It does not ask for authentication, authorization, TLS termination,
or rate limiting — the initiative's recorded posture is that inspection servers assume a trusted
network or an authenticating reverse proxy, and that gap is documented, not solved, by the UI
initiative. It does not ask to change any endpoint's payload.

## Acceptance

1. With no CORS configuration, all responses are byte-for-byte free of CORS headers — identical
   to today's behavior.
2. With `https://ops.example.com` configured, a preflight
   `OPTIONS /metrics` with `Origin: https://ops.example.com` and
   `Access-Control-Request-Method: GET` receives a success status and
   `Access-Control-Allow-Origin: https://ops.example.com`, and a subsequent
   `GET /metrics` from that origin carries the same allow-origin header.
3. The same requests with `Origin: https://evil.example.com` receive no CORS headers.
4. With `https://ops.example.com` configured, a WebSocket upgrade to `/ws/events` with that
   `Origin` succeeds and one with a disallowed browser `Origin` is rejected.
5. A curl request with no `Origin` header behaves identically in all configurations.
6. Attempting to configure a wildcard origin for credentialed use fails at configuration time
   (or is unrepresentable in the config type).

## Requested Deliverables

The `MetricsConfig` extension and its application across HTTP routes, preflight handling, and
the WebSocket upgrade path; tests covering the acceptance transcripts above; documentation in
`docs/user/metrics.md` including the reverse-proxy alternative; changelog entries and
PVP-appropriate version bumps, at kiroku's discretion.

## Implementation Evidence

Plan 90 implements `Kiroku.Metrics.Cors`, the `cors` field in
`MetricsServerConfig`, and one wrap around combined HTTP/WebSocket dispatch.
Configuration validates explicit HTTP(S) origins; disabled middleware is the original
application. Enabled responses vary on Origin even without a grant, allowed GET/HEAD
preflights validate requested headers, and disallowed upgrade origins are refused with
HTTP 403 `origin_not_allowed` before framing. Shared JSON helpers sanitize store failures
for the next inspection routes without changing published legacy errors.

`kiroku-metrics/test/Test/CorsSpec.hs` covers configuration, WAI response identity,
cache variation, preflight validation, credentials/max-age and real store-backed HTTP
and WebSocket behavior. The metrics suite reports 43 examples, zero failures.
The seven-step `kiroku-metrics-example` verifies preflight and allowed/disallowed GET
behavior alongside existing metrics, health and event-tail checks. The guide documents
the single-origin proxy alternative and the trusted-network/authenticating-proxy posture.
[ADR-16](../adr/0016-browser-inspection-access-is-explicit-and-default-off.md) records the
composition invariant. This is local implementation evidence; IR-11 remains `in_progress`
until plan 96 publishes and verifies the cohort.
