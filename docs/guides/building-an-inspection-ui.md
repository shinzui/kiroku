# Building an inspection UI

A client for the keiro runtime UI and an independent Kiroku UI consume the same
`kiroku-metrics` surface. Stream history, durable subscription checkpoints, dead
letters and live tails belong to this event store. A store-only adopter can run
`kiroku-inspect`; an application can embed the exported WAI application or runner.
The cohort described here is unreleased. This guide describes its implemented
contract; see the [reference](../user/metrics.md) for complete payloads.

## Start here: discovery

Use a configured base URL, including any mount prefix, and GET its relative
`capabilities` path. For example, a base of `https://ops.example/kiroku/` resolves
`capabilities` to `https://ops.example/kiroku/capabilities`. Avoid leading slashes
when resolving URLs: they discard the prefix. Derive `ws:` or `wss:` from the
base's scheme and retain its path when resolving `ws/events` or `ws/metrics`.

```bash
curl -s http://localhost:9091/capabilities | jq .
```

The response identifies `package` and the compiled `version`, with nine booleans
in `routes`: `metrics`, `prometheus`, `health`, `subscriptions_live`,
`subscriptions_checkpoints`, `dead_letters`, `browse`, `websocket_metrics` and
`websocket_events`. Render the screens those flags support. An available route
can still fail temporarily; discovery reports wiring, not database health.
`cors.enabled` reports whether explicit origins are configured, without revealing
the allowlist. Discovery itself stays available when JSON, Prometheus and
WebSocket delivery are disabled, and performs no store reads.

`process_local` lists `metrics`, `prometheus`, `health`, `subscriptions_live` and
`websocket_metrics`. Label those panels with the answering process. An empty
live registry in a standalone process means that process runs no workers; it
says nothing about workers in other processes. Durable checkpoints and dead
letters remain available after those workers stop.

## Two ways to run the surface

A process already owning a store and collector can bind all providers:

```haskell
import Kiroku.Metrics
import Kiroku.Metrics.Config qualified as Config

let cfg = defaultConfig{Config.port = 9091}
providers <- storeServerProviders cfg metrics store
withMetricsServerWithProviders cfg metrics [postgresPing store] providers $ \server ->
  runApplication server
```

