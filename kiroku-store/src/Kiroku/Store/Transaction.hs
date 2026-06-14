{- | Transactional combinators that compose a Kiroku event-store
operation with arbitrary additional @hasql-transaction@ work in a
single ACID transaction.

This module is the entry point for callers — most prominently the
@keiro@ projection layer — that need to atomically write to their own
SQL tables in the same transaction as an event append. Three ergonomic
levels are provided:

* 'runTransaction' / 'runTransactionNoRetry' — bare escape hatch: run
  an opaque 'Tx.Transaction' against the store's connection pool.

* 'appendToStreamTx' — a 'Tx.Transaction'-flavored single-stream
  append. Useful inside a 'runTransaction' block when the caller
  wants full control over conflict handling.

* 'runTransactionAppending' / 'runTransactionAppendingNoRetry' — the
  recommended high-level wrapper that combines a single-stream append
  with the caller's 'Tx.Transaction' continuation in one atomic
  transaction. This is the primary API for @keiro@-style projection
  consumers.

The @-NoRetry@ variants use
'Hasql.Transaction.Sessions.transactionNoRetry' under the hood; the
default variants use 'Hasql.Transaction.Sessions.transaction', which
automatically retries the body on PostgreSQL serialization conflicts.
The retry runs the entire 'Tx.Transaction' value more than once. This
is safe for pure-SQL bodies (each retry's prior partial work rolls back
inside Postgres before the next attempt begins) but should be
considered when the caller reasons about external observability.

Mocking: a mock 'Kiroku.Store.Effect.Store' interpreter cannot
meaningfully execute an opaque 'Tx.Transaction' against in-memory state
and is expected to reject 'Kiroku.Store.Effect.RunTransaction' /
'Kiroku.Store.Effect.RunTransactionNoRetry' at runtime.
-}
module Kiroku.Store.Transaction (
    -- * Bare escape hatch
    runTransaction,
    runTransactionNoRetry,

    -- * Tx-flavored append building block
    appendToStreamTx,
    PreparedEvent,
    prepareEventsIO,

    -- * Convenience wrapper for the keiro use case
    runTransactionAppending,
    runTransactionAppendingNoRetry,
    runTransactionAppendingResource,
    runTransactionAppendingResourceNoRetry,

    -- * Manual enrichment for direct 'appendToStreamTx' callers
    enrichEventsIO,

    -- * Append-precondition conflicts
    AppendConflict (..),
    appendConflictToStoreError,
) where

import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Functor (($>))
import Data.Generics.Labels ()
import Data.Time.Clock (UTCTime, getCurrentTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (PreparedEvent, Store (..), appendDispatchTx, buildAppendParams, prepareEvents)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, getKirokuStore)
import Kiroku.Store.Error (AppendConflict (..), StoreError (..), appendConflictToStoreError, emptyResultConflict)
import Kiroku.Store.Settings qualified as Settings
import Kiroku.Store.Types

{- | Run an arbitrary 'Tx.Transaction' against the store's connection
pool inside a 'BEGIN'/'COMMIT' block.

The body may run /more than once/ if PostgreSQL raises a serialization
conflict — automatic retry is the default behavior of
'Hasql.Transaction.Sessions.transaction'. Use 'runTransactionNoRetry'
when retry is unacceptable (for example, the caller has been promised
exactly-once semantics that an outside observer of intermediate state
could break).

The body executes at 'Hasql.Transaction.Sessions.ReadCommitted'
isolation in 'Hasql.Transaction.Sessions.Write' mode, mirroring the
existing transactional sites in 'Kiroku.Store.Append.appendMultiStream'
and the hard-delete path.

Errors: a hasql 'Hasql.Pool.UsageError' is translated to
'Kiroku.Store.Error.ConnectionError'. Calling 'Tx.condemn' inside the
body marks the transaction for rollback at commit; the call returns the
final value the body produced, but no SQL writes from this transaction
will be visible. Mock interpreters of 'Store' reject this constructor.
-}
runTransaction ::
    (HasCallStack, Store :> es) =>
    Tx.Transaction a ->
    Eff es a
runTransaction tx = send (RunTransaction tx)

{- | Like 'runTransaction' but uses
'Hasql.Transaction.Sessions.transactionNoRetry' — the body is executed
exactly once even on PostgreSQL serialization conflicts. A conflict
surfaces as 'Kiroku.Store.Error.ConnectionError' carrying the underlying
'Hasql.Pool.UsageError'.
-}
runTransactionNoRetry ::
    (HasCallStack, Store :> es) =>
    Tx.Transaction a ->
    Eff es a
runTransactionNoRetry tx = send (RunTransactionNoRetry tx)

