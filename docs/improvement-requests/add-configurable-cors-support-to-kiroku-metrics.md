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
timestamp: "2026-08-19T00:00:00Z"
requestId: IR-11
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Add Configurable CORS Support to kiroku-metrics

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`). This
is the enabling request for every browser consumer of kiroku-metrics: without it, none of the
other endpoints requested by the initiative are reachable from a browser page on a different
origin. Implementation is kiroku's own downstream work under kiroku's plans.

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
