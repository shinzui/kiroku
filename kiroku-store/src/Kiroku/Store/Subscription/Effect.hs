{-# LANGUAGE TypeFamilies #-}

module Kiroku.Store.Subscription.Effect (
    -- * The Subscription effect
    Subscription (..),

    -- * Convenience wrapper
    subscribe,

    -- * Interpreters
    runSubscription,
    runSubscriptionResource,
) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, Limit (..), Persistence (..), UnliftStrategy (..), (:>))
import Effectful.Dispatch.Dynamic (HasCallStack, interpret, localUnliftIO, send)
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, getKirokuStore)
import Kiroku.Store.Subscription qualified as Sub
import Kiroku.Store.Subscription.Types (SubscriptionConfigM (..), SubscriptionHandle)

-- ---------------------------------------------------------------------------
-- Subscription effect
-- ---------------------------------------------------------------------------

{- | The Subscription effect — subscribe to event streams.

This is a higher-order effect: the handler inside the config runs in the
caller's effect monad @m@, which is @Eff localEs@ at the call site.
-}
data Subscription :: Effect where
    Subscribe :: SubscriptionConfigM m -> Subscription m SubscriptionHandle

type instance DispatchOf Subscription = Dynamic

-- ---------------------------------------------------------------------------
-- Convenience wrapper
-- ---------------------------------------------------------------------------

{- | Subscribe to an event stream (effectful API).

The handler inside the config runs in @Eff es@, so it can use any effects
available in the caller's stack.

__Lifecycle note:__ The returned handle must be canceled before the effect
scope exits. The subscription thread captures the effect environment; if the
@Eff@ computation finishes while the thread is still running, the environment
becomes invalid.
-}
subscribe :: (HasCallStack, Subscription :> es) => SubscriptionConfigM (Eff es) -> Eff es SubscriptionHandle
subscribe config = send (Subscribe config)

-- ---------------------------------------------------------------------------
-- Interpreters
-- ---------------------------------------------------------------------------

{- | Interpret Subscription by delegating to the MonadIO-based subscribe.

Uses @ConcUnlift Persistent (Limited 1)@ to convert the @Eff@-based handler
to @IO@ for the async worker thread.
-}
runSubscription ::
    (IOE :> es) =>
    KirokuStore ->
    Eff (Subscription : es) a ->
    Eff es a
runSubscription store = interpret $ \env -> \case
    Subscribe config ->
        localUnliftIO env (ConcUnlift Persistent (Limited 1)) $ \unlift -> do
            let ioConfig = config{handler = \evt -> unlift (handler config evt)}
            Sub.subscribe store ioConfig

-- | Interpret Subscription by reading the store handle from 'KirokuStoreResource'.
runSubscriptionResource ::
    (IOE :> es, KirokuStoreResource :> es) =>
    Eff (Subscription : es) a ->
    Eff es a
runSubscriptionResource action = do
    store <- getKirokuStore
    runSubscription store action
