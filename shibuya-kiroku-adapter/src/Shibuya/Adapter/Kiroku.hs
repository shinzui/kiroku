{- | Kiroku event store adapter for the Shibuya queue processing framework.

This adapter wraps Kiroku's push-based subscriptions into Shibuya's
pull-based 'Adapter' interface. Events are bridged through a bounded
'TBQueue' (via @kiroku-store@'s 'subscriptionStream') and lifted into the
effectful stack with @Stream.morphInner@.

== Example

@
import Effectful (runEff)
import Kiroku.Store (withStore, defaultConnectionSettings)
import Shibuya.Adapter.Kiroku
import Shibuya.App
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)

main :: IO ()
main = withStore settings $ \\store ->
    runEff $ runTracingNoop $ do
        adapter <- kirokuAdapter store
            KirokuAdapterConfig
                { subscriptionName = SubscriptionName \"my-projection\"
                , subscriptionTarget = AllStreams
                , batchSize = 100
                , bufferSize = 256
                }

        let handler ingested = do
                -- process ingested.envelope.payload :: RecordedEvent
                pure AckOk

        Right appHandle <- runApp IgnoreFailures 100
            [(ProcessorId \"my-projection\", mkProcessor adapter handler)]

        waitApp appHandle
@

== Ack Semantics

Kiroku subscriptions are fundamentally different from message queues:
events are immutable and persistent, and checkpoint advancement is managed
internally by the subscription worker.

* 'AckOk' — no-op (the normal case; checkpoint advances automatically).
* 'AckRetry' — no-op (events cannot be redelivered; they are always available).
* 'AckDeadLetter' — no-op (there is no dead-letter concept for an event log).
* 'AckHalt' — cancels the underlying Kiroku subscription.

== Backpressure

The @bufferSize@ field in 'KirokuAdapterConfig' controls the 'TBQueue'
capacity. When the queue is full, the Kiroku subscription worker blocks
until the Shibuya handler drains events, providing natural backpressure.
-}
module Shibuya.Adapter.Kiroku (
    -- * Adapter
    kirokuAdapter,

    -- * Configuration
    KirokuAdapterConfig (..),

    -- * Re-exports from kiroku-store
    SubscriptionName (..),
    SubscriptionTarget (..),
) where

import Data.Int (Int32)
import Effectful (Eff, IOE, liftIO, (:>))
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Subscription.Stream (subscriptionStream)
import Kiroku.Store.Subscription.Types (
    SubscriptionConfigM (..),
    SubscriptionName (..),
    SubscriptionResult (..),
    SubscriptionTarget (..),
 )
import Kiroku.Store.Types (RecordedEvent)
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku.Convert (toIngested)
import Streamly.Data.Stream qualified as Stream

{- | Configuration for creating a Kiroku adapter.

@subscriptionName@ must be unique across all active subscriptions — it
identifies the checkpoint row in the @subscriptions@ table.

@bufferSize@ controls backpressure: the Kiroku worker blocks when the
internal queue is full, throttling database polling to match the handler's
consumption rate.
-}
data KirokuAdapterConfig = KirokuAdapterConfig
    { subscriptionName :: !SubscriptionName
    -- ^ Unique subscription identifier (checkpoint key)
    , subscriptionTarget :: !SubscriptionTarget
    -- ^ 'AllStreams' or @'Category' categoryName@
    , batchSize :: !Int32
    -- ^ Events per database fetch during catch-up
    , bufferSize :: !Natural
    -- ^ TBQueue capacity (backpressure threshold)
    }

{- | Create a Shibuya 'Adapter' backed by a Kiroku subscription.

The adapter:

1. Calls 'subscriptionStream' to start a Kiroku subscription with a
   bounded 'TBQueue' bridge.
2. Lifts the @Stream IO RecordedEvent@ to @Stream (Eff es)@ via
   @Stream.morphInner liftIO@.
3. Wraps each 'RecordedEvent' into an 'Ingested' value with an
   'Envelope' (mapping event ID → message ID, global position → cursor)
   and a no-op 'AckHandle' (except 'AckHalt' which cancels the
   subscription).

The returned adapter's @shutdown@ action cancels the underlying
subscription and flushes the sentinel through the queue so any
blocked stream reader terminates.
-}
kirokuAdapter ::
    (IOE :> es) =>
    KirokuStore ->
    KirokuAdapterConfig ->
    Eff es (Adapter es RecordedEvent)
kirokuAdapter store (KirokuAdapterConfig subName subTarget bs buf) = do
    let subConfig =
            SubscriptionConfig
                { name = subName
                , target = subTarget
                , handler = \_ -> pure Continue
                , batchSize = bs
                }

    (ioStream, cancelAction) <- liftIO $ subscriptionStream store subConfig buf

    let ingestedStream = fmap (toIngested cancelAction) (Stream.morphInner liftIO ioStream)

    pure
        Adapter
            { adapterName = "kiroku"
            , source = ingestedStream
            , shutdown = liftIO cancelAction
            }
