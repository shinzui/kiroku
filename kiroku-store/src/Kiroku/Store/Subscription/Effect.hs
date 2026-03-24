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

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (HasCallStack, interpret_, send)
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, getKirokuStore)
import Kiroku.Store.Subscription qualified as Sub
import Kiroku.Store.Subscription.Types (SubscriptionConfig, SubscriptionHandle)

-- ---------------------------------------------------------------------------
-- Subscription effect
-- ---------------------------------------------------------------------------

-- | The Subscription effect — subscribe to event streams.
data Subscription :: Effect where
    Subscribe :: SubscriptionConfig -> Subscription m SubscriptionHandle

type instance DispatchOf Subscription = Dynamic

-- ---------------------------------------------------------------------------
-- Convenience wrapper
-- ---------------------------------------------------------------------------

-- | Subscribe to an event stream (effectful API).
subscribe :: (HasCallStack, Subscription :> es) => SubscriptionConfig -> Eff es SubscriptionHandle
subscribe config = send (Subscribe config)

-- ---------------------------------------------------------------------------
-- Interpreter
-- ---------------------------------------------------------------------------

-- | Interpret Subscription by delegating to the MonadIO-based subscribe.
runSubscription ::
    (IOE :> es) =>
    KirokuStore ->
    Eff (Subscription : es) a ->
    Eff es a
runSubscription store = interpret_ $ \case
    Subscribe config -> Sub.subscribe store config

-- | Interpret Subscription by reading the store handle from 'KirokuStoreResource'.
runSubscriptionResource ::
    (IOE :> es, KirokuStoreResource :> es) =>
    Eff (Subscription : es) a ->
    Eff es a
runSubscriptionResource action = do
    store <- getKirokuStore
    runSubscription store action
