module Kiroku.Store.Append (
    appendToStream,
    appendMultiStream,
) where

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Types

{- | Append a batch of events to a single stream under the given
'ExpectedVersion' precondition.

When to use this vs.
'Kiroku.Store.Transaction.runTransactionAppending':

* Reach for 'appendToStream' by default. It is the cheapest path —
  one CTE on a pool connection, no Haskell-layer @BEGIN@/@COMMIT@
  envelope, no caller-driven retry semantics to reason about.
* Reach for 'Kiroku.Store.Transaction.runTransactionAppending' /only/
  when you need to atomically combine the append with additional SQL
  writes that the store doesn't perform (most prominently a
  projection-row insert from a downstream projection table). The
  wrapper opens an explicit 'BEGIN'/'COMMIT', enables PostgreSQL
  serialization-conflict retry of the entire body by default, and
  threads the caller's continuation into the same transaction.

Semantics:

* If the precondition fails, the entire batch is rejected — appends are
  all-or-nothing per call.
* On success, events are visible to subsequent reads on /this/ store
  handle (read-your-own-writes is guaranteed). Other store handles see
  the events after their pool connection's transaction-visibility
  horizon advances.
* The returned 'AppendResult' carries the position of the /last/ event
  in the batch.

Idempotent retries: supply 'Kiroku.Store.Types.EventData.eventId' yourself
and retry on transient failures. A retry whose previous attempt actually
committed surfaces as 'Kiroku.Store.Error.DuplicateEvent' (when the
events_pkey detail is parseable). A retry that observed
'Kiroku.Store.Error.WrongExpectedVersion' on an 'ExactVersion' append
should be treated as ambiguous: either a concurrent writer raced you or
your previous attempt succeeded; the recovery in both cases is to
re-read the stream and decide.

Errors (all variants of 'Kiroku.Store.Error.StoreError'):

* 'Kiroku.Store.Error.WrongExpectedVersion' — 'ExactVersion' mismatch.
* 'Kiroku.Store.Error.StreamNotFound' — 'StreamExists' against a missing
  or soft-deleted stream.
* 'Kiroku.Store.Error.ReservedStreamName' — the target is @$all@, which
  is the global read stream and cannot be appended as an application
  stream.
* 'Kiroku.Store.Error.StreamAlreadyExists' — 'NoStream' against an
  existing stream (including soft-deleted).
* 'Kiroku.Store.Error.DuplicateEvent' — caller-supplied 'eventId'
  collides with an existing event.

Empty event lists: passing @[]@ is a programming mistake. The
underlying CTE returns 0 rows, which the interpreter maps to a
constructor that depends on the supplied 'ExpectedVersion'
('Kiroku.Store.Error.WrongExpectedVersion' for 'ExactVersion',
'Kiroku.Store.Error.StreamNotFound' for 'StreamExists', and so on).
None of these is the caller's intent; reject the call yourself before
invoking the API.
-}
appendToStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    ExpectedVersion ->
    [EventData] ->
    Eff es AppendResult
appendToStream name expected events = send (AppendToStream name expected events)

{- | Atomically append events to multiple streams in a single
transaction.

Either every per-stream append succeeds or all of them roll back —
there is no partial-commit state. The interpreter pre-locks the named
streams in deterministic @stream_id@ order to avoid deadlocks when two
concurrent multi-stream calls touch overlapping streams in different
user orders.

@$all@ is reserved for the global read stream. If any operation targets
@$all@, the whole call is rejected before opening the transaction with
'Kiroku.Store.Error.ReservedStreamName'.

Per-stream errors are attributed to the stream that caused them: the
@Right results@ branch of the interpreter iterates the input list and
maps each empty CTE result back to the corresponding @(StreamName,
ExpectedVersion)@. Errors raised as PostgreSQL exceptions are
attributed via 'Kiroku.Store.Error.attributeMultiStreamError', which
parses the server-error detail for the offending stream name when
possible; the latent misattribution path (a future schema change that
introduces a constraint violation visible to the client) is covered
defensively.

The returned list mirrors the input order. Each 'AppendResult' carries
the corresponding stream's final state.

Empty input @[]@ is a no-op programming mistake; do not call.
-}
appendMultiStream ::
    (HasCallStack, Store :> es) =>
    [(StreamName, ExpectedVersion, [EventData])] ->
    Eff es [AppendResult]
appendMultiStream ops = send (AppendMultiStream ops)
