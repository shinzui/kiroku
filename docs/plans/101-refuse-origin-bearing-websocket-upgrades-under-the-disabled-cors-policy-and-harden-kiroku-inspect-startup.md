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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T18:58:39Z
      verdict: "changes-requested"
      note: "Ground failure classification in actual startup exceptions; fix mixed-signal shutdown and conflicting tests; cover same-origin proxy migration and existing CORS capabilities."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T19:17:17Z
      mode: "update"
      note: "Apply review findings: typed startup failures, shared signal state and deterministic subprocess checks, conflicting-test updates, same-origin proxy migration, and existing CORS discovery."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T19:51:44Z
      mode: "implement"
      note: "Implement default WebSocket origin refusal and standalone startup and shutdown hardening."
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
position 0 and read every event payload. Fixed-port listeners bind all interfaces. Review
REV-3 (`docs/reviews/kiroku-0-11-inspection-cohort.md`) recorded this, noted that the
kiroku-metrics 0.3.0.0 changelog claims a "WebSocket origin refusal before upgrade"
that the default does not perform, and the user chose on 2026-10-21 to close the
browser case: with CORS disabled, a WebSocket upgrade that carries an `Origin` header is
refused; upgrades without one, which command-line and Haskell clients send, are
unaffected, and HTTP behaviour is unchanged. This refusal also applies to browser
WebSockets forwarded by a same-origin proxy that preserves `Origin`: those deployments
must configure the page's public origin even though their HTTP requests need no CORS
response headers.

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

- [x] Milestone 1 (2026-10-25; full package suite: 118 examples, 0 failures): with `corsDisabled`, a WebSocket upgrade carrying any `Origin` header is refused with HTTP 403 and the `origin_not_allowed` envelope, an upgrade without `Origin` succeeds, and HTTP requests with `Origin` are unchanged; `CorsSpec` pins all three and the full kiroku-metrics suite passes.
- [x] Milestone 2 (2026-10-25; strict ADR validation: 20 concepts; capabilities tests passed in the 118-example suite): ADR-16, `docs/user/metrics.md`, `docs/guides/building-an-inspection-ui.md` and the kiroku-metrics changelog describe the new default and same-origin proxy migration; the 0.3.0.0 claim is corrected in place and the next-version entry is marked breaking. Existing `cors.enabled` discovery remains compatible.
- [x] Milestone 3 (2026-10-25; final formatted candidate: 124 examples, 0 failures; all four blocked-teardown signal pairs exit 130 within one second; strict ADR validation passes): `kiroku-inspect` distinguishes bind, database, schema and other failures without details; either signal starts graceful shutdown and a second SIGINT or SIGTERM forces exit, including mixed pairs. Tests cover actual startup failures and a deliberately blocked shutdown; the guides and ADR-18 document loopback-only `--port 0`.


## Surprises & Discoveries

The 2026-10-25 review found that `runInspect` has no explicit schema verification.
`Store.withStore` starts a notifier and publisher before the HTTP listener: notifier
connection failures raise `NotifierStartError`, while the publisher's initial
`currentGlobalPositionStmt` throws raw `Hasql.Pool.UsageError`. A missing schema makes
the unqualified `streams` query fail; classification must inspect structured errors,
not assume a dedicated schema exception.

The same review found two tests that encode the old behaviour: disabled middleware
identity includes an Origin-bearing upgrade, and the executable signal test expects
exit 0 after repeated signals. Both must change. `/capabilities` already contains
`cors.enabled`, and both guides and ADR-16 explicitly support same-origin proxies
without CORS configuration; that WebSocket guidance needs a migration note.


## Decision Log

- Decision: Under the disabled policy, refuse WebSocket upgrades that carry an `Origin`
  header; do not add origin checks to ordinary HTTP under the disabled policy.
  Rationale: Chosen by the user on 2026-10-21. Browsers always send `Origin` on a
  WebSocket handshake and never apply CORS to it, so the header is the only signal; for
  plain HTTP the absence of `Access-Control-Allow-Origin` already stops a cross-origin
  page from reading the response, so nothing changes there.
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
- Decision: Classify the existing startup exceptions and mark listener setup failures
  at the standalone boundary; do not add a schema probe or change kiroku-store.
  Rationale: The existing publisher query supplies the missing-schema failure, and
  arbitrary `IOException` values can also come from hooks or output rather than bind.
  Date: 2026-10-25
