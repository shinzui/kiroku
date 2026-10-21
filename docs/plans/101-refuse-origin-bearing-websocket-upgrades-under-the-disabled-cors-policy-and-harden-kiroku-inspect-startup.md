---
id: 101
slug: refuse-origin-bearing-websocket-upgrades-under-the-disabled-cors-policy-and-harden-kiroku-inspect-startup
title: "Refuse Origin-bearing WebSocket upgrades under the disabled CORS policy and harden kiroku-inspect startup"
kind: exec-plan
created_at: 2026-10-21T14:06:08Z
intention: "intention_01m5fcgrhve7mam08dd9f581h4"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T14:06:08Z
---

# Refuse Origin-bearing WebSocket upgrades under the disabled CORS policy and harden kiroku-inspect startup

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The kiroku-metrics package serves an inspection API over HTTP and WebSocket: browse
streams, read dead letters and checkpoints, and tail live events on `/ws/events`. Its
CORS policy, which decides which browser origins may read responses, is off by default
(`corsDisabled`), and `kiroku-inspect`, the standalone server, inherits that default
when started without `--cors-origin`. Browsers do not apply CORS to WebSocket
handshakes, and with the policy disabled the middleware checks nothing, so any web page
a user visits can open `ws://<host>:9091/ws/events`, send `subscribe_events` from
position 0 and read every event payload. The listener binds all interfaces. Review
REV-3 (`docs/reviews/kiroku-0-11-inspection-cohort.md`) recorded this, noted that the
kiroku-metrics 0.3.0.0 changelog claims a "WebSocket origin refusal before upgrade"
that the default does not perform, and the user chose on 2026-10-21 to close the
browser case: with CORS disabled, a WebSocket upgrade that carries an `Origin` header is
refused; upgrades without one, which command-line and Haskell clients send, are
unaffected, and HTTP behaviour is unchanged.

The same review listed three smaller `kiroku-inspect` operability gaps: `--port 0`
binds loopback only while fixed ports bind every interface and the guide says there is
no bind option; every startup failure collapses into one redacted line so a port in
use, a bad password and a missing schema are indistinguishable; and a second
SIGINT or SIGTERM during a hung shutdown does nothing.

After this plan, a page served from another origin cannot open the inspection
WebSocket on a host that never configured CORS, the documentation and changelog say
exactly that, `kiroku-inspect` reports which class of startup failure it hit without
leaking connection details, a second interrupt ends it, and the free-port behaviour is
documented as the safe loopback it already is.


## Progress

- [ ] Milestone 1: with `corsDisabled`, a WebSocket upgrade carrying any `Origin` header is refused with HTTP 403 and the `origin_not_allowed` envelope, an upgrade without `Origin` succeeds, and HTTP requests with `Origin` are unchanged; `CorsSpec` pins all three and the full kiroku-metrics suite passes.
- [ ] Milestone 2: ADR-16, `docs/user/metrics.md`, `docs/guides/building-an-inspection-ui.md` and the kiroku-metrics changelog describe the new default, the changelog's erroneous 0.3.0.0 claim is corrected in place, and the next-version entry is marked breaking.
- [ ] Milestone 3: `kiroku-inspect` prints one of four startup failure classes without details, exits on a second SIGINT or SIGTERM, and documents that `--port 0` listens on loopback only; `StandaloneSpec` covers the failure classes.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Under the disabled policy, refuse WebSocket upgrades that carry an `Origin`
  header; do not add origin checks to ordinary HTTP under the disabled policy.
  Rationale: Chosen by the user on 2026-10-21. Browsers always send `Origin` on a
  WebSocket handshake and never apply CORS to it, so the header is the only signal; for
  plain HTTP the absence of `Access-Control-Allow-Origin` already stops a page from
  reading the response, so nothing changes there.
  Date: 2026-10-21
- Decision: This is a breaking change for kiroku-metrics (next version 0.4.0.0), not a
  patch, because a browser client on a host that relied on the open default stops
  working until the host configures `cors` or `--cors-origin`.
  Rationale: The behaviour is user-visible and the fix for an affected deployment is
  configuration, which the changelog must tell them.
  Date: 2026-10-21
- Decision: `--port 0` keeps binding loopback; the plan documents it instead of changing it.
  Rationale: Loopback is the safer direction for an ephemeral port, and nothing in the
  repository depends on the free port being reachable from another host.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The server is composed in `kiroku-metrics/src/Kiroku/Metrics/Server.hs`.
`combinedAppWithProviders` (around line 174) wraps the combined HTTP and WebSocket
dispatch in `corsMiddleware cfg.cors`; dispatch hands a request to the WebSocket
application when `wai-websockets`' `websocketsOr` recognizes an upgrade. CORS is in
`kiroku-metrics/src/Kiroku/Metrics/Cors.hs`: `CorsPolicy`, `corsDisabled`,
`corsEnabled`, `originAllowed`, and `corsMiddleware` (lines 228 to 258). Its first
guard, `| not (corsEnabled policy) = id`, is the behaviour this plan changes. The
enabled branch already contains the refusal to reuse: for `isWebSocketsReq req` it
admits requests with no `Origin` values, admits a granted origin, and otherwise replies
`errorResponse status403 "origin_not_allowed" "The request origin is not allowed." Nothing`.
`headerValues originHeader (requestHeaders req)` returns every `Origin` value present.

