{- | Streamly bridges that turn a push-based subscription into a pull-based
@Stream IO@, with a bounded 'Control.Concurrent.STM.TBQueue' providing
backpressure between the Kiroku worker and a downstream stream consumer.

Two bridges are provided:

  * 'subscriptionStream' — the plain bridge. The bridge handler enqueues each
    event and immediately returns 'Continue', so the worker checkpoints at the
    batch tail independently of whether the downstream consumer has processed
    the event. Use it when the stream is an in-process handoff and per-event
    acknowledgement is not required.
  * 'subscriptionAckStream' — the __ack-coupled__ bridge. Each emitted 'AckItem'
    carries a one-shot reply variable; the bridge handler blocks until the
    consumer replies with a 'SubscriptionResult', and only then does the worker
    checkpoint \/ retry \/ dead-letter. This is the path the
    @shibuya-kiroku-adapter@ builds on so a Shibuya @AckRetry@\/@AckDeadLetter@
    drives a real Kiroku disposition before the checkpoint advances.

Both honour the subscription's worker-side filters
('Kiroku.Store.Subscription.Types.eventTypeFilter' and
'Kiroku.Store.Subscription.Types.selector'): a filtered-out event never reaches
either bridge.

Both streams end normally when the subscription worker stops cleanly or is
cancelled. If the worker dies for any other reason, the next stream pull
rethrows the worker's exception to the stream consumer.
-}
module Kiroku.Store.Subscription.Stream (
    -- * Plain pull stream
    subscriptionStream,

    -- * Ack-coupled pull stream
    AckItem (..),
    InvalidStreamBufferSize (..),
    subscriptionAckStream,
)
where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (
    STM,
    TBQueue,
    TMVar,
    TVar,
    atomically,
    newEmptyTMVarIO,
    newTBQueueIO,
    newTVarIO,
    orElse,
    putTMVar,
    readTBQueue,
    readTVar,
    retry,
    takeTMVar,
    writeTBQueue,
    writeTVar,
 )
import Control.Exception (Exception, SomeException, fromException, throwIO)
import Control.Monad (when)
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

{- | Thrown by 'subscriptionAckStream' when the requested bridge queue capacity
is zero.

A zero-capacity 'TBQueue' would make the bridge handler block forever on its
first delivery, before a stream consumer can ever see the event or reply to it.
-}
newtype InvalidStreamBufferSize = InvalidStreamBufferSize Natural
    deriving stock (Eq, Show)
    deriving anyclass (Exception)

data BridgeTermination
    = BridgeClosedCleanly
    | BridgeCrashed !SomeException

closeBridge :: TVar (Maybe BridgeTermination) -> BridgeTermination -> STM ()
closeBridge closedVar termination =
    readTVar closedVar >>= \case
        Nothing -> writeTVar closedVar (Just termination)
        Just _ -> pure ()

{- | Create a pull-based 'Stream' from a kiroku subscription.

A bounded 'TBQueue' sits between kiroku's push-based handler and the
returned Streamly stream. The stream terminates normally when the underlying
subscription stops cleanly or the returned cancel action runs. If the
underlying worker crashes, the next stream pull rethrows the worker exception
to the consumer.

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

The returned cancel action cancels the underlying subscription and wakes any
blocked reader without writing to the bounded queue.
-}
subscriptionStream ::
    KirokuStore ->
    SubscriptionConfig ->
    -- | TBQueue capacity for the bridge; must be at least 1.
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
worker blocked waiting for a reply) and wakes any blocked reader without
writing to the bounded queue. A clean worker stop or cancellation ends the
stream normally; any other worker exception is rethrown from the next stream
pull. This includes overflow, handler exceptions, dead-letter database errors,
and decode-hook exceptions.
-}
subscriptionAckStream ::
    KirokuStore ->
    SubscriptionConfig ->
    -- | TBQueue capacity for the bridge; must be at least 1.
    Natural ->
    IO (Stream IO AckItem, IO ())
subscriptionAckStream store config bufferSize = do
    when (bufferSize < 1) $
        throwIO (InvalidStreamBufferSize bufferSize)
    queue <- newTBQueueIO bufferSize
    closedVar <- newTVarIO Nothing
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
            atomically (writeTBQueue queue (AckItem event attempt reply))
            atomically (takeTMVar reply)

    let bridgeConfig = config{handler = bridgeHandler}

    subHandle <- subscribe store bridgeConfig
    _monitor <- Async.async $ do
        outcome <- wait subHandle
        atomically . closeBridge closedVar $ case outcome of
            Right () -> BridgeClosedCleanly
            Left e
                | Just Async.AsyncCancelled <- fromException e -> BridgeClosedCleanly
                | otherwise -> BridgeCrashed e

    let cancelAction = do
            cancel subHandle
            atomically (closeBridge closedVar BridgeClosedCleanly)

    let step :: () -> IO (Maybe (AckItem, ()))
        step () = do
            next <-
                atomically $
                    (Right <$> readTBQueue queue)
                        `orElse` (readTVar closedVar >>= maybe retry (pure . Left))
            case next of
                Right item -> pure (Just (item, ()))
                Left BridgeClosedCleanly -> pure Nothing
                Left (BridgeCrashed e) -> throwIO e

    pure (Stream.unfoldrM step (), cancelAction)