- Decision: Count delivered SIGINT and SIGTERM handlers in one atomic state, independent
  of the shutdown notification. The first requests graceful shutdown; the second
  forces exit 130, even when the signals differ.
  Rationale: Replacing only one signal's handler misses mixed pairs, and consuming an
  `MVar` notification must not reset the shutdown state. A subprocess fixture with
  blocked teardown makes the acceptance condition deterministic.
  Date: 2026-10-25


## Outcomes & Retrospective

Completed 2026-10-25. Disabled CORS now refuses every tested Origin-bearing
upgrade with the existing 403 envelope before dispatch, while ordinary HTTP and
origin-less clients retain their behavior. Real `/ws/events` tests verify refusal
and successful handshakes both without Origin under the default and with an
explicitly configured public origin. Capabilities retain their existing wire shape
and configuration meaning. Both guides, ADR-16 and the changelog explain proxy
migration and the historical erratum; the next release target remains 0.4.0.0.

Standalone diagnostics classify typed listener, notifier, pool and store failures
without rendering their details. Real occupied-port, refused-connection and absent-schema
processes exit 1 with exact redacted lines and no success banner. Hook IO errors
remain `other`; cancellation and supervised socket release continue to pass.
Single SIGINT/SIGTERM exits 0. The shared-handler test fixture proves that all four
ordered signal pairs force exit 130 within one second after teardown is confirmed
blocked, including after the first notification is consumed. Help and ADR-18 document
forced cleanup semantics and the unchanged loopback-only free port.

Acceptance evidence from the repository root:

```bash
nix develop --no-write-lock-file -c cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

The final formatted candidate passed 124 examples with 0 failures in 8.9527 seconds;
the initial CORS milestone passed the then-existing full 118-example suite before
documentation work. Strict ADR validation passed all 20 concepts. `nix fmt` was run
on the changed Haskell/Cabal files, and `git diff --check` passed. The built binary's
`--help` was checked for loopback binding and both signal behaviors. The automated
real-socket assertions supply the 403/101 handshake smoke evidence without a separate
manually managed database or listener.

Durable decisions are recorded in the dated ADR-16 and ADR-18 amendments. No new
scope or dependency bounds were needed, and no performance experiment or publication
was performed. The friction-log query for this plan returned no logged entries;
no friction met the recording threshold during implementation.


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

`kiroku-store/src/Kiroku/Store/Connection.hs` opens the store before the listener.
`kiroku-store/src/Kiroku/Store/Notification.hs` exports `NotifierStartError`, with
`NotifierConnectError` and `NotifierListenError SomeException` constructors.
`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` starts the publisher
by querying the global stream position and throwing any `Hasql.Pool.UsageError`.
The query in `kiroku-store/src/Kiroku/Store/SQL.hs` reads `streams` through the
configured search path. `Kiroku.Store.Error.mapGenericUsageError` in
`kiroku-store/src/Kiroku/Store/Error.hs` already preserves structured PostgreSQL
SQLSTATE codes (five-character error identifiers) as `UnexpectedServerError`.
There is no separate schema-verification exception in `runInspect`.

Tests: `kiroku-metrics/test/Test/CorsSpec.hs` holds the policy and middleware tests,
including "keeps upgrades open to any origin under the default disabled policy" (line
202) and the `wsSnapshot` helper (line 246) that connects with explicit request headers
through `WS.runClientWith`. The `websockets` client sends no `Origin` unless given one;
`kiroku-metrics/test/Test/StandaloneSpec.hs` and
`kiroku-metrics/test/Test/CheckpointsSpec.hs` connect with plain `WS.runClient` and
must keep passing. The standalone test module also contains executable tests for runtime redaction and occupied ports, plus a test named
"exits 0 after SIGINT or SIGTERM, including repeated signals". That last expectation
must be split into graceful first-signal and forced second-signal tests.
`kiroku-metrics/test/Test/CorsSpec.hs` also has a standalone middleware test named
"preserves every response byte and header when disabled, including upgrades and
preflights". Its Origin-bearing upgrade must move to the refusal cases. The existing
enabled-policy network refusal test only matches `MalformedResponse`; that exception
alone does not establish a particular HTTP status or JSON envelope.

Documentation: `docs/user/metrics.md` line 119 (config table: "Disabled sends no CORS
headers and leaves upgrades open"), lines 690 to 696 (the CORS section's statement
that under the disabled policy "upgrades remain open to any origin"), and the
`kiroku-inspect` option table around line 880; `docs/guides/building-an-inspection-ui.md`
line 229 (the listener "binds all interfaces", "no bind option") and line 148 (tail error
contract); `kiroku-metrics/CHANGELOG.md` line 48 (the 0.3.0.0 claim). The
conventions for error envelopes are in `kiroku-metrics/src/Kiroku/Metrics/JSON.hs`
(`errorResponse`, `errorEnvelope`).
The same-origin proxy example in `docs/user/metrics.md` and the security section in
`docs/guides/building-an-inspection-ui.md` currently say no CORS policy is needed;
both must distinguish unchanged same-origin HTTP from the new WebSocket requirement.

Relevant ADRs: [ADR-16](../adr/0016-browser-inspection-access-is-explicit-and-default-off.md)
decides default-off CORS and says in its Decision section "Disabled policy retains the
previously open upgrades". Its empty-policy identity, disabled-identity test claim
and same-origin proxy guidance also need amendment.
[ADR-18](../adr/0018-the-inspection-surface-is-composable-self-hosting-and-self-describing.md)
covers the standalone server and `/capabilities`. `Kiroku.Metrics.Capabilities` in
`kiroku-metrics/src/Kiroku/Metrics/Capabilities.hs` already encodes
`"cors": {"enabled": ...}` from whether origins are configured. Preserve that field
and meaning: `false` will still mean no origins configured, while the disabled policy
now refuses Origin-bearing upgrades. ADR-18 also needs its all-interface binding
statements qualified for port 0 and its signal-shutdown guarantee clarified.
[ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
freezes wire shapes: the 403 envelope already exists, so no new shape is introduced.
[ADR-20](../adr/0020-store-boundaries-preserve-structured-server-errors.md) requires
structured error classification and sanitized public diagnostics; reuse its existing
store error mapping rather than parsing rendered driver messages.
Downstream consumers of kiroku-metrics are listed by
`mori registry dependents shinzui/kiroku --packages`; `mori://shinzui/keiro-ui` is the
browser client. Do not assume its deployment already configures origins: a same-origin
proxy could previously work without them. The migration note must cover both separate
page origins and same-origin proxies, without depending on an unverified downstream
configuration. No cross-repository ADR amendment is required by this plan.


