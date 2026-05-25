# Changelog

## Unreleased

### Fixed — Category/consumer-group live subscriptions busy-spinning (plan 37)

* Live `Category` subscriptions and consumer-group members no longer busy-spin
  when idle while other categories/partitions advance the global `$all`
  position. `Category` subscriptions now wake from a per-category NOTIFY signal
  (the Notifier previously discarded the notification payload), so an idle
  category does zero DB work; consumer-group members now gate on the last
  observed global position instead of the per-category cursor. Delivery and
  checkpoint semantics are unchanged. See
  `docs/plans/37-fix-category-subscription-live-loop-busy-spin.md`.

### Added

* `KirokuEventSubscriptionFetched` observability event (per live DB-driven
  fetch), exposing per-subscription live-fetch activity.

## 0.1.0.0 — 2026-05-23

### Changed — migrations own schema lifecycle

* `kiroku-store` no longer embeds schema SQL or runs DDL during `withStore`.
  Apply `kiroku-store-migrations` before opening the store. This removes the
  duplicated bootstrap path between the runtime package and the migration
  package.
* Removed `Kiroku.Store.Schema`, `SchemaInitialization`,
  `InitializeSchemaOnAcquire`, `SkipSchemaInitialization`, and
  `ConnectionSettingsM.schemaInitialization`.

### Added — `lookupStreamNames` / `lookupStreamName` (plan 36)

* `Kiroku.Store.Read.lookupStreamNames :: [StreamId] -> Eff es (Map StreamId
  StreamName)` resolves a batch of surrogate stream ids to their names in a
  single round trip (and `lookupStreamName :: StreamId -> Eff es (Maybe
  StreamName)` for one). This is the inverse of `lookupStreamId` and the
  supported way to recover the source stream name from a `RecordedEvent`'s
  `originalStreamId` on fan-in reads — `$all`, categories,
  causation/correlation queries, and subscriptions — which carry only the
  surrogate id.
* Chosen over carrying a `originalStreamName` field on every `RecordedEvent`:
  benchmarking showed returning the name on every read row costs ~13% on
  `$all` 100-event pages (decoding ~100 extra `text` values per page), whether
  the name came from a join or a denormalized column. The lookup API keeps the
  read hot path at its prior latency and makes consumers pay only when, and
  only as much as, they actually need names (one round trip per batch for the
  distinct ids). See `docs/plans/36-add-originalstreamname-to-recordedevent.md`.

* A fresh installation now creates and uses a dedicated `kiroku` PostgreSQL
  schema instead of installing into `public`. The
  `kiroku-store-migrations` bootstrap creates the schema and sets
  `search_path` first, and every pooled connection runs
  `SET search_path TO "<schema>", pg_catalog` before any statement.
* `defaultConnectionSettings` now defaults `schema = "kiroku"` (was `"public"`).
  The `schema` field is now authoritative for object location, table
  resolution, and the `LISTEN <schema>.events` channel — previously it only
  named the notification channel while table resolution depended on the
  connection-string `search_path`.
* The `kiroku-store-migrations` codd bootstrap installs into `kiroku`; run it
  with `CODD_SCHEMAS=kiroku`. The runtime role needs privileges on the
  `kiroku` schema rather than on `public`.

### Added — consumer groups for partitioned subscriptions (MasterPlan 4, plans 28–31)

* Static, hash-partitioned consumer groups: a named subscription can be split
  across `N` members, each processing a disjoint, per-stream-ordered slice in
  parallel, with per-member checkpoints. Works for `Category` and `$all`
  targets.
* `Kiroku.Store.Subscription.Types` (re-exported from `Kiroku.Store`):
  * `ConsumerGroup { member :: Int32, size :: Int32 }` — static membership
    descriptor. A stream is assigned to member
    `(((hashtextextended(stream_id::text, 0) % size) + size) % size)`.
  * Two new fields on `SubscriptionConfigM m`: `consumerGroup :: Maybe
    ConsumerGroup` (default `Nothing`) and `consumerGroupGuard :: Bool`
    (default `False`, an opt-in startup advisory-lock conflict probe).
    `defaultSubscriptionConfig` sets both defaults, so existing callers compile
    unchanged.
  * Exceptions `InvalidConsumerGroup` (thrown by `subscribe` when `size < 1` or
    `member` is out of range) and `ConsumerGroupGuardConflict` (thrown at
    startup when the guard detects a duplicate member).
