{- | Transactional combinators that compose a Kiroku event-store
operation with arbitrary additional @hasql-transaction@ work in a
single ACID transaction.

This module is the entry point for callers — most prominently the
@keiro@ projection layer — that need to atomically write to their own
SQL tables in the same transaction as an event append. The current
milestone exposes two levels:

* 'runTransaction' / 'runTransactionNoRetry' — bare escape hatch: run
  an opaque 'Tx.Transaction' against the store's connection pool.

* 'appendToStreamTx' — a 'Tx.Transaction'-flavored single-stream
  append. Useful inside a 'runTransaction' block when the caller
  wants full control over conflict handling.

A higher-level wrapper that combines an append with a caller-supplied
continuation in one transaction will be added in the next milestone.

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

    -- * Append-precondition conflicts
    AppendConflict (..),
    appendConflictToStoreError,
) where

import Control.Monad.IO.Class (MonadIO)
import Data.Time.Clock (UTCTime)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Effect (PreparedEvent, Store (..), appendDispatchTx, buildAppendParams, prepareEvents)
import Kiroku.Store.Error (AppendConflict (..), appendConflictToStoreError, emptyResultConflict)
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

Empty event lists are a programming mistake — see
'Kiroku.Store.Append.appendToStream' for the rationale.
-}
appendToStreamTx ::
    StreamName ->
    ExpectedVersion ->
    [PreparedEvent] ->
    UTCTime ->
    Tx.Transaction (Either AppendConflict AppendResult)
appendToStreamTx sn@(StreamName name) expected prepared now = do
    let params = buildAppendParams name now prepared
    mResult <- appendDispatchTx expected params
    pure $ case mResult of
        Just r -> Right r
        Nothing -> Left (emptyResultConflict sn expected)