See [collector wiring](../user/metrics.md#wiring-the-collector) for constructing
`metrics` before opening `store`. This mode reports that process's workers.
`defaultServerProviders` supports custom record updates; a custom WebSocket app
must declare `webSocketChannels`. Legacy starters with opaque caller-supplied
apps conservatively declare no channels. The legacy store starter includes
browse/checkpoint/dead-letter reads and both channels, but preserves its original
unconfigured live-registry response.

For a migrated database with no host program:

```bash
DATABASE_URL='postgresql://localhost/kiroku' kiroku-inspect --port 9091 --cors-origin http://localhost:5173
```

```text
kiroku-inspect: connected to schema "kiroku"; listening on port 9091
kiroku-inspect: routes browse=on subscriptions_checkpoints=on dead_letters=on subscriptions_live=on websocket_events=on cors=on
kiroku-inspect: this process runs no subscriptions; /subscriptions, /metrics, and /health reflect only this process
```

The executable opens its own store and collector. It runs no subscriptions and
does not migrate the database. `/subscriptions` returns `[]`, `/metrics` has an
empty `subscriptions` map and readiness checks this connection. Use
`--schema` for an already migrated tenant schema. Options and environment
fallbacks are in the [standalone reference](../user/metrics.md#running-the-standalone-server).

Keiro hosts can compose `combinedAppWithProviders` behind a per-surface prefix,
as requested by `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`.
The host strips its prefix from WAI `pathInfo`; HTTP and WebSocket dispatch use
that relative path. All returned content remains independent of the mount URL.

## Screen to endpoint map

| Screen | Routes |
| --- | --- |
| Stream browser | `GET /streams`, `GET /streams/<name>`, `GET /streams/<name>/events` |
| Category browser | `GET /categories`, `GET /categories/<name>/events`; use `/streams?category=<name>` to browse the category's streams |
| Global history and event detail | `GET /events`, `GET /events/<event_id>` |
| Live tail | WebSocket `/ws/events` |
| Subscription dashboard | `GET /subscription-checkpoints`, `GET /subscriptions`, `GET /subscriptions/<name>/dead-letters` |
| Process health and metrics | `/health/live`, `/health/ready`, `/health`, `/metrics`, `/metrics/prometheus`, WebSocket `/ws/metrics` |

### Browsing history

Start category stream navigation with `/streams?category=orders&limit=100`.
Add `prefix=orders-order_` for a literal name prefix. Names use UTF-8 byte order;
`%` and `_` are literal characters. TypeID names group naturally within a
category and sort in ID-generation order, which does not guarantee event or
commit order. Category enumeration retains database locale order.

```bash
curl -s 'http://localhost:9091/streams?category=orders&limit=10'
curl -s 'http://localhost:9091/events?from=0&limit=100'
```

Pages contain `items`; pass an included `next_cursor` verbatim as the next
request's `from`, keeping the other filters and direction. Absence of the cursor
ends paging. Stream versions and global positions are exclusive cursors; do not
infer a global cursor from per-stream reads, whose `globalPosition` is zero.
Zero selects the beginning forward and newest backward. Encode resource names
as individual path segments, including embedded slashes.

Fan-in event items and event frames add `original_stream_name`, or null when
resolution is unavailable; the original surrogate `originalStreamId` remains.
This follows [ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md).
Pages observe current data without a snapshot spanning requests. Soft-deleted
summaries remain visible; hard-deleted streams disappear. Ordered stream reads
honour truncation; global/category reads retain their existing lifecycle rules.

### Following events and recovering loss

Send `{"type":"subscribe_events"}` to `/ws/events` for live-from-now delivery,
or provide optional `from_position` and `category`:

```json
{"type":"subscribe_events","from_position":42,"category":"orders"}
```

`event_stream_started` acknowledges the selected boundary. Subsequent `event`
frames carry the event object in global-position order. Retain the last known
safe cursor and deduplicate replay/live overlap by event ID and position.
`from_position` replays history before live delivery. Category tails read their
category directly; global tails use a bounded drop-oldest queue.

An `error` with code `event_stream_overflowed` arrives **before** the surviving
batch. Save the pre-notice cursor and mark later live frames as hints while
recovering with `GET /events?from=<saved>&limit=100`, or the category route for a
category view. Do not advance the recovery cursor to a survivor and skip the
missing history. Page to the desired frontier, deduplicate, then resume a tail
from the recovered cursor. Apply the same rule after reconnect. A numeric gap
alone is not evidence of loss: category filters and deleted events can produce
gaps. The safe cursor means ordered coverage of the chosen scope, not consecutive
integers. Push is a hint and polled history is truth, per
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`.

`replay_failed`, `category_read_failed` and `live_decode_failed` terminate the
current tail; the connection can still answer `ping` or accept resubscription.
Repair the cause and resume from the safe cursor. `unsubscribe_events` joins
and releases the tail. The name cache retains at most 4096 names per tail and
performs at most one lookup per batch; it resets when that tail ends.
See the [WebSocket conformance mapping](../user/metrics.md#conformance-with-the-cross-project-websocket-convention).

### Subscription progress and dead letters

Use `/subscription-checkpoints` for cross-process persisted truth. Its
`store_position` and checkpoint rows share one SQL statement snapshot. Merge
`/subscriptions` only as live annotation for the answering process; a stopped
worker disappears there but its durable row remains. Separate polls can see
intervening commits. The equivalent SQL contract is
[`kiroku.subscription_checkpoints_v1`](../user/schema.md#subscription_checkpoints_v1).

Call `store_position - checkpoint_position` a **position distance**, never lag
or exact backlog for a filtered/category/grouped consumer. Inventory is
unpaginated and proportional to row count. Wait for a poll to finish before
starting another.

Dead-letter pages are newest first. Echo their opaque `next_cursor`, rather
than computing it from the position alone. Preserve the stored JSON `reason`,
including unfamiliar variants. A historical member filter can reduce read work;
all-member work scales with member count times page size. Unknown subscription
names return an empty page. Use the event UUID for `/events/<event_id>` detail.

### Process metrics and health

These panels describe this process. `/ws/metrics` pushes a complete `snapshot`
on connect, then periodically; `unsubscribe_metrics` stops pushes and
`subscribe_metrics` requests a fresh snapshot and resumes them. `ping` is valid
in either state. Metrics retain full snapshots rather than deltas. An empty
standalone subscription map is expected. Readiness includes the database ping;
it is not health evidence about workers elsewhere.

## Wire rules a client must honour

Published shapes are frozen and grow additively under
[ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md).
New keys use snake_case; the shipped event keys remain camelCase. Ignore unknown
fields, frames and vocabulary members. Decode Int64 numbers losslessly, including
values greater than 2^53, before converting positions to cursors. Plain
JavaScript `JSON.parse` into `Number` loses precision; converting that rounded
number to `BigInt` afterwards does not restore it. Use a lossless JSON parser
and keep positions as exact integer or decimal-text values throughout the client.

New read routes support GET and HEAD (same status and headers, no HEAD body).
Other methods return 405 with `Allow: GET, HEAD`. Errors use
`{"error":{"code":"…","message":"…","details":{…}}}`; details are optional.
Read the code for behavior and the message for display. Existing metrics/health/
live-registry errors retain their published string bodies. Do not assume every
404 uses the structured envelope.

| Family | Stable codes |
| --- | --- |
| Discovery | `not_found`, `method_not_allowed` |
| Browse | `store_browsing_not_configured`, `store_unavailable`, `stream_not_found`, `event_not_found`, `invalid_event_id`, `invalid_query_parameter` |
| Checkpoints | `checkpoint_inventory_not_configured`, `checkpoint_inventory_unavailable` |
| Dead letters | `dead_letters_not_configured`, `dead_letters_unavailable`, `invalid_query_parameter` |
| Shared new reads | `event_decode_failed`, `store_error`, `method_not_allowed`, `not_found` |
| Browser policy | `origin_not_allowed`, `cors_method_not_allowed`, `invalid_cors_request` |

Known query parameters reject duplicates, signs, malformed UTF-8, missing values
and overflow before a provider call. Unknown parameters are ignored. Page limits
default to 100 and cap at 1000; an embedded host may configure smaller bounds.

## Reaching the server from a browser

For a separate page origin, pass repeatable `--cors-origin` options or configure
`MetricsServerConfig.cors` with validated explicit origins. CORS defaults off.
Credentials require `--cors-allow-credentials` with explicit origins; wildcard
origins are refused. `--no-cors-allow-credentials` overrides an environment True.
A reverse proxy serving page and API from one origin avoids CORS entirely.
Use the configured base URL for both HTTP and WebSocket paths.

## What this surface does not do

It supplies reads and live hints, not retry, redrive, deletion, or other operator
mutations. It serves no static UI assets. There is no authentication, TLS or rate
limiting, consistent with `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7` and the
shared conventions at `mori://shinzui/keiro-ui`,
`docs/architecture/inspection-api-conventions.md` (artifact-level URI pending).
The standalone listener binds all interfaces and has no bind-address option.
Restrict it with a controlled network/firewall or an authenticating TLS proxy;
CORS does not authenticate callers.