* `subscriptions` table gains `consumer_group_member` and `consumer_group_size`
  columns; the checkpoint key becomes the composite unique
  `(subscription_name, consumer_group_member)` (index
  `ix_subscriptions_name_member`). The change is applied by the migration
  package.
* The four `KirokuEventSubscription*` observability events carry a trailing
  `SubscriptionGroupContext` (`NonGroup` | `GroupMember member size`),
  re-exported from `Kiroku.Store`.
* Surfaced through every subscription entry point: the `MonadIO`
  `subscribe`/`withSubscription`, the effectful `Subscription` effect, the
  Streamly `subscriptionStream` bridge, and the Shibuya adapter
  (`KirokuAdapterConfig` gains `consumerGroup :: Maybe ConsumerGroup`).
* New user guide `docs/user/consumer-groups.md` and a runnable example,
  `cabal run kiroku-store:kiroku-consumer-group-example`.

### Added — causation chain and correlation walkers (plan 14)

* `Kiroku.Store.Causation` (new module, re-exported from `Kiroku.Store`):
  * `findCausationDescendants :: EventId -> Eff es (Vector RecordedEvent)`
    — walk the causation graph forward from a seed event. Returns the
    seed plus every event whose `causation_id` chain leads back to it,
    in ascending `global_position` order. Backed by the existing partial
    index `ix_events_causation_id`, so cost scales as O(depth · log n)
    against the total event count.
  * `findCausationAncestors :: EventId -> Eff es (Vector RecordedEvent)`
    — symmetric walk in the other direction: returns the seed plus
    every ancestor reachable by following `causation_id` upward, in
    leaf-first depth order. Uses the same index.
  * `findByCorrelation :: UUID -> Eff es (Vector RecordedEvent)` — return
    every event whose `correlation_id` equals the input, in ascending
    `global_position` order. Backed by `ix_events_correlation_id`.
* `Kiroku.Store.Effect.Store` gains a single new constructor
  `FindEvents :: EventFilter -> Store m (Vector RecordedEvent)` whose
  argument is a closed sum (`Kiroku.Store.Types.EventFilter` —
  `FilterCorrelation`, `FilterCausationDescendants`, `FilterCausationAncestors`).
  The closed-sum shape preserves exhaustiveness checking for downstream
  mock interpreters.
* The new reads honor `StoreSettings.decodeHook`, so any interpreter-level
  decode customization wired through `ConnectionSettings` applies on
  parity with `readStreamForward` / `readAllForward` / `readCategory`.

### Added — interpreter-level event-data hooks (plan 13)

* `Kiroku.Store.Settings` (new module, re-exported from `Kiroku.Store`):
  * `StoreSettings { enrichEvent :: Maybe (EventData -> IO EventData),
    decodeHook :: Maybe (RecordedEvent -> IO RecordedEvent) }` — optional
    interpreter-level hooks. `enrichEvent` runs on the append path before
    encoding (on the typed `EventData` the caller supplied); `decodeHook`
    runs on the read and subscription paths after decoding (on the typed
    `RecordedEvent` about to be surfaced). Both default to `Nothing`,
    taking a `pure` fast path that adds no traversal or allocation when
    the hook is absent.
  * `defaultStoreSettings` — both fields `Nothing` (no-op).
  * `enrichEvents :: StoreSettings -> [EventData] -> IO [EventData]` and
    `decodeEvents :: StoreSettings -> Vector RecordedEvent -> IO (Vector
    RecordedEvent)` — internal helpers reused by the interpreter, the
    subscription publisher, the subscription worker, and the new
    `enrichEventsIO` convenience.
* `Kiroku.Store.Connection.ConnectionSettings` and
  `Kiroku.Store.Connection.KirokuStore` gain a `storeSettings ::
  StoreSettings` field. `defaultConnectionSettings` seeds it with
  `defaultStoreSettings` so existing callers see no behaviour change.
  `withStore` copies the value onto the runtime handle for the
  interpreter, the publisher, and the worker to read.
