module Kiroku.Store.Subscription.Stream (
    -- * Plain pull stream
    subscriptionStream,

    -- * Ack-coupled pull stream
    AckItem (..),
    subscriptionAckStream,
)
where

import Control.Concurrent.STM (
    TBQueue,
    TMVar,
    atomically,
    newEmptyTMVarIO,
    newTBQueueIO,
    putTMVar,
    readTBQueue,
    takeTMVar,
    writeTBQueue,
 )
import Data.IORef (atomicModifyIORef', newIORef)
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Subscription (subscribe)
import Kiroku.Store.Subscription.Types (
    SubscriptionConfig,
    SubscriptionConfigM (..),
    SubscriptionHandleM (..),
    SubscriptionResult (..),
 )
import Kiroku.Store.Types (EventId, RecordedEvent (..))
import Numeric.Natural (Natural)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

{- | One ack-coupled item emitted by 'subscriptionAckStream'.

The Kiroku subscription worker enqueues an 'AckItem' for each delivered event and
then __blocks__ until the consumer writes a 'SubscriptionResult' into 'ackReply'.
Only then does the worker act on it (checkpoint on 'Continue'\/'Stop', redeliver
on 'Retry', record-and-advance on 'DeadLetter'). This is what lets a downstream
consumer (the @shibuya-kiroku-adapter@) drive Kiroku's per-event disposition from
its own acknowledgement decision.
-}
data AckItem = AckItem
    { ackEvent :: !RecordedEvent
    -- ^ the delivered event
    , ackAttempt :: !Word
    {- ^ zero-based redelivery count for this event: @0@ on first delivery, @1@
    on the first redelivery after a 'Retry', and so on. Tracked by the bridge
    (the worker redelivers the same event consecutively while retrying).
    -}
    , ackReply :: !(TMVar SubscriptionResult)
    -- ^ one-shot reply the consumer must fill exactly once
    }

{- | Create a pull-based 'Stream' from a kiroku subscription.

A bounded 'TBQueue' sits between kiroku's push-based handler and the
returned Streamly stream. The stream terminates when the underlying
subscription ends or the returned cancel action runs.

The @handler@ field in the provided 'SubscriptionConfig' is ignored —
the bridge provides its own handler.

This is the plain, non-acknowledging bridge: every event is replied 'Continue'
as soon as the consumer pulls it, preserving the original semantics. It is
implemented in terms of 'subscriptionAckStream'; consumers that need to drive
retry\/dead-letter dispositions should use 'subscriptionAckStream' directly.

The config's
'Kiroku.Store.Subscription.Types.eventTypeFilter' is honored: the worker
applies it before the bridge handler runs, so the stream yields only matching
events while the checkpoint still advances past filtered-out ones. The stream's
element type is unchanged ('RecordedEvent') — filtering only removes elements,
it does not reshape them.

The returned cancel action cancels the underlying subscription and
writes the sentinel so any blocked reader wakes up and terminates.
-}
subscriptionStream ::
    KirokuStore ->
    SubscriptionConfig ->
    -- | TBQueue capacity (buffer size for backpressure)
    Natural ->
    IO (Stream IO RecordedEvent, IO ())
subscriptionStream store config bufferSize = do
    (ackStream, cancelAction) <- subscriptionAckStream store config bufferSize
    let stream =
            Stream.mapM
                ( \item -> do
                    atomically (putTMVar (ackReply item) Continue)
                    pure (ackEvent item)
                )
                ackStream
    pure (stream, cancelAction)

{- | Create an ack-coupled pull 'Stream' from a kiroku subscription.

Each emitted 'AckItem' carries a one-shot reply variable; the underlying Kiroku
worker blocks in its handler until the consumer fills 'ackReply' with a
'SubscriptionResult'. The worker then checkpoints, redelivers, dead-letters, or
stops accordingly — so the consumer controls Kiroku checkpointing per event. The
@handler@ field in the provided 'SubscriptionConfig' is ignored; the bridge
installs its own.

The returned cancel action cancels the underlying subscription (interrupting any
worker blocked waiting for a reply) and writes the @Nothing@ sentinel so a
blocked reader wakes up and the stream terminates.
-}
subscriptionAckStream ::
    KirokuStore ->
    SubscriptionConfig ->
    -- | TBQueue capacity (buffer size for backpressure)
    Natural ->
    IO (Stream IO AckItem, IO ())
subscriptionAckStream store config bufferSize = do
    queue <- newTBQueueIO bufferSize
    -- Tracks the previous (eventId, attempt) so a consecutive redelivery of the
    -- same event (the worker's bounded retry) is reported with an incremented
    -- attempt. The worker delivers events one at a time and blocks on the reply,
    -- so there is no concurrent access to this ref.
    attemptRef <- newIORef (Nothing :: Maybe (EventId, Word))

    let bridgeHandler :: RecordedEvent -> IO SubscriptionResult
        bridgeHandler event = do
            attempt <- atomicModifyIORef' attemptRef $ \mPrev ->
                case mPrev of
                    Just (eid, n)
                        | eid == eventId event -> (Just (eid, n + 1), n + 1)
                    _ -> (Just (eventId event, 0), 0)
            reply <- newEmptyTMVarIO
            atomically (writeTBQueue queue (Just (AckItem event attempt reply)))
            atomically (takeTMVar reply)

    let bridgeConfig = config{handler = bridgeHandler}

    subHandle <- subscribe store bridgeConfig

    let cancelAction = do
            cancel subHandle
            atomically (writeTBQueue queue Nothing)

    let step :: () -> IO (Maybe (AckItem, ()))
        step () = do
            mItem <- atomically (readTBQueue queue)
            case mItem of
                Just item -> pure (Just (item, ()))
                Nothing -> pure Nothing

    pure (Stream.unfoldrM step (), cancelAction)