-- ---------------------------------------------------------------------------
-- Tx-flavored append
-- ---------------------------------------------------------------------------

{- | Generate UUIDv7s for any 'EventData' lacking a caller-supplied
'eventId' and return the prepared list, ready to feed into
'appendToStreamTx' inside a 'Tx.Transaction'.

'Tx.Transaction' has no 'MonadIO' instance, so UUID generation must
happen /before/ the transaction body runs. This helper is the IO-side
preparation step paired with 'appendToStreamTx'.
-}
prepareEventsIO :: (MonadIO m) => [EventData] -> m [PreparedEvent]
prepareEventsIO = prepareEvents

{- | Append a batch of events to a single stream as part of a larger
'Tx.Transaction'.

The 'Tx.Transaction'-flavored counterpart to
'Kiroku.Store.Append.appendToStream'. It does /not/ enforce the @$all@
reserved-stream check — callers should validate the stream name before
entering the transaction body, or use 'runTransactionAppending', which
performs the rejection up front.

The combinator returns 'Either' instead of throwing because
'Tx.Transaction' has no exception channel. On 'Left' the caller decides
whether to call 'Tx.condemn' to roll back the transaction, branch
around the conflict, or commit (which would persist the rest of the
transaction body without the append).

The events list must be pre-prepared via 'prepareEventsIO' (which
generates UUIDv7s) and the @createdAt@ timestamp must be captured by
the caller prior to entering the transaction body.

Empty event lists are a programming mistake. This function returns
@'Left' ('EmptyAppendBatchConflict' …)@ without dispatching a statement;
the high-level @runTransactionAppending*@ wrappers return
@'Left' ('EmptyAppendBatch' …)@ before opening a transaction.
-}
appendToStreamTx ::
    StreamName ->
    ExpectedVersion ->
    [PreparedEvent] ->
    UTCTime ->
    Tx.Transaction (Either AppendConflict AppendResult)
appendToStreamTx sn@(StreamName name) expected prepared now = do
    case prepared of
        [] ->
            pure (Left (EmptyAppendBatchConflict sn))
        _ -> do
            let params = buildAppendParams name now prepared
            mResult <- appendDispatchTx expected params
            pure $ case mResult of
                Just r -> Right r
                Nothing -> Left (emptyResultConflict sn expected)

-- ---------------------------------------------------------------------------
-- Convenience wrapper
-- ---------------------------------------------------------------------------

{- | Append events to a single stream and run an arbitrary
'Tx.Transaction' continuation in one ACID transaction.

This is the recommended API for callers who want to combine an event
append with their own SQL writes (canonical example: a projection row
that must land iff the append commits).

Behavior:

* If the target stream is the reserved @$all@, the call rejects with
  @'Left' ('ReservedStreamName' …)@ /before/ opening any transaction;
  the continuation is not invoked.
* If the event list is empty, the call rejects with
  @'Left' ('EmptyAppendBatch' …)@ /before/ opening any transaction; the
  continuation is not invoked.
* UUIDv7 ids are generated for events with a 'Nothing' 'eventId', and
  the current time is captured, before the transaction begins
  ('Tx.Transaction' has no 'MonadIO' so this prep cannot happen
  inside).
* Inside the transaction, 'appendToStreamTx' is called. On 'Left'
  (version conflict, missing stream, etc.), the transaction is
  'Tx.condemn'-ed, the continuation is /not/ run, and the call returns
  @'Left' storeErr@.
* On 'Right' the continuation runs with the resulting 'AppendResult'.
  If the continuation calls 'Tx.condemn', the transaction rolls back
  at commit time and no writes — including the event append — are
  visible.
* The transaction body may execute more than once if PostgreSQL raises
  a serialization conflict; use 'runTransactionAppendingNoRetry' to
  disable retry.

Connection-level failures from the @hasql-pool@ layer surface through
the surrounding @'Effectful.Error.Static.Error' 'StoreError'@ effect
('Kiroku.Store.Error.ConnectionError', 'ConnectionLost', etc.), not
through the returned 'Either' — that 'Either' is reserved for semantic
append-precondition conflicts (and the up-front reserved-stream
rejection).

This wrapper does /not/ apply the
'Kiroku.Store.Settings.enrichEvent' hook, because resolving the
'StoreSettings' requires reaching the live 'KirokuStore' handle and the
constraint set here is intentionally minimal. Callers running on a
'Kiroku.Store.Effect.Resource.KirokuStoreResource'-flavored stack and
wanting the hook should use 'runTransactionAppendingResource'; callers
on a bare stack can call 'enrichEventsIO' explicitly before invoking
this wrapper.
-}
runTransactionAppending ::
    (HasCallStack, IOE :> es, Store :> es) =>
    StreamName ->
    ExpectedVersion ->
    [EventData] ->
    (AppendResult -> Tx.Transaction a) ->
    Eff es (Either StoreError a)