The standalone server is `kiroku-metrics/src/Kiroku/Metrics/Standalone.hs`
(`inspectParserInfo`, `resolveInspectOptions`, `runInspect`, `InspectHooks`,
`renderStartupBanner`) with its executable in `kiroku-metrics/app-inspect/Main.hs`: it
installs `Catch` handlers for SIGINT and SIGTERM that fill an `MVar` once, runs
`runInspect` under `tryJust synchronousException`, and on any synchronous exception
prints `kiroku-inspect: startup or server failure (details redacted)` and exits 1.
Port 0 goes through `Warp.openFreePort` in `startMetricsServerWithProviders`, which
binds `127.0.0.1`; fixed ports use `Warp.setHost "*"`.

Tests: `kiroku-metrics/test/Test/CorsSpec.hs` holds the policy and middleware tests,
including "keeps upgrades open to any origin under the default disabled policy" (line
202) and the `wsSnapshot` helper (line 246) that connects with explicit request headers
through `WS.runClientWith`. The `websockets` client sends no `Origin` unless given one;
`kiroku-metrics/test/Test/StandaloneSpec.hs` line 119 and `CheckpointsSpec.hs` lines
199 to 225 connect with plain `WS.runClient` and must keep passing. `StandaloneSpec.hs`
lines 153 to 170 pin the redacted failure line and exit code.

Documentation: `docs/user/metrics.md` line 119 (config table: "Disabled sends no CORS
headers and leaves upgrades open"), lines 690 to 696 (the CORS section's statement
that under the disabled policy "upgrades remain open to any origin"), and the
`kiroku-inspect` option table around line 880; `docs/guides/building-an-inspection-ui.md`
line 229 (the listener "binds all interfaces", "no bind option") and line 148 (tail error
contract); `kiroku-metrics/CHANGELOG.md` line 48 (the 0.3.0.0 claim). The
conventions for error envelopes are in `kiroku-metrics/src/Kiroku/Metrics/JSON.hs`
(`errorResponse`, `errorEnvelope`).