## Plan of Work

Milestone 1 changes the disabled branch of `corsMiddleware`. Replace `id` with a
middleware that, when `isWebSocketsReq req` holds and `headerValues originHeader
(requestHeaders req)` is non-empty, replies with the same 403 envelope the enabled
branch uses, and otherwise passes the request through untouched, adding no headers.
Keep the enabled branch exactly as it is. Update the Haddock on `corsMiddleware` and
on `corsDisabled` to state the rule. In `kiroku-metrics/test/Test/CorsSpec.hs`, narrow
the disabled identity test to ordinary HTTP, preflights and upgrades without Origin.
Use its existing `capture`, `grants` and `errorCode` helpers to check that disabled
upgrades with a normal origin, an empty value, `null`, or duplicate Origin headers
return status 403, JSON content type, and the exact existing `origin_not_allowed`
envelope, with no `Access-Control-*` headers and no invocation of the inner app.
The presence of the header is sufficient; do not parse it in the disabled branch.
Preserve byte/header identity for passed-through requests.

Replace the real-server "keeps upgrades open" case with refusal under `corsDisabled`
and successful origin-less connection cases. Use a real HTTP upgrade request with an
Origin to assert the 403 response and envelope as well as the failed WebSocket
handshake; matching `MalformedResponse` alone is insufficient. Pin refusal on
`/ws/events`, the sensitive event channel, and keep the existing `/ws/metrics`
snapshot helper as the origin-less success check. A plain HTTP GET with Origin under
`corsDisabled` must return 200 with no grants. Preserve enabled-policy allowlist tests,
including successful upgrade for the configured public origin used behind a proxy.
Run the whole kiroku-metrics suite; `StandaloneSpec`, `CheckpointsSpec` and
`WebSocketConvergenceSpec` connect without `Origin` and prove nonbrowser clients are
unaffected.

