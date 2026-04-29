module Kiroku.Store.Subscription (
    -- * Subscribe
    subscribe,
    withSubscription,

    -- * Types
    module Kiroku.Store.Subscription.Types,
) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically)
import Control.Exception (bracket)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Data.Generics.Labels ()
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Subscription.EventPublisher qualified as Pub
import Kiroku.Store.Subscription.Types
import Kiroku.Store.Subscription.Worker (runWorker)

{- | Start a subscription. Returns a handle for cancellation and waiting.

The subscription spawns a worker thread that:
1. Reads the checkpoint from the database (or starts from position 0).
2. Catches up by querying the database directly until reaching the
   EventPublisher's current position.
3. Switches to live mode, reading events from the EventPublisher's
   broadcast channel.

The returned 'SubscriptionHandle' carries an implicit lifecycle contract:
the worker thread runs until 'cancel' is called or the handler returns 'Stop'.
Forgetting to cancel leaks the thread. Prefer 'withSubscription' for any
non-trivial code path; use the bare 'subscribe' only when the caller already
has a structured lifecycle (e.g., the Streamly 'subscriptionStream' bridge).
-}
subscribe :: (MonadIO m) => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle
subscribe store config = liftIO $ do
    liveChan <- atomically $ Pub.subscribePublisher (store ^. #publisher)
    let pubPosVar = Pub.lastPublished (store ^. #publisher)
    thread <-
        Async.async $
            runWorker (store ^. #pool) (store ^. #schema) liveChan pubPosVar config
    pure
        SubscriptionHandle
            { cancel = Async.cancel thread
            , wait = Async.waitCatch thread
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
