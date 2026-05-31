module Kiroku.Store.Subscription (
    -- * Subscribe
    subscribe,
    withSubscription,

    -- * Observability
    subscriptionStates,
    SubscriptionStateView (..),

    -- * Types
    module Kiroku.Store.Subscription.Types,
) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (bracket, finally, throwIO)
import Control.Lens ((^.))
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Unique (newUnique)
import GHC.Generics (Generic)
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Notification qualified as Notifier
import Kiroku.Store.Subscription.EventPublisher qualified as Pub
import Kiroku.Store.Subscription.Fsm (SubscriptionState (..), stateCursor, stateName)
import Kiroku.Store.Subscription.Types
import Kiroku.Store.Subscription.Worker (configMember, runWorker)
import Kiroku.Store.Types (GlobalPosition (..))

{- | Start a subscription. Returns a handle for cancellation and waiting.

The subscription spawns a worker thread that:

1. Reads the checkpoint from the database (or starts from global position 0
   for a fresh subscription name).
2. Catches up by querying the database directly until it reaches the
   'Kiroku.Store.Subscription.EventPublisher.lastPublished' cursor.
3. Switches to live mode. For 'Kiroku.Store.Subscription.Types.AllStreams'
   subscriptions, the worker reads pre-broadcast events from the
   publisher's bounded per-subscriber queue. For
   'Kiroku.Store.Subscription.Types.Category' subscriptions, the worker
   bypasses the broadcast entirely and re-queries the database with the
   SQL category filter whenever 'lastPublished' advances.

The returned 'SubscriptionHandle' carries an implicit lifecycle contract:
the worker thread runs until 'cancel' is called or the handler returns 'Stop'.
Forgetting to cancel leaks the thread. Prefer 'withSubscription' for any
non-trivial code path; use the bare 'subscribe' only when the caller already
has a structured lifecycle (e.g., the Streamly 'subscriptionStream' bridge).

=== Delivery semantics

Events are delivered __at least once__. The store's checkpoint is advanced
__per batch__, not per event: when the handler returns 'Continue' for every
event in a batch the checkpoint is saved at the batch tail; when the handler
returns 'Stop' for some event the checkpoint is saved at that event. The
following events on the boundary therefore __replay__ on the next
subscription with the same 'Kiroku.Store.Subscription.Types.SubscriptionName':

* The handler returned 'Continue' but the worker was cancelled or the
  process crashed before 'saveCheckpoint' completed. The events processed
  by the handler are re-delivered.
* The handler was interrupted between events (cancellation, crash) inside
  one batch. The events already processed are re-delivered along with the
  not-yet-processed ones.
* The publisher could not reach the database for one cycle (transient
  pool error). The next cycle re-fetches and re-broadcasts; subscribers
  that had already exited catch-up may see those events delivered late
  with no checkpoint advance in between, so a subsequent restart replays
  them.

Handlers must therefore be idempotent — process a duplicate event without
producing a wrong-on-replay result — or be tolerant of duplicates by some
domain-specific check (e.g., a unique key on the projection table).

=== Failure modes

The 'Kiroku.Store.Subscription.Types.SubscriptionHandleM.wait' on the
returned handle resolves with one of:

* @Right ()@ — the handler returned 'Stop' for some event and the worker
  exited cleanly. The checkpoint is saved at that event.
* @Left e@ where @e@ is 'Control.Concurrent.Async.AsyncCancelled' — the
  caller invoked 'cancel'. No checkpoint advance is guaranteed; events
  in flight at cancellation time will replay.
* @Left e@ where @e@ is
  'Kiroku.Store.Subscription.Types.SubscriptionOverflowed' — the publisher
  marked this subscription overflowed under
  'Kiroku.Store.Subscription.Types.DropSubscription'. Investigate the
  slow handler and either fix the slowness, raise 'queueCapacity', or
  switch to 'Kiroku.Store.Subscription.Types.DropOldest' if the consumer
  can tolerate event loss.
* @Left e@ for any exception thrown by the handler — handler exceptions
  are not caught; the worker thread dies and the original exception
  propagates to the consumer. This is intentional: a handler that
  throws is signalling that the subscription cannot proceed safely.
-}
subscribe :: (MonadIO m) => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle
subscribe store config = liftIO $ do
    -- Fail fast on a misconfigured group, before any thread is spawned. A bad
    -- (member, size) is a programmer error; throwing here keeps subscribe's
    -- non-Either signature intact for every existing caller (see EP-2 Decision Log).
    for_ (consumerGroup config) $ \(ConsumerGroup m n) ->
        when (n < 1 || m < 0 || m >= n) $
            throwIO (InvalidConsumerGroup m n)
    (queue, statusVar, unsubscribe) <-
        atomically $
            Pub.subscribePublisher
                (store ^. #publisher)
                (queueCapacity config)
                (overflowPolicy config)
    -- The worker writes its current FSM state here on every transition; the
    -- handle's 'currentState' reads it. Seeded with the catch-up entry state so
    -- a read before the worker's first transition is sensible.
    stateVar <- newTVarIO (CatchingUp (GlobalPosition 0) 0)
    let pubPosVar = Pub.lastPublished (store ^. #publisher)
        catGenVar = Notifier.categoryGenerations (store ^. #notifier)
    -- Register this worker's state cell into the store's central registry under
    -- (name, member). A fresh token identifies *this* worker so that an older
    -- worker's cleanup cannot delete a newer worker's replacement entry under
    -- the same key, and a held handle reads only the cell it registered.
    token <- newUnique
    let reg = store ^. #subscriptionRegistry
        key = (name config, configMember config)
        -- `finally unsubscribe` removes this subscription from the publisher's
        -- registry whenever the worker exits — gracefully on Stop, by
        -- cancellation, or on any exception (including SubscriptionOverflowed).
        -- Forgetting to unsubscribe would leave a registry entry with no
        -- reader, and the publisher would needlessly trigger this subscriber's
        -- overflow policy on the next batch. We extend the same `finally` to
        -- also deregister from the subscription-state registry on ANY exit, so
        -- the registry never leaks a stale entry. The delete is
        -- token-conditional so stale cleanup from an older duplicate-key worker
        -- cannot remove a newer worker's live entry.
        cleanup =
            unsubscribe
                >> atomically
                    ( modifyTVar' reg $
                        Map.update
                            ( \(tok', cell) ->
                                if tok' == token
                                    then Nothing
                                    else Just (tok', cell)
                            )
                            key
                    )
    -- Insert before forking so a caller that reads a snapshot immediately after
    -- `subscribe` returns already sees this subscription.
    atomically $ modifyTVar' reg (Map.insert key (token, stateVar))
    thread <-
        Async.async
            ( runWorker (store ^. #pool) queue statusVar stateVar pubPosVar catGenVar config (store ^. #eventHandler) (store ^. #storeSettings)
                `finally` cleanup
            )
    pure
        SubscriptionHandle
            { cancel = Async.cancel thread
            , wait = Async.waitCatch thread
            , currentState = do
                m <- readTVarIO reg
                case Map.lookup key m of
                    Just (tok, cell) | tok == token -> Just <$> readTVarIO cell
                    _ -> pure Nothing
            }

{- | Bracket-style subscription lifecycle.

Starts a subscription, runs the body, and ensures the underlying worker
thread is cancelled on either normal exit or an exception thrown inside
the body. This is the recommended way to use subscriptions: forgetting
to call 'cancel' on a 'SubscriptionHandle' leaks the worker thread for
the lifetime of the process.

Equivalent to:

    bracket (subscribe store config) cancel action

but lifted to any 'MonadUnliftIO' so it composes with effectful stacks
that already have an unlift in scope.
-}
withSubscription ::
    (MonadUnliftIO m) =>
    KirokuStore ->
    SubscriptionConfig ->
    (SubscriptionHandle -> m a) ->
    m a
withSubscription store config action = withRunInIO $ \runInIO ->
    bracket (subscribe store config) cancel (runInIO . action)

{- | A public, point-in-time view of one live subscription's state, as returned
by 'subscriptionStates'. This is the committed observability surface external
consumers (a future Prometheus exporter, an admin tool) read directly; it is
intentionally a flat view, not the internal 'SubscriptionState' cell type.

* 'subscriptionName' / 'member' identify the subscription (member 0 for a
  non-group subscription), matching the registry/checkpoint key.
* 'state' is the live 'SubscriptionState' read from the worker's registered cell.
* 'statePhase' is a stable, low-cardinality label (via
  'Kiroku.Store.Subscription.Fsm.stateName') suitable as a metric label value or
  admin column; it does not drift if a constructor's fields change.
* 'cursor' is the worker FSM cursor (via 'Kiroku.Store.Subscription.Fsm.stateCursor').
  It is the cheap live progress signal for observability, not a guaranteed
  durable checkpoint row.

Read fields via the codebase's @generic-lens@ convention, e.g. @view ^. #state@.
-}
data SubscriptionStateView = SubscriptionStateView
    { subscriptionName :: !SubscriptionName
    , member :: !Int32
    , state :: !SubscriptionState
    , statePhase :: !Text
    , cursor :: !GlobalPosition
    }
    deriving stock (Show, Generic)

{- | A near-instant snapshot of every live subscription as a public
'SubscriptionStateView', keyed by (subscription name, consumer-group member;
0 for non-group).

Snapshots the registry's outer map with 'readTVarIO', then reads each registered
state cell with 'readTVarIO' __outside__ STM. This is deliberately not one STM
transaction over all cells: a single transaction would put every subscription's
state cell in the reader's STM read set, and since each worker writes its cell
~once per batch, any such write would force the whole scan to re-run — a
reader-side cost that scales with subscription count. The named consumers (a
Prometheus scrape, an admin listing) read independent values and do not need a
globally atomic snapshot, so each entry is read as its own freshest value.

A subscription appears here from the moment 'subscribe' returns its handle until
its worker exits (stop, cancel, or crash), at which point its key is removed; a
stopped/cancelled/crashed subscription is represented by __absence__, never by a
@"stopped"@ phase (the FSM never writes 'Stopped' into the cell). This map of
view records is the committed surface the future Prometheus exporter and admin
tool consume.
-}
subscriptionStates :: KirokuStore -> IO (Map (SubscriptionName, Int32) SubscriptionStateView)
subscriptionStates store = do
    cells <- readTVarIO (store ^. #subscriptionRegistry)
    Map.traverseWithKey
        ( \(nm, mbr) (_tok, cell) -> do
            st <- readTVarIO cell
            pure
                SubscriptionStateView
                    { subscriptionName = nm
                    , member = mbr
                    , state = st
                    , statePhase = stateName st
                    , cursor = stateCursor st
                    }
        )
        cells