Milestone 2 fixes the words. Amend ADR-16's disabled-policy identity, upgrade, test and
same-origin proxy passages together: disabled ordinary HTTP is unchanged, but
Origin-bearing upgrades are refused. Include a dated amendment, advance `timestamp`,
and add an `okf log add` entry following the bundle convention. Rewrite the config
table, CORS section and standalone guidance in `docs/user/metrics.md`, and the browser
policy section in `docs/guides/building-an-inspection-ui.md`.

In both guides and ADR-16, explain that a same-origin proxy removes the need for HTTP
CORS grants but does not remove Origin from a browser WebSocket handshake. For the
existing `ops.example.com` proxy example, configure
`--cors-origin https://ops.example.com` on the backend, or the equivalent
`corsAllowOrigins` policy in an embedded host. Preserve the proxy example and describe
this backend setting alongside it. The operator must use the page's public origin,
not the proxy's internal upstream address. Document `cors.enabled` as the existing
configuration indicator, not a promise that disabled WebSockets are unrestricted.

In `kiroku-metrics/CHANGELOG.md`, add a top-level `## Unreleased` section containing
`### Breaking Changes`. State the new refusal, including same-origin proxy impact,
and the configuration that restores browser access. Correct the 0.3.0.0 claim in place
to say origin refusal applied only with CORS enabled, with a dated erratum under that
historical entry. The published Hackage copy cannot change; the erratum and next
release notes are the correction. Keep 0.4.0.0 as the next-release target; publication
is outside this plan.

Milestone 3 hardens the standalone executable. In
`kiroku-metrics/src/Kiroku/Metrics/Standalone.hs`, add a pure classifier over
`SomeException` returning one of `bind`, `database`, `schema`, or `other`. Give bind
failures a typed marker carrying the original `IOException`, applied only to listener
setup. Keep the existing supervised `withMetricsServerWithProviders` lifetime. One
concrete way to distinguish setup is a local listening flag surrounding that call:
set it at entry to its callback, before invoking the user's `onListening` hook, and
wrap only `IOException` values caught before that flag is set. The store acquisition
stays outside this catch. Unmarked IO errors from hooks, output or teardown classify
as `other`; preserve asynchronous exception propagation.

Recognize `NotifierConnectError` as `database`. For raw `Hasql.Pool.UsageError`, reuse
`Kiroku.Store.Error.mapGenericUsageError` to recover structured store errors. Classify
`UnexpectedServerError` with SQLSTATE `42P01` (undefined table) or `3F000` (invalid
schema name) as `schema`; classify remaining pool errors and store connection,
timeout, transient transaction or other server errors as `database`. For
`NotifierListenError`, inspect any recognized nested pool/store exception using the
same rules and otherwise classify the notifier setup failure as `database`.
Unrelated exceptions and store domain errors default to `other`. Do not parse
exception text or add SQL to preflight the schema. This is a startup diagnostic
classification, not a new schema compatibility validator.

In `kiroku-metrics/app-inspect/Main.hs`, print exactly
`kiroku-inspect: <class> failure (details redacted)` for synchronous runtime failures
and retain exit code 1. Never print the marker's underlying exception, database URL,
SQL or server message. Retain exit code 2 for option/resolution errors. Extend
`kiroku-metrics/test/Test/StandaloneSpec.hs` with pure classifier cases for all four
classes, including an unrelated `userError` classified as `other`. Extend the existing
executable tests to assert the exact redacted line for an occupied port and refused
database connection. Add a real missing-schema case using a migrated test database
with `--schema plan101_missing_schema`, after confirming that schema is absent; it
must exit 1, print the `schema` line, and print no success banner. Each startup test
uses the existing bounded subprocess helpers and checks that secret-bearing
diagnostic inputs are absent from output.

Put signal installation in a shared executable-internal module,
`kiroku-metrics/app-inspect/InspectSignals.hs`, used by Main and the test subprocess
fixture. Install `Catch` handlers for both signals using one atomic, persistent
shutdown flag (for example an `IORef Bool` updated with `atomicModifyIORef'`). The
first delivered handler marks shutdown requested and fills the existing notification
`MVar`; every later handler calls `System.Posix.Process.exitImmediately
(ExitFailure 130)`. Consuming the notification must not reset the flag. Use a
bracketed helper that restores previous handlers on ordinary exit, including cleanup
if installation fails. Do not replace handlers dynamically or expose a production
CLI option for delaying teardown.

