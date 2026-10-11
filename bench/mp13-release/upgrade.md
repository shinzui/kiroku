# Kiroku 0.10.0.0 to 0.11.0.0: inspection cohort

Establish direct package usage and database ownership before editing. A project
without direct usage or an affected database should report this edge inapplicable
and succeed. Resolve dependency source through Mori. Keep changes within this
edge, and preserve the typed-decoding changes already required by 0.10.

The cohort versions are store 0.11.0.0, migrations 0.7.1.0, metrics 0.3.0.0,
CLI 0.2.0.10, OTel 0.2.0.12 and adapter 0.6.0.1. Update direct bounds in every
library, executable, example and test stanza. The last three packages change
their store bound without changing their public APIs. Metrics requires the new
CLI patch. Resolve and build before claiming the selected versions.

Search exhaustive custom `Store` interpreters for all four new constructors:
`ListStreams`, `ListCategories`, `GetEvent`, `ListSubscriptionDeadLetters`.
Implement their read behavior or an explicit typed refusal; do not add a catch-all
that conceals future constructors. `Subscriber` complete record construction must
now supply `subDropped :: TVar Word64`, initialized to zero. The legacy
`subscribePublisher` triple remains; `subscribePublisherWith` exposes the counter
and idempotent deregistration. Preserve `DecodedBatch` and typed decode failures.

`MetricsServerConfig` complete or positional construction must supply `cors`;
prefer `defaultConfig` updates, with `corsDisabled` unless browser access is
intended. Validate explicit origins with `allowedOrigin`. Qualify configuration
record labels under umbrella imports. Handle new `UnsubscribeMetrics` and
`CodedError` constructors in exhaustive protocol matches. Existing starter
signatures and published wire keys remain. New composition uses
`defaultServerProviders` updates; full construction supplies `webSocketServer`,
`subscriptionStatus`, `checkpointInventory`, `storeBrowsing`, `deadLetters`, and
`webSocketChannels`. Explicitly declare custom WebSocket channels for discovery.

`/subscription-checkpoints` is the durable inventory path;
`/subscriptions/checkpoints` can still name a live subscription. Discover wiring
at `/capabilities`. Event objects add `original_stream_name`, which may be null.
Tail error codes are `replay_failed`, `category_read_failed`,
`live_decode_failed`, and `event_stream_overflowed`. On overflow, recover from
the last contiguous position before the notice, using REST; notifications are
hints and durable polling is truth. New read routes support GET/HEAD and
structured errors. Stream-name cursors use UTF-8 byte order and must be echoed
verbatim. Inventory is unpaginated: avoid overlapping polls.

The metrics package now installs `kiroku-inspect`; it needs a migrated database
and runs no subscriptions. Empty live metrics/registry describe only that
process. The listener binds all interfaces; use a controlled network or an
authenticating proxy. CORS is browser policy. The UI is not served by this binary.
Run `kiroku-inspect --help` and a disposable database smoke check before adopting it.

Classify the database with read-only evidence before prescribing migration 0015.
It adds `ix_streams_browse_name`, one partial C-collated name index, retaining
identity/category/event indexes and all existing data. Its transactional CREATE
INDEX can block writes, so operators should back up, rehearse on a restored
clone, and schedule a write pause/maintenance window. Apply the owning migration
runner from migrations 0.7.1.0; never rewrite the ledger or hand-copy SQL.
Old writers remain schema-compatible with this additive index, but new browsing
requires it. Do not apply a migration to a database containing real data from
this edge. Disposable, unshared databases may follow their normal rebuild path.

Build and run the consuming project's tests. Verify capability truth, CORS,
mounted paths, event names and clean shutdown where those interfaces are used.
Report exact selected versions, edits, tests and unverified database work.
