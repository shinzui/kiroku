{- | Kiroku Store — high-performance PostgreSQL event store.

Public API re-exports.

Note: The effectful @subscribe@ wrapper from "Kiroku.Store.Subscription.Effect"
is /not/ re-exported here to avoid a name clash with
"Kiroku.Store.Subscription.subscribe". Import @Kiroku.Store.Subscription.Effect@
explicitly to use the effectful version.
-}
module Kiroku.Store (
    module Kiroku.Store.Types,
    module Kiroku.Store.Connection,
    module Kiroku.Store.Effect,
    module Kiroku.Store.Effect.Resource,
    module Kiroku.Store.Error,
    module Kiroku.Store.Append,
    module Kiroku.Store.Causation,
    module Kiroku.Store.Lifecycle,
    module Kiroku.Store.Link,
    module Kiroku.Store.Read,
    module Kiroku.Store.Settings,
    module Kiroku.Store.Subscription,
    module Kiroku.Store.Transaction,

    -- * Subscription effect (interpreter only — import Effect module for @subscribe@)
    Subscription,
    runSubscription,
    runSubscriptionResource,

    -- * Notifier startup
    NotifierStartError (..),

    -- * Operational events emitted by the store itself
    KirokuEvent (..),
    SubscriptionDbPhase (..),
    SubscriptionStopReason (..),
    SubscriptionGroupContext (..),

    -- * Pool observation types (re-exported from hasql-pool)
    Observation (..),
    ConnectionStatus (..),
    ConnectionReadyForUseReason (..),
    ConnectionTerminationReason (..),
) where

import Hasql.Pool.Observation (ConnectionReadyForUseReason (..), ConnectionStatus (..), ConnectionTerminationReason (..), Observation (..))
import Kiroku.Store.Append
import Kiroku.Store.Causation
import Kiroku.Store.Connection
import Kiroku.Store.Effect
import Kiroku.Store.Effect.Resource
import Kiroku.Store.Error
import Kiroku.Store.Lifecycle
import Kiroku.Store.Link
import Kiroku.Store.Notification (NotifierStartError (..))
import Kiroku.Store.Observability (KirokuEvent (..), SubscriptionDbPhase (..), SubscriptionGroupContext (..), SubscriptionStopReason (..))
import Kiroku.Store.Read
import Kiroku.Store.Settings
import Kiroku.Store.Subscription
import Kiroku.Store.Subscription.Effect (Subscription, runSubscription, runSubscriptionResource)
import Kiroku.Store.Transaction
import Kiroku.Store.Types