For deterministic evidence, add a private `--inspect-signal-fixture` dispatch in
`kiroku-metrics/test/Main.hs`, before starting the PostgreSQL harness or Hspec. It
uses the same `InspectSignals` helper, flushes `READY` after installing handlers,
waits for the first shutdown notification, then enters a bracket finalizer that
flushes `SHUTTING_DOWN` and blocks on an empty `MVar`. In `StandaloneSpec`, spawn the
test executable itself with this argument, wait for READY, deliver the first signal,
wait for SHUTTING_DOWN, and only then deliver the second. Cover SIGINT/SIGINT,
SIGTERM/SIGTERM and both mixed orders. Each child must exit 130 within one second of
the second signal; use bounded setup waits and bracketed child cleanup on failure.
The handshake between parent and child prevents signal coalescing from making the
test nondeterministic. Revise the existing real-executable test to send just one
signal and retain its graceful exit-0 assertion for each signal.

Register `InspectSignals` in both component `other-modules` lists in
`kiroku-metrics/kiroku-metrics.cabal` and add `app-inspect` to the test suite's
`hs-source-dirs`, keeping its existing `test` directory first. No new package is
needed: both components already depend on `unix`. Document first-signal graceful
shutdown and second-signal exit 130 in `--help` and `docs/user/metrics.md`. Amend
ADR-18 to distinguish graceful cleanup from forced process exit. Correct blanket
binding claims in both guides and ADR-18: fixed ports listen on all interfaces,
`--port 0` on loopback only, and no bind option exists. Update ADR-18's timestamp and
bundle log, and run strict validation after both ADR amendments.


## Concrete Steps

All commands run from the repository root. Enter the repository development shell
first if GHC 9.12.4 and PostgreSQL tools are not already on PATH:

```bash
nix develop --no-write-lock-file
```

The default shell in `nix/haskell.nix` provides the compiler and PostgreSQL tools.
The test runner manages its own migrated databases through
`kiroku-test-support/src/Kiroku/Test/Postgres.hs`; it does not require the manual
server below. The review shell could not run `cabal list-bin` without this setup
because `ghc-9.12.4` was absent from PATH.

```bash
cabal build kiroku-metrics:kiroku-metrics-test kiroku-metrics:kiroku-inspect
cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct \
  --test-options='--match "Cors"'
```

Before milestone 1 the new refusal cases fail because requests pass through; after
it, the CORS group passes. Run the whole package suite at that milestone and again
after the executable changes, expecting every example to pass:

```bash
cabal test kiroku-metrics:kiroku-metrics-test
```

For milestone 3's focused checks, including both standalone library and executable
groups, run:

```bash
cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct \
  --test-options='--match "Kiroku.Metrics.Standalone"'
cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct \
  --test-options='--match "kiroku-inspect"'
```

Place the signal subprocess examples in the existing `kiroku-inspect (executable)`
group so the second command exercises them. The private fixture is launched by
those tests; no timing-dependent manual double-interrupt is needed for acceptance.

Manual check of the user-visible behaviour, with a disposable, already migrated
Kiroku database available. Replace the example URL in both startup commands with
that database's URL; migration instructions are in `docs/user/schema-migrations.md`.
Do not assume the development shell's initialized PostgreSQL cluster has already
been started or migrated:

```bash
DATABASE_URL='postgresql://localhost/kiroku' $(cabal list-bin kiroku-metrics:kiroku-inspect) --port 9091
```

In another shell, a handshake with an `Origin` header must be refused and one without
must succeed:

```bash
curl -sNi --max-time 2 -H 'Origin: http://evil.example' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://127.0.0.1:9091/ws/events | head -1
curl -sNi --max-time 2 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://127.0.0.1:9091/ws/events | head -1
```

```text
HTTP/1.1 403 Forbidden
HTTP/1.1 101 Switching Protocols
```

The successful upgrade leaves a WebSocket open, so the second curl may reach its
two-second timeout after emitting 101. Judge this smoke check by the status line;
the automated socket tests supply the complete handshake and envelope assertions.

Startup failure classes (second command with the first still running):

```bash
DATABASE_URL='postgresql://localhost/kiroku' $(cabal list-bin kiroku-metrics:kiroku-inspect) --port 9091
```

