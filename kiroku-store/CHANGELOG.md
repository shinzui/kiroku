# Changelog

## Unreleased

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