Relevant ADRs: [ADR-16](../adr/0016-browser-inspection-access-is-explicit-and-default-off.md)
decides default-off CORS and says in its Decision section "Disabled policy retains the
previously open upgrades"; this plan amends that sentence.
[ADR-18](../adr/0018-the-inspection-surface-is-composable-self-hosting-and-self-describing.md)
covers the standalone server and `/capabilities`; the capability document does not
advertise CORS state, so it needs no change unless the implementer finds it does.
[ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
freezes wire shapes: the 403 envelope already exists, so no new shape is introduced.
Downstream consumers of kiroku-metrics are listed by
`mori registry dependents shinzui/kiroku --packages`; `mori://shinzui/keiro-ui` is the
browser client and must already configure origins to work at all, which the implementer
should confirm from that project's documentation before writing the changelog's
migration note. No cross-repository ADR applies.


## Plan of Work

Milestone 1 changes the disabled branch of `corsMiddleware`. Replace `id` with a
middleware that, when `isWebSocketsReq req` holds and `headerValues originHeader
(requestHeaders req)` is non-empty, replies with the same 403 envelope the enabled
branch uses, and otherwise passes the request through untouched, adding no headers.
Keep the enabled branch exactly as it is. Update the Haddock on `corsMiddleware` and
on `corsDisabled` to state the rule. In `CorsSpec.hs` turn the "keeps upgrades open"
case into three: an upgrade with `Origin` under `corsDisabled` fails the handshake with
a 403 (the existing `wsSnapshot` helper and the `MalformedResponse` pattern used by the
enabled-policy refusal test show how to assert it), an upgrade without `Origin` under
`corsDisabled` succeeds, and a plain HTTP GET with `Origin` under `corsDisabled`
returns 200 with no `Access-Control-*` headers (the `grants` helper filters them).
Run the whole kiroku-metrics suite; `StandaloneSpec`, `CheckpointsSpec` and
`WebSocketConvergenceSpec` connect without `Origin` and prove nonbrowser clients are
unaffected.

Milestone 2 fixes the words. Amend ADR-16's Decision paragraph on upgrades to say that
the disabled policy refuses `Origin`-bearing upgrades and admits origin-less ones, with
a dated amendment note, a bumped `timestamp`, a log entry and strict validation.
Rewrite `docs/user/metrics.md` line 119 and the CORS section accordingly, and add one
sentence to the `kiroku-inspect` section saying that browser clients require
`--cors-origin`. In `kiroku-metrics/CHANGELOG.md`, add an `## Unreleased` entry under
Breaking Changes that states the new refusal, names the configuration that restores
browser access, and corrects the 0.3.0.0 claim in place with a short "Erratum
(2026-10-21)" line under that entry, so the repository changelog no longer overstates
what 0.3.0.0 did. The published Hackage copy cannot change; the erratum and the next
release notes are the correction.

Milestone 3 hardens the standalone executable. In `app-inspect/Main.hs` replace the
single redacted line with a classification: a `bind` failure (an `IOException` from
Warp's socket setup, typically address in use or permission denied), a `database`
failure (a `StoreError` such as `ConnectionLost` or `ConnectionError`, or the
connection-establishment exception `withStore` raises), a `schema` failure (the
verification `runInspect` performs when the schema is missing, if it raises a distinct
type; read `Standalone.hs` to see which exception it throws and classify on that), and
`other`. Print `kiroku-inspect: <class> failure (details redacted)` and keep exit code
1; never print the exception text, because connection strings carry passwords. Put the
classifier in `Standalone.hs` as a pure function over `SomeException` so
`StandaloneSpec` can test it with constructed exceptions, and extend the existing
redaction test to assert the class word for a bind failure (start a second instance on
the same fixed port) and a database failure (an unreachable socket path, as
`ScriptSessionErrors` in kiroku-store does with `host=/nonexistent/...`). For signals,
keep the first `Catch` that fills the `MVar`, and have the handler install a second
handler on the same signal that calls `exitImmediately (ExitFailure 130)` so a second
interrupt ends the process even if teardown hangs; document this in the executable's
`--help` footer and in `metrics.md`. Finally, correct the guide's bind statement: fixed
ports listen on all interfaces, `--port 0` on loopback only, and no bind option exists.


## Concrete Steps

All commands run from the repository root.

```bash
cabal build kiroku-metrics:kiroku-metrics-test kiroku-metrics:kiroku-inspect
cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct \
  --test-options='--match "Cors"'
```

Before milestone 1 the new refusal case fails because the handshake succeeds; after it,
the CORS group passes. Then run the whole package suite and expect every example to pass:

```bash
cabal test kiroku-metrics:kiroku-metrics-test
```

Manual check of the user-visible behaviour, with a kiroku database available:

```bash
DATABASE_URL='postgresql://localhost/kiroku' $(cabal list-bin kiroku-metrics:kiroku-inspect) --port 9091
```

In another shell, a handshake with an `Origin` header must be refused and one without
must succeed:

```bash
curl -si -H 'Origin: http://evil.example' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://127.0.0.1:9091/ws/events | head -1
curl -si -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://127.0.0.1:9091/ws/events | head -1
```

```text
HTTP/1.1 403 Forbidden
HTTP/1.1 101 Switching Protocols
```

Startup failure classes (second command with the first still running):

```bash
$(cabal list-bin kiroku-metrics:kiroku-inspect) --port 9091
```

```text
kiroku-inspect: bind failure (details redacted)
```

Bundle validation after the ADR amendment:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix fmt
```


## Validation and Acceptance

Milestone 1 is accepted when the three new `CorsSpec` cases pass, every other
kiroku-metrics example still passes, and the manual `curl` check above shows 403 with
`Origin` and 101 without. Milestone 2 is accepted when ADR-16 validates strictly, the
user guide and inspection guide no longer say upgrades stay open under the disabled
policy, and the changelog carries both the breaking entry and the erratum. Milestone 3
is accepted when `StandaloneSpec` asserts at least the bind and database classes, a
second interrupt terminates a running `kiroku-inspect` within a second during a
deliberately slow shutdown (verify by hand: start it, send SIGINT twice), and the guide
documents the loopback free port.

Early integration check: the WebSocket client in `StandaloneSpec` (plain `WS.runClient`)
is the representative nonbrowser consumer; it must pass unchanged after milestone 1
before the documentation work starts.

Proposed, not required: adding a `cors` field to `/capabilities` so a UI can discover
whether browser access is configured; record the decision if taken.


## Idempotence and Recovery

Code changes are additive to a branch of one function and to the executable's error
handling; reverting the single commit restores the open default. Tests use ephemeral
databases and ports chosen by the test harness. The ADR amendment and changelog erratum
are additive text. Every step can be repeated safely.


## Interfaces and Dependencies

`Kiroku.Metrics.Cors.corsMiddleware :: CorsPolicy -> Middleware` keeps its type;
`corsDisabled` keeps its value, only its documented behaviour on upgrades changes.
`wai-websockets` (`Network.Wai.Handler.WebSockets.isWebSocketsReq`) detects upgrades;
`wai` and `warp` serve; `websockets` is the test client. `Kiroku.Metrics.JSON.errorResponse`
builds the 403 envelope with code `origin_not_allowed`. `Kiroku.Metrics.Standalone`
gains a pure failure classifier; `unix` (`System.Posix.Signals`) and `System.Exit.exitImmediately`
are used by the executable. kiroku-metrics' next version is 0.4.0.0; kiroku-store is
untouched.
