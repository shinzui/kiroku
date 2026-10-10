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
        let cfg = defaultKirokuAdapterConfig (SubscriptionName \"my-projection\") AllStreams
        adapter <- kirokuAdapter store cfg

        let handler ingested = do
                -- process ingested.envelope.payload :: RecordedEvent
                pure AckOk

        Right appHandle <- runApp defaultAppConfig
            [(ProcessorId \"my-projection\", kirokuProcessor adapter handler)]

        waitApp appHandle
@

== Consumer-Group Example (size 4)

A consumer group splits one logical subscription across @N@ members. Each
originating stream is deterministically assigned to exactly one member (by a
hash computed in PostgreSQL), so same-stream events stay ordered while distinct
streams are processed in parallel. To run a whole group in one process, use
'kirokuConsumerGroupProcessors': one call yields @N@ named processors, each a
member adapter pinned to the group-level @('PartitionedInOrder', 'Serial')@
policy — no manual @[0..N-1]@ wiring.

@
main :: IO ()
main = withStore settings $ \\store ->
    runEff $ runTracingNoop $ do
        groupSize <- either (fail . show) pure (mkConsumerGroupSize 4)
        let cfg = defaultConsumerGroupConfig
                (SubscriptionName \"orders-projection\")
                (Category (CategoryName \"orders\"))
                groupSize

        Right processors <- kirokuConsumerGroupProcessors store cfg handler
        Right appHandle <- runApp defaultAppConfig processors
        waitApp appHandle
  where
    handler ingested = do
        -- process ingested.envelope.payload :: RecordedEvent
        pure AckOk
@

To run members across separate processes instead, give each process one
'kirokuAdapter' with its own 'member' index and the same 'subscriptionName'.
Kiroku's per-member checkpoint (keyed by @(subscriptionName, member)@) lets each
process resume from its own position after a restart. Exactly one live process
must own each member index at a time.

== Ack Semantics

The adapter bridges through @kiroku-store@'s __ack-coupled__ stream
('subscriptionAckStream'): for each event the Kiroku worker blocks until the
Shibuya handler's 'AckDecision' is finalized, then acts on it. The handler's
decision therefore drives Kiroku checkpointing per event:

* 'AckOk' — the worker checkpoints past the event (the normal case).
* 'AckRetry' @delay@ — the worker redelivers the /same/ event after @delay@,
  bounded by the subscription's retry policy
  ('Kiroku.Store.Subscription.Types.RetryPolicy', default five attempts); on
  exhaustion the event is dead-lettered with
  'Kiroku.Store.Subscription.Types.DeadLetterMaxAttempts'.
* 'AckDeadLetter' @reason@ — the worker records the event in
  @kiroku.dead_letters@ (with the reason translated to a Kiroku-native
  'Kiroku.Store.Subscription.Types.DeadLetterReason') and atomically advances
  the checkpoint past it.
* 'AckHalt' — cancels the underlying Kiroku subscription (no checkpoint advance,
  so the halting event replays on restart).

The envelope's @attempt@ reports the zero-based redelivery count, so a handler
can observe how many times Kiroku has redelivered an event.

== Backpressure and Handler Exceptions

Because delivery is ack-coupled, the Kiroku subscription worker blocks on each
event until the Shibuya handler finalizes its decision, providing natural
backpressure. The @bufferSize@ field is only the capacity of the bridge queue
between the worker and the Shibuya stream consumer; for this adapter the
effective depth is at most one event because the worker waits for an ack before
delivering the next event, and @bufferSize@ must be at least 1.

The @queueCapacity@ field is the publisher-side burst knob: it is the number of
publisher batches, up to 1000 events each, that can be buffered before Kiroku
pauses this subscriber. The adapter uses Kiroku's lossless @PauseAndResume@
overflow policy, so a paused subscriber catches up from its checkpoint instead
of being killed.

Shibuya's supervised runner converts a synchronous handler exception to an
immediate 'AckRetry' and finalizes it, so the ack-coupled Kiroku worker cannot be
left blocked by an abandoned reply. 'kirokuProcessor' applies the one-second
paced guard for a single processor. 'guardKirokuHandlerWith' remains useful when
the application wants a different exception disposition, and
'kirokuConsumerGroupProcessors' applies the adapter's default guard
automatically. Asynchronous cancellation is never converted into an ack.

Raw consumers of @adapter.source@ must finalize every item. Leaving one pending
blocks delivery and checkpoint advancement. Opt in with a positive
@handlerStallWarnAfter@ to receive advisory store handler-stall events; warnings
never finalize, retry or checkpoint the item. @retryPolicy@ controls total
deliveries independently of the delay chosen by 'AckRetry'.
-}
module Shibuya.Adapter.Kiroku (
    -- * Adapter
    kirokuAdapter,
    kirokuProcessor,
    guardKirokuHandlerWith,
    guardKirokuHandler,

    -- * Configuration
    KirokuAdapterConfig (..),
    defaultKirokuAdapterConfig,

    -- * Consumer-group helpers
    KirokuConsumerGroupConfig (..),
    defaultConsumerGroupConfig,
    consumerGroupPolicy,
    kirokuConsumerGroupProcessors,
    kirokuConsumerGroupProcessorsWith,

    -- * Re-exports from kiroku-store
    SubscriptionName (..),
    SubscriptionTarget (..),
    ConsumerGroup,
    ConsumerGroupSize,
    consumerGroupSizeValue,
    mkConsumerGroupSize,
    mkConsumerGroup,
    member,
    size,
    EventTypeFilter (..),
    MissingCheckpointPolicy (..),
) where

import Control.Exception (SomeException)
import Data.Int (Int32)
import Data.Text qualified as T
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Exception (catchSync)
import GHC.Generics (Generic)
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Subscription.Stream (StreamBufferSize, defaultStreamBufferSize, subscriptionAckStream)
import Kiroku.Store.Subscription.Types (
    ConsumerGroup,
    ConsumerGroupSize,
    EventTypeFilter (..),
    MissingCheckpointPolicy (..),
    SubscriptionConfig,
    SubscriptionName (..),
    SubscriptionResult (..),
    SubscriptionTarget (..),
    consumerGroupSizeValue,
    defaultSubscriptionConfig,
    member,
    mkConsumerGroup,
    mkConsumerGroupSize,
    size,
 )
import Kiroku.Store.Subscription.Types qualified as Sub
import Kiroku.Store.Types (RecordedEvent)
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku.Convert (kirokuEnvelopeAttrs, toIngestedAck)
import Shibuya.Adapter.Kiroku.Internal (acquireAllAndTransfer)
import Shibuya.App (ProcessorId (..), QueueProcessor (..), mkProcessor)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Error (PolicyError (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..), validatePolicy)
import Streamly.Data.Stream qualified as Stream

{- | Configuration for creating a Kiroku adapter.

@subscriptionName@ must be unique across all active subscriptions — it
identifies the checkpoint row in the @subscriptions@ table.

@bufferSize@ is the bridge queue capacity and must be at least 1. With this
ack-coupled adapter the effective depth is at most one event, because the
worker blocks until the handler's decision is finalized.

@queueCapacity@ is the publisher-side burst capacity in batches. When a burst
exceeds it, the adapter relies on Kiroku's default @PauseAndResume@ policy:
Kiroku pauses the subscriber and later resumes losslessly from its checkpoint.
-}
data KirokuAdapterConfig = KirokuAdapterConfig
    { subscriptionName :: !SubscriptionName
    -- ^ Unique subscription identifier (checkpoint key)
    , subscriptionTarget :: !SubscriptionTarget
    -- ^ 'AllStreams' or @'Category' categoryName@
    , batchSize :: !Sub.BatchSize
    -- ^ Events per database fetch during catch-up
    , bufferSize :: !StreamBufferSize
    -- ^ Bridge 'TBQueue' capacity; must be at least 1.
    , retryPolicy :: !Sub.RetryPolicy
    -- ^ Total delivery attempts, default five; each AckRetry chooses its delay.
    , handlerStallWarnAfter :: !(Maybe NominalDiffTime)
    -- ^ Optional positive advisory warning interval, disabled by default.
    , queueCapacity :: !Natural
    {- ^ Publisher-side capacity in batches, where each batch contains up to
    Kiroku's publisher batch size (currently 1000 events). When this fills,
    Kiroku pauses and later resumes the subscriber losslessly.
    -}
    , consumerGroup :: !(Maybe ConsumerGroup)
    {- ^ Optional consumer-group membership for this adapter instance.
    'Nothing' (the default) = ordinary single-consumer subscription.
    @'Just' cg@ (built with 'mkConsumerGroup') = this adapter is
    member @m@ of a group of size @n@, receiving only the events whose
    originating stream hashes to slot @m@ (in global-position order). To run a
    full size-@n@ group, create @n@ adapters with the same 'subscriptionName'
    and distinct 'member' indices, each backed by its own Shibuya processor.

    'mkConsumerGroupSize' and 'mkConsumerGroup' validate this invariant before
    an adapter can be configured.
    -}
    , missingCheckpointPolicy :: !MissingCheckpointPolicy
    {- ^ What the underlying Kiroku worker does when this adapter's exact
    @(subscriptionName, consumer-group member)@ checkpoint row is absent.
    'FromBeginning' is the compatibility default; use 'FromCurrentHead' for a
    future-only processor or 'FailIfMissing' when prior provisioning is
    mandatory. Existing checkpoints always win.
    -}
    , eventTypeFilter :: !EventTypeFilter
    {- ^ Which event types this adapter delivers. Pass 'AllEventTypes' (deliver
    everything) or @'OnlyEventTypes' s@ to receive only events whose type is in
    @s@. Forwarded into the underlying subscription; filtering is worker-side
    (before the ack-coupled bridge), so a filtered-out event never reaches the
    Shibuya handler, is never retried or dead-lettered, and the checkpoint still
    advances past it. 'Shibuya.Adapter.Kiroku.Convert' and the 'AckHandle' are
    unaffected.
    -}
    , selector :: !(Maybe (RecordedEvent -> Bool))
    {- ^ Optional opaque per-event predicate, the escape hatch for filtering this
    adapter's stream on a property 'eventTypeFilter' cannot express (e.g.
    payload, metadata, or correlation\/causation ids). Default 'Nothing' (no
    extra filtering). Forwarded into the underlying subscription and composed
    with 'eventTypeFilter' as a logical AND: an event reaches the Shibuya handler
    only when it passes both. Like 'eventTypeFilter' it is applied worker-side
    before the ack-coupled bridge, so a rejected event is never retried or
    dead-lettered and the checkpoint still advances past it. See
    'Kiroku.Store.Subscription.Types.selector' for when to prefer it over the
    introspectable 'eventTypeFilter'.
    -}
    }
    deriving stock (Generic)

{- | A 'KirokuAdapterConfig' with sensible defaults: @batchSize = Sub.defaultBatchSize@,
@bufferSize = defaultStreamBufferSize@, @queueCapacity = 16@, @consumerGroup = 'Nothing'@
(ordinary single-consumer subscription), @missingCheckpointPolicy =
'FromBeginning'@, @eventTypeFilter = 'AllEventTypes'@
(deliver every type), and @selector = 'Nothing'@ (no extra predicate
filtering). Supply the subscription name and target; override individual fields
with record-update syntax.

Prefer this over a full record literal so that any field added to
'KirokuAdapterConfig' later is inherited at its default automatically:

@
let cfg =
        (defaultKirokuAdapterConfig "my-projection" 'AllStreams')
            { eventTypeFilter = 'OnlyEventTypes' (Set.fromList [EventType "OrderPlaced"]) }
adapter <- kirokuAdapter store cfg
@
-}
defaultKirokuAdapterConfig ::
    SubscriptionName -> SubscriptionTarget -> KirokuAdapterConfig
defaultKirokuAdapterConfig name target =
    KirokuAdapterConfig
        { subscriptionName = name
        , subscriptionTarget = target
        , batchSize = Sub.defaultBatchSize
        , bufferSize = defaultStreamBufferSize
        , retryPolicy = Sub.defaultRetryPolicy
        , handlerStallWarnAfter = Nothing
        , queueCapacity = 16
        , consumerGroup = Nothing
        , missingCheckpointPolicy = FromBeginning
        , eventTypeFilter = AllEventTypes
        , selector = Nothing
        }

{- | Convert any synchronous exception thrown by a Shibuya handler into an
'AckDecision'.

This ensures Shibuya still finalizes the ack. Asynchronous exceptions such as
thread cancellation are not caught.
-}
guardKirokuHandlerWith ::
    (SomeException -> AckDecision) ->
    Handler es msg ->
    Handler es msg
guardKirokuHandlerWith handleException h ingested =
    h ingested `catchSync` (pure . handleException)

{- | Recommended handler guard for this adapter.

A synchronous exception becomes @'AckRetry' ('RetryDelay' 1)@. Kiroku then
redelivers after one second and eventually dead-letters persistent failures
according to the subscription retry policy.
-}
guardKirokuHandler :: Handler es msg -> Handler es msg
guardKirokuHandler = guardKirokuHandlerWith (const (AckRetry (RetryDelay 1)))

{- | Recommended single-processor constructor. Like mkProcessor, defaults to
unordered policy and serial concurrency, with the paced exception guard.
-}
kirokuProcessor :: Adapter es RecordedEvent -> Handler es RecordedEvent -> QueueProcessor es
kirokuProcessor adapter handler = mkProcessor adapter (guardKirokuHandler handler)

{- | Create a Shibuya 'Adapter' backed by a Kiroku subscription.

The adapter:

1. Calls 'subscriptionStream' to start a Kiroku subscription with a
   ack-coupled bounded bridge.
2. Lifts the @Stream IO RecordedEvent@ to @Stream (Eff es)@ via
   @Stream.morphInner liftIO@.
3. Wraps each 'RecordedEvent' into an 'Ingested' value with an
   'Envelope' (mapping event ID → message ID, global position → cursor)
   and an 'AckHandle' whose finalized decision drives Kiroku checkpointing,
   retries, dead-lettering, or halt.

The returned adapter's @shutdown@ action cancels the underlying
subscription and wakes any blocked stream reader. If the subscription worker
dies with an exception, @source@ terminates with that exception.
-}
kirokuAdapter ::
    (IOE :> es) =>
    KirokuStore ->
    KirokuAdapterConfig ->
    Eff es (Adapter es RecordedEvent)
kirokuAdapter store KirokuAdapterConfig{subscriptionName = subName, subscriptionTarget = subTarget, batchSize = bs, bufferSize = buf, queueCapacity = qCap, retryPolicy = attempts, handlerStallWarnAfter = stallWarn, consumerGroup = cg, missingCheckpointPolicy = checkpointPolicy, eventTypeFilter = etf, selector = sel} = do
    -- Build from 'defaultSubscriptionConfig' and override only the non-default
    -- fields. Using the smart constructor (rather than a full record literal)
    -- means any future field added to 'SubscriptionConfigM' is inherited at its
    -- default automatically — e.g. EP-2's 'consumerGroupGuard', left 'False' here.
    let subConfig :: SubscriptionConfig
        subConfig =
            (defaultSubscriptionConfig subName subTarget (\_ -> pure Continue))
                { Sub.batchSize = bs
                , Sub.retryPolicy = attempts
                , Sub.handlerStallWarnAfter = stallWarn
                , Sub.queueCapacity = qCap
                , Sub.consumerGroup = cg
                , Sub.missingCheckpointPolicy = checkpointPolicy
                , Sub.eventTypeFilter = etf
                , Sub.selector = sel
                }

    (ioStream, cancelAction) <- liftIO $ subscriptionAckStream store subConfig buf

    -- The subscription name and consumer-group member are known only here (not on
    -- the RecordedEvent), so thread them into the conversion as OTel attributes
    -- that ride onto Shibuya's per-message span (EP-5 M2).
    let SubscriptionName subNameText = subName
        -- Precompute the constant kiroku.* attributes once per adapter (not per
        -- event): kirokuEnvelopeAttrs builds the base map, and the per-event
        -- conversion only inserts the event type and global position.
        envAttrs =
            kirokuEnvelopeAttrs
                subNameText
                (fmap (fromIntegral . member) cg)
        ingestedStream = fmap (toIngestedAck envAttrs cancelAction) (Stream.morphInner liftIO ioStream)

    pure
        Adapter
            { adapterName = "kiroku"
            , source = ingestedStream
            , shutdown = liftIO cancelAction
            }

{- | Configuration for a whole kiroku consumer group presented as a single
Shibuya partitioned-ordering unit.

Unlike 'KirokuAdapterConfig' (which describes one member), this describes the
__entire__ group: 'groupSize' members of one subscription, each receiving the
streams whose originating-stream hash maps to its slot. Hand to
'kirokuConsumerGroupProcessors' to obtain @groupSize@ ready-to-run Shibuya
processors with no manual @[0..N-1]@ wiring.

@memberConcurrency@ is the per-member concurrency. Because kiroku delivers each
member a single strictly global-position-ordered stream, only 'Serial' honestly
preserves per-stream ordering; any 'Ahead'/'Async' is rejected by
'consumerGroupPolicy' before any subscription opens. The /group/ as a whole is
'PartitionedInOrder' (ordered within each member's partition, parallel across
members).
-}
data KirokuConsumerGroupConfig = KirokuConsumerGroupConfig
    { subscriptionName :: !SubscriptionName
    {- ^ Shared subscription identifier; each member checkpoints under
    @(subscriptionName, member)@.
    -}
    , subscriptionTarget :: !SubscriptionTarget
    {- ^ 'AllStreams' or @'Category' categoryName@ — the same source for every
    member; kiroku partitions it across members in SQL.
    -}
    , groupSize :: !ConsumerGroupSize
    {- ^ @N@ members; must be @>= 1@ (enforced by the underlying
    'mkConsumerGroupSize' at construction).
    -}
    , batchSize :: !Sub.BatchSize
    -- ^ Events per database fetch during catch-up (per member).
    , bufferSize :: !StreamBufferSize
    -- ^ Per-member bridge 'TBQueue' capacity; must be at least 1.
    , retryPolicy :: !Sub.RetryPolicy
    -- ^ Total delivery attempts, default five; each AckRetry chooses its delay.
    , handlerStallWarnAfter :: !(Maybe NominalDiffTime)
    -- ^ Optional positive advisory warning interval, disabled by default.
    , queueCapacity :: !Natural
    {- ^ Per-member publisher-side capacity in batches. When this fills, Kiroku
    pauses and later resumes the member losslessly.
    -}
    , memberConcurrency :: !Concurrency
    -- ^ Per-member concurrency; must be 'Serial' (validated).
    , missingCheckpointPolicy :: !MissingCheckpointPolicy
    {- ^ Missing-checkpoint policy applied independently to every member key.
    Existing member rows always win; a new 'FromCurrentHead' group seeds every
    member at the head each member observes during startup.
    -}
    , eventTypeFilter :: !EventTypeFilter
    {- ^ Event-type filter applied to /every/ member (the same filter on each).
    'AllEventTypes' delivers everything; @'OnlyEventTypes' s@ delivers only the
    named types. Forwarded into each per-member 'KirokuAdapterConfig', so a
    filtered partitioned group behaves like a filtered single subscription:
    filtering is worker-side and per member, the checkpoint still advances past
    filtered events, and the partition's completeness is preserved over the
    delivered types.
    -}
    , selector :: !(Maybe (RecordedEvent -> Bool))
    {- ^ Optional opaque per-event predicate applied to /every/ member (the same
    predicate on each), the escape hatch for filtering a property
    'eventTypeFilter' cannot express. Default 'Nothing'. Forwarded into each
    per-member 'KirokuAdapterConfig' and composed with 'eventTypeFilter' as a
    logical AND, so a selector-filtered partitioned group behaves like a
    selector-filtered single subscription (worker-side, per member, checkpoint
    still advances past rejected events). See
    'Kiroku.Store.Subscription.Types.selector'.
    -}
    }
    deriving stock (Generic)

{- | A 'KirokuConsumerGroupConfig' with sensible defaults: @memberConcurrency =
'Serial'@ (the only legal per-member concurrency), @batchSize = Sub.defaultBatchSize@,
@bufferSize = defaultStreamBufferSize@, @queueCapacity = 16@, @missingCheckpointPolicy =
'FromBeginning'@, @eventTypeFilter = 'AllEventTypes'@
(deliver every type), @selector = 'Nothing'@ (no extra predicate filtering).
Supply the subscription name, target, and group size.
-}
defaultConsumerGroupConfig ::
    SubscriptionName -> SubscriptionTarget -> ConsumerGroupSize -> KirokuConsumerGroupConfig
defaultConsumerGroupConfig name target n =
    KirokuConsumerGroupConfig
        { subscriptionName = name
        , subscriptionTarget = target
        , groupSize = n
        , batchSize = Sub.defaultBatchSize
        , bufferSize = defaultStreamBufferSize
        , retryPolicy = Sub.defaultRetryPolicy
        , handlerStallWarnAfter = Nothing
        , queueCapacity = 16
        , memberConcurrency = Serial
        , missingCheckpointPolicy = FromBeginning
        , eventTypeFilter = AllEventTypes
        , selector = Nothing
        }

{- | Map a requested per-member concurrency onto the group's validated Shibuya
@('OrderingPolicy', 'Concurrency')@.

The group's ordering contract is always 'PartitionedInOrder'; a member's own
ordered stream must be processed serially. This reuses Shibuya's own
'validatePolicy' rule (@'StrictInOrder' => 'Serial'@) so the adapter never
invents its own legality check: 'Ahead'/'Async' yield
@'Left' ('InvalidPolicyCombo' ...)@ and 'Serial' yields
@'Right' ('PartitionedInOrder', 'Serial')@. The returned
@('PartitionedInOrder', 'Serial')@ also passes 'validatePolicy', so 'runApp'
will not reject it later.
-}
consumerGroupPolicy :: Concurrency -> Either PolicyError (OrderingPolicy, Concurrency)
consumerGroupPolicy conc = do
    -- A member delivers one strictly-ordered stream; only Serial is honest.
    validatePolicy StrictInOrder conc -- rejects Ahead/Async with PolicyError
    pure (PartitionedInOrder, conc)

{- | Present a whole kiroku consumer group as a single 'PartitionedInOrder' unit:
one call yields @groupSize@ named 'QueueProcessor's, each backed by its own
member adapter and each pinned to @('PartitionedInOrder', 'Serial')@.
The supplied handler is wrapped in 'guardKirokuHandler' automatically so a
synchronous handler exception finalizes a retry disposition instead of
abandoning Kiroku's ack reply.

This replaces the manual @mapM mkMemberAdapter [0 .. N-1]@ boilerplate. The
member→policy mapping is validated once up front via 'consumerGroupPolicy'; if
the caller requests a 'memberConcurrency' kiroku cannot honor per member
('Ahead'/'Async'), the result is @'Left' ('InvalidPolicyCombo' ...)@ and __no
kiroku subscription is opened__.

Each processor's 'ProcessorId' is
@\"\<subscriptionName\>-member-\<m\>\"@ so member identity is readable off the id
and two members never collide. The group size is validated by 'mkConsumerGroupSize' at construction.
-}
kirokuConsumerGroupProcessors ::
    (IOE :> es) =>
    KirokuStore ->
    KirokuConsumerGroupConfig ->
    Handler es RecordedEvent ->
    Eff es (Either PolicyError [(ProcessorId, QueueProcessor es)])
kirokuConsumerGroupProcessors store cfg@KirokuConsumerGroupConfig{subscriptionName = subName, subscriptionTarget = subTarget, groupSize = n, batchSize = bs, bufferSize = buf, queueCapacity = qCap, retryPolicy = attempts, handlerStallWarnAfter = stallWarn, missingCheckpointPolicy = checkpointPolicy, eventTypeFilter = etf, selector = sel} handler =
    kirokuConsumerGroupProcessorsWith mkMemberAdapter cfg handler
  where
    mkMemberAdapter m =
        kirokuAdapter
            store
            KirokuAdapterConfig
                { subscriptionName = subName
                , subscriptionTarget = subTarget
                , batchSize = bs
                , bufferSize = buf
                , retryPolicy = attempts
                , handlerStallWarnAfter = stallWarn
                , queueCapacity = qCap
                , consumerGroup = Just (either (error . show) Prelude.id (mkConsumerGroup m n))
                , missingCheckpointPolicy = checkpointPolicy
                , eventTypeFilter = etf
                , selector = sel
                }

{- | Factory-parameterized core for 'kirokuConsumerGroupProcessors'.

This is exported primarily for tests and advanced integration points. It
validates the group configuration, creates each member adapter with the
provided factory, and shuts down already-created adapters if a later factory
call throws before ownership can be returned to the caller.
-}
kirokuConsumerGroupProcessorsWith ::
    (IOE :> es) =>
    (Int32 -> Eff es (Adapter es RecordedEvent)) ->
    KirokuConsumerGroupConfig ->
    Handler es RecordedEvent ->
    Eff es (Either PolicyError [(ProcessorId, QueueProcessor es)])
kirokuConsumerGroupProcessorsWith
    mkMemberAdapter
    KirokuConsumerGroupConfig
        { subscriptionName = subName
        , groupSize = n
        , memberConcurrency = mc
        }
    handler =
        case consumerGroupPolicy mc of
            Left e -> pure (Left e)
            Right (ordering, conc) -> do
                let SubscriptionName name = subName
                acquireAllAndTransfer
                    (consumerGroupSizeValue n)
                    mkMemberAdapter
                    (\Adapter{shutdown = shutdownAction} -> shutdownAction)
                    (\_ _ -> pure ())
                    ( \adapters ->
                        pure . Right $
                            [ let pid = ProcessorId (name <> "-member-" <> T.pack (show m))
                               in (pid, QueueProcessor adapter (guardKirokuHandler handler) ordering conc)
                            | (m, adapter) <- zip [0 .. consumerGroupSizeValue n - 1] adapters
                            ]
                    )
