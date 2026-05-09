{- | Transactional combinators that compose a Kiroku event-store
operation with arbitrary additional @hasql-transaction@ work in a
single ACID transaction.

This module is the entry point for callers — most prominently the
@keiro@ projection layer — that need to atomically write to their own
SQL tables in the same transaction as an event append.

In this milestone the module exposes the bare escape hatch only:

* 'runTransaction' / 'runTransactionNoRetry' — run an opaque
  'Tx.Transaction' against the store's connection pool. Higher-level
  combinators (single-stream append + caller continuation, etc.) layer
  on top in subsequent milestones.

The @-NoRetry@ variant uses
'Hasql.Transaction.Sessions.transactionNoRetry' under the hood; the
default variant uses 'Hasql.Transaction.Sessions.transaction', which
automatically retries the body on PostgreSQL serialization conflicts.
The retry runs the entire @Transaction@ value more than once. This is
safe for pure-SQL bodies (each retry's prior partial work rolls back
inside Postgres before the next attempt begins) but should be considered
when the caller is reasoning about external observability.

Mocking: a mock 'Kiroku.Store.Effect.Store' interpreter cannot
meaningfully execute an opaque 'Tx.Transaction' against in-memory state
and is expected to reject 'Kiroku.Store.Effect.RunTransaction' /
'Kiroku.Store.Effect.RunTransactionNoRetry' at runtime.
-}
module Kiroku.Store.Transaction (
    -- * Bare escape hatch
    runTransaction,
    runTransactionNoRetry,
) where

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Effect (Store (..))

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