runTransactionAppending = runTransactionAppendingWith RunTransaction

{- | Like 'runTransactionAppending' but uses
'Hasql.Transaction.Sessions.transactionNoRetry' under the hood — the
transaction body runs exactly once even on PostgreSQL serialization
conflicts.

Like 'runTransactionAppending', this wrapper bypasses the
'Kiroku.Store.Settings.enrichEvent' hook; see that function's
Haddock for guidance on hooking under different stacks.
-}
runTransactionAppendingNoRetry ::
    (HasCallStack, IOE :> es, Store :> es) =>
    StreamName ->
    ExpectedVersion ->
    [EventData] ->
    (AppendResult -> Tx.Transaction a) ->
    Eff es (Either StoreError a)
runTransactionAppendingNoRetry = runTransactionAppendingWith RunTransactionNoRetry

{- | Hook-aware variant of 'runTransactionAppending' for callers running
under a 'Kiroku.Store.Effect.Resource.KirokuStoreResource' effect.

Behaves exactly like 'runTransactionAppending' except that the
'Kiroku.Store.Settings.enrichEvent' hook (if any) is applied to every
'EventData' before the transaction body opens. The hook fires in
'IO', /outside/ the transaction; subsequent retries of a serialization
conflict do not re-invoke it (the enriched events are already prepared).

This is the recommended path for callers — most prominently the
@keiro@ projection layer — that want trace-context or PII-injection
hooks to fire uniformly across both direct @'appendToStream'@ calls
and transactional append+projection sites.
-}
runTransactionAppendingResource ::
    (HasCallStack, IOE :> es, KirokuStoreResource :> es, Store :> es) =>
    StreamName ->
    ExpectedVersion ->
    [EventData] ->
    (AppendResult -> Tx.Transaction a) ->
    Eff es (Either StoreError a)
runTransactionAppendingResource sn expected events k = do
    store <- getKirokuStore
    events' <- liftIO $ enrichEventsIO store events
    runTransactionAppendingWith RunTransaction sn expected events' k

{- | Like 'runTransactionAppendingResource' but uses
'Hasql.Transaction.Sessions.transactionNoRetry' under the hood.
-}
runTransactionAppendingResourceNoRetry ::
    (HasCallStack, IOE :> es, KirokuStoreResource :> es, Store :> es) =>
    StreamName ->
    ExpectedVersion ->
    [EventData] ->
    (AppendResult -> Tx.Transaction a) ->
    Eff es (Either StoreError a)
runTransactionAppendingResourceNoRetry sn expected events k = do
    store <- getKirokuStore
    events' <- liftIO $ enrichEventsIO store events
    runTransactionAppendingWith RunTransactionNoRetry sn expected events' k

{- | Apply the store's 'Kiroku.Store.Settings.enrichEvent' hook (if any)
to a list of 'EventData' values.

Use this when calling 'appendToStreamTx' directly — that lower-level
API does not see the interpreter and therefore does not run the hook
on its own. Calling 'enrichEventsIO' yourself before
'prepareEventsIO' restores hook coverage for that path.

When 'Kiroku.Store.Settings.enrichEvent' is 'Nothing' the function
returns the input list unchanged with no traversal.
-}
enrichEventsIO :: KirokuStore -> [EventData] -> IO [EventData]
enrichEventsIO store = Settings.enrichEvents (store ^. #storeSettings)

{- | Shared implementation for 'runTransactionAppending' and
'runTransactionAppendingNoRetry'. The only difference between the
two wrappers is which 'Store' constructor is sent.
-}
runTransactionAppendingWith ::
    (IOE :> es, Store :> es) =>
    (forall x. Tx.Transaction x -> Store (Eff es) x) ->
    StreamName ->
    ExpectedVersion ->
    [EventData] ->
    (AppendResult -> Tx.Transaction a) ->
    Eff es (Either StoreError a)
runTransactionAppendingWith ctor sn@(StreamName name) expected events k
    | name == "$all" = pure (Left (ReservedStreamName sn))
    | null events = pure (Left (EmptyAppendBatch sn))
    | otherwise = do
        prepared <- prepareEventsIO events
        now <- liftIO getCurrentTime
        let body = do
                outcome <- appendToStreamTx sn expected prepared now
                case outcome of
                    Left conflict ->
                        Tx.condemn $> Left (appendConflictToStoreError conflict)
                    Right ar ->
                        Right <$> k ar
        send (ctor body)