```text
kiroku-inspect: bind failure (details redacted)
```

The second process must exit 1 without a success banner. Stop the first process
with one SIGINT after these checks. Repeat the Origin-bearing upgrade against a
fresh instance configured with `--cors-origin http://evil.example`; it must return
101, confirming the migration mechanism. Use this origin only as a local test value;
deployment examples use the operator's actual page origin.

Bundle validation after the ADR amendment:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix fmt
```


## Validation and Acceptance

Milestone 1 is accepted when disabled middleware refuses every tested Origin-bearing
upgrade before dispatch with the exact 403 envelope and no grants, origin-less
WebSockets still connect, ordinary HTTP/preflight responses remain unchanged, and
the full kiroku-metrics suite passes. Real-server tests must cover refusal on
`/ws/events`, origin-less success and configured-origin success. The bounded manual
check above shows 403 with Origin and 101 without, then 101 with the configured origin.

Milestone 2 is accepted when ADR-16 validates strictly, both guides and the ADR
consistently explain same-origin proxy configuration as well as separate-origin
access, and the changelog contains the breaking migration note and historical
erratum. Existing capabilities codec and endpoint tests must continue to pass:
`cors.enabled` remains a boolean indicating configured origins, with no added field
or changed wire shape.

Milestone 3 is accepted when pure classifier tests cover all four classes and
unrelated IO errors, and executable tests demonstrate the exact redacted `bind`,
`database` and `schema` failure lines, exit 1 and no startup banner. One SIGINT or
SIGTERM still produces graceful exit 0. The shared-handler subprocess fixture must
prove exit 130 within one second after the second signal for all four ordered pairs,
while its finalizer is deliberately blocked. A normal fast exit is not evidence for
this condition. The help, guides and ADR-18 must describe both shutdown modes and
the loopback free port; strict ADR validation and the full package suite must pass
after the final code changes.

Early integration check: the WebSocket client in `StandaloneSpec` (plain `WS.runClient`)
is the representative nonbrowser consumer; it must pass unchanged after milestone 1
before the documentation work starts.


## Idempotence and Recovery

Tests use disposable databases and ports chosen by the existing harness. The
missing-schema case selects an absent schema without dropping or modifying one.
Each signal fixture owns its child process and must terminate and reap it on a
timeout or assertion failure. Manual checks own only the explicitly started server
and must stop it on completion. Tests and documentation validation can be repeated.
If reverting this work, revert the relevant implementation commits and associated
tests/documentation together; doing so restores the open WebSocket default.


## Interfaces and Dependencies

`Kiroku.Metrics.Cors.corsMiddleware :: CorsPolicy -> Middleware` keeps its type;
`corsDisabled` keeps its value, only its documented behaviour on upgrades changes.
`wai-websockets` (`Network.Wai.Handler.WebSockets.isWebSocketsReq`) detects upgrades;
`wai` and `warp` serve; `websockets` is the test client. `Kiroku.Metrics.JSON.errorResponse`
builds the 403 envelope with code `origin_not_allowed`. `Kiroku.Metrics.Standalone`
gains a four-class pure failure classifier and a typed marker for listener setup
IO failures; `runInspect` retains its existing signature and supervised lifetime.
Reuse the existing exported `NotifierStartError`, `StoreError` and
`mapGenericUsageError` interfaces. No dependency bounds change and kiroku-store is
untouched.

The internal `InspectSignals` module exposes a bracketed helper to the executable
and test fixture, taking the first-signal shutdown action and the action to run with
handlers installed. It uses `System.Posix.Signals` and
`System.Posix.Process.exitImmediately` from the existing `unix` dependency.
`System.Exit` supplies `ExitCode`, not `exitImmediately`. The fixture switch is
recognized only by the test executable. Preserve the existing `/capabilities`
`cors.enabled` field and its configuration meaning. The next kiroku-metrics release
target remains 0.4.0.0.


## Revision Notes

2026-10-25: Applied the review findings by grounding startup classification in actual
notifier/pool exceptions, defining shared signal state and blocked-teardown subprocess
acceptance, updating conflicting CORS and signal tests, covering same-origin proxy
migration, and preserving existing CORS discovery. Added the development-shell
prerequisite and bounded manual checks so validation is reproducible. At that revision, implementation
milestones remained pending.