* `Kiroku.Store.Transaction`:
  * `runTransactionAppendingResource` /
    `runTransactionAppendingResourceNoRetry` — hook-aware variants of
    `runTransactionAppending` / `runTransactionAppendingNoRetry` for
    callers running under a `KirokuStoreResource` effect. They apply
    `enrichEvent` to every `EventData` before opening the transaction.
  * `enrichEventsIO :: KirokuStore -> [EventData] -> IO [EventData]` —
    public convenience for direct callers of `appendToStreamTx`, who
    bypass the interpreter.

A typical use case is enriching every appended event with an
OpenTelemetry trace context:

```haskell
storeSettings = defaultStoreSettings
  { enrichEvent = Just $ \ed -> do
      ctx <- captureCurrentSpan
      pure (ed & #metadata %~ injectTraceContext ctx)
  }
```

Wired through `ConnectionSettings`'s `storeSettings` field, the hook
fires uniformly across `appendToStream`, `appendMultiStream`,
`runTransactionAppendingResource`, every read path, and the
subscription pipeline (live + catch-up).

### Added — streaming single-stream forward read

* `Kiroku.Store.Read.readStreamForwardStream` (re-exported from
  `Kiroku.Store`): a Streamly `Stream (Eff es) RecordedEvent` companion to
  `readStreamForward`. Internally paginates `readStreamForward` at a
  caller-supplied page size and yields events one at a time, enabling
  constant-memory folds over long streams. Shares SQL path and error
  semantics with `readStreamForward`.

### Added — single-stream `RunTransaction` combinator (plan 11)

* `Kiroku.Store.Transaction` (new module, re-exported from
  `Kiroku.Store`):
  * `runTransaction` / `runTransactionNoRetry` — bare escape hatch for
    running an arbitrary `Hasql.Transaction.Transaction a` against the
    store's connection pool. The default variant retries the body on
    PostgreSQL serialization conflicts; the `-NoRetry` variant runs
    exactly once. Both execute at `ReadCommitted` isolation in `Write`
    mode.
  * `appendToStreamTx :: StreamName -> ExpectedVersion ->
    [PreparedEvent] -> UTCTime -> Tx.Transaction (Either AppendConflict
    AppendResult)` — the `Tx`-flavored single-stream append building
    block. Useful inside a `runTransaction` block when the caller needs
    full control over conflict handling. Does not enforce reserved-stream
    rejection; pair with `prepareEventsIO` for UUIDv7 / `createdAt`
    prep.
  * `runTransactionAppending` /
    `runTransactionAppendingNoRetry` — recommended high-level wrapper
    for the `keiro` use case. Atomically composes a single-stream append
    with a caller-supplied `Tx.Transaction` continuation. Rejects `$all`
    up front, `Tx.condemn`s on append conflicts (the continuation never
    runs), and surfaces both conflict and connection failures through
    the `Either StoreError` return type. Carries `IOE :> es` in addition
    to `Store :> es`.
* `Kiroku.Store.Effect`:
  * New `Store` constructors `RunTransaction` and
    `RunTransactionNoRetry`. Mock interpreters are expected to reject
    these.
  * Internal building blocks `PreparedEvent`, `prepareEvents`,
    `buildAppendParams`, and `appendDispatchTx` are now exported (under
    the `$internal` haddock group) to support
    `Kiroku.Store.Transaction`. Not part of the supported public
    surface.
* `Kiroku.Store.Error`:
  * `AppendConflict` — sum of append-precondition failures observable
    inside a `Tx.Transaction` body
    (`WrongExpectedVersionConflict` / `StreamNotFoundConflict` /
    `StreamAlreadyExistsConflict`). 1:1 with the corresponding
    `StoreError` constructors.
  * `appendConflictToStoreError`, `emptyResultConflict` — supporting
    pure helpers.

### Changed

* `appendMultiStream`'s interpreter now dispatches per-stream appends
  through the shared `appendDispatchTx` helper. Behavior is unchanged.
* `appendToStream`'s haddock now describes when to reach for
  `runTransactionAppending` instead.
