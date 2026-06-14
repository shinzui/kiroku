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

        Right appHandle <- runApp IgnoreFailures 100
            [(ProcessorId \"my-projection\", mkProcessor adapter handler)]

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
        let cfg = defaultConsumerGroupConfig
                (SubscriptionName \"orders-projection\")
                (Category (CategoryName \"orders\"))
                4   -- group size

        Right processors <- kirokuConsumerGroupProcessors store cfg handler
        Right appHandle <- runApp IgnoreFailures 100 processors
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

A Shibuya handler used with this adapter must not let synchronous exceptions
escape. Shibuya's supervised runner records handler exceptions without
finalizing the ack; with Kiroku's ack-coupled bridge, an unfinalized ack blocks
the Kiroku worker forever. Direct 'mkProcessor' users should wrap handlers in
'guardKirokuHandler' or handle exceptions themselves.
'kirokuConsumerGroupProcessors' applies 'guardKirokuHandler' automatically.
-}
module Shibuya.Adapter.Kiroku (
    -- * Adapter
    kirokuAdapter,
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

    -- * Re-exports from kiroku-store
    SubscriptionName (..),
    SubscriptionTarget (..),
    ConsumerGroup (..),
    EventTypeFilter (..),
) where

import Control.Exception (SomeException)
import Data.Int (Int32)
import Data.Text qualified as T
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Exception (catchSync)
import GHC.Generics (Generic)
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Subscription.Stream (subscriptionAckStream)
import Kiroku.Store.Subscription.Types (
    ConsumerGroup (..),
    EventTypeFilter (..),
    SubscriptionConfig,
    SubscriptionName (..),
    SubscriptionResult (..),
    SubscriptionTarget (..),
    defaultSubscriptionConfig,
 )
import Kiroku.Store.Subscription.Types qualified as Sub
import Kiroku.Store.Types (RecordedEvent)
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku.Convert (kirokuEnvelopeAttrs, toIngestedAck)
import Shibuya.App (ProcessorId (..), QueueProcessor (..))
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Error (PolicyError (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), Ordering (..), validatePolicy)
import Streamly.Data.Stream qualified as Stream
import Prelude hiding (Ordering)

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
    , batchSize :: !Int32
    -- ^ Events per database fetch during catch-up
    , bufferSize :: !Natural
    -- ^ Bridge 'TBQueue' capacity; must be at least 1.
    , queueCapacity :: !Natural
    {- ^ Publisher-side capacity in batches, where each batch contains up to
    Kiroku's publisher batch size (currently 1000 events). When this fills,
    Kiroku pauses and later resumes the subscriber losslessly.
    -}
    , consumerGroup :: !(Maybe ConsumerGroup)
    {- ^ Optional consumer-group membership for this adapter instance.
    'Nothing' (the default) = ordinary single-consumer subscription.
    @'Just' ('ConsumerGroup' { member = m, size = n })@ = this adapter is
    member @m@ of a group of size @n@, receiving only the events whose
    originating stream hashes to slot @m@ (in global-position order). To run a
    full size-@n@ group, create @n@ adapters with the same 'subscriptionName'
    and distinct 'member' indices, each backed by its own Shibuya processor.

    The validity invariant (@size >= 1@, @0 <= member < size@) is enforced by
    the underlying 'Kiroku.Store.Subscription.subscribe' call, which throws
    'Kiroku.Store.Subscription.Types.InvalidConsumerGroup' on violation.
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

{- | A 'KirokuAdapterConfig' with sensible defaults: @batchSize = 100@,
@bufferSize = 256@, @queueCapacity = 16@, @consumerGroup = 'Nothing'@
(ordinary single-consumer subscription), @eventTypeFilter = 'AllEventTypes'@
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
        , batchSize = 100
        , bufferSize = 256
        , queueCapacity = 16
        , consumerGroup = Nothing
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
guardKirokuHandlerWith onException h ingested =
    h ingested `catchSync` (pure . onException)

{- | Recommended handler guard for this adapter.

A synchronous exception becomes @'AckRetry' ('RetryDelay' 1)@. Kiroku then
redelivers after one second and eventually dead-letters persistent failures
according to the subscription retry policy.
-}
guardKirokuHandler :: Handler es msg -> Handler es msg
guardKirokuHandler = guardKirokuHandlerWith (const (AckRetry (RetryDelay 1)))

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
kirokuAdapter store KirokuAdapterConfig{subscriptionName = subName, subscriptionTarget = subTarget, batchSize = bs, bufferSize = buf, queueCapacity = qCap, consumerGroup = cg, eventTypeFilter = etf, selector = sel} = do
    -- Build from 'defaultSubscriptionConfig' and override only the non-default
    -- fields. Using the smart constructor (rather than a full record literal)
    -- means any future field added to 'SubscriptionConfigM' is inherited at its
    -- default automatically — e.g. EP-2's 'consumerGroupGuard', left 'False' here.
    let subConfig :: SubscriptionConfig
        subConfig =
            (defaultSubscriptionConfig subName subTarget (\_ -> pure Continue))
                { Sub.batchSize = bs
                , Sub.queueCapacity = qCap
                , Sub.consumerGroup = cg
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
                (fmap (\ConsumerGroup{member = m} -> fromIntegral m) cg)
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
    , groupSize :: !Int32
    {- ^ @N@ members; must be @>= 1@ (enforced by the underlying
    'Kiroku.Store.Subscription.subscribe', which throws
    'Kiroku.Store.Subscription.Types.InvalidConsumerGroup' otherwise).
    -}
    , batchSize :: !Int32
    -- ^ Events per database fetch during catch-up (per member).
    , bufferSize :: !Natural
    -- ^ Per-member bridge 'TBQueue' capacity; must be at least 1.
    , queueCapacity :: !Natural
    {- ^ Per-member publisher-side capacity in batches. When this fills, Kiroku
    pauses and later resumes the member losslessly.
    -}
    , memberConcurrency :: !Concurrency
    -- ^ Per-member concurrency; must be 'Serial' (validated).
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
'Serial'@ (the only legal per-member concurrency), @batchSize = 100@,
@bufferSize = 256@, @queueCapacity = 16@, @eventTypeFilter = 'AllEventTypes'@
(deliver every type), @selector = 'Nothing'@ (no extra predicate filtering).
Supply the subscription name, target, and group size.
-}
defaultConsumerGroupConfig ::
    SubscriptionName -> SubscriptionTarget -> Int32 -> KirokuConsumerGroupConfig
defaultConsumerGroupConfig name target n =
    KirokuConsumerGroupConfig
        { subscriptionName = name
        , subscriptionTarget = target
        , groupSize = n
        , batchSize = 100
        , bufferSize = 256
        , queueCapacity = 16
        , memberConcurrency = Serial
        , eventTypeFilter = AllEventTypes
        , selector = Nothing
        }

{- | Map a requested per-member concurrency onto the group's validated Shibuya
@('Ordering', 'Concurrency')@.

The group's ordering contract is always 'PartitionedInOrder'; a member's own
ordered stream must be processed serially. This reuses Shibuya's own
'validatePolicy' rule (@'StrictInOrder' => 'Serial'@) so the adapter never
invents its own legality check: 'Ahead'/'Async' yield
@'Left' ('InvalidPolicyCombo' ...)@ and 'Serial' yields
@'Right' ('PartitionedInOrder', 'Serial')@. The returned
@('PartitionedInOrder', 'Serial')@ also passes 'validatePolicy', so 'runApp'
will not reject it later.
-}
consumerGroupPolicy :: Concurrency -> Either PolicyError (Ordering, Concurrency)
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
and two members never collide. The group-validity invariant (@groupSize >= 1@,
@0 <= member < groupSize@) is enforced downstream by
'Kiroku.Store.Subscription.subscribe' (throwing
'Kiroku.Store.Subscription.Types.InvalidConsumerGroup'); 'groupSize >= 1' is a
documented precondition of this helper.
-}
kirokuConsumerGroupProcessors ::
    (IOE :> es) =>
    KirokuStore ->
    KirokuConsumerGroupConfig ->
    Handler es RecordedEvent ->
    Eff es (Either PolicyError [(ProcessorId, QueueProcessor es)])
kirokuConsumerGroupProcessors
    store
    KirokuConsumerGroupConfig
        { subscriptionName = subName
        , subscriptionTarget = subTarget
        , groupSize = n
        , batchSize = bs
        , bufferSize = buf
        , queueCapacity = qCap
        , memberConcurrency = mc
        , eventTypeFilter = etf
        , selector = sel
        }
    handler =
        case consumerGroupPolicy mc of
            Left e -> pure (Left e)
            Right (ordering, conc) -> do
                let SubscriptionName name = subName
                processors <-
                    mapM
                        ( \m -> do
                            adapter <-
                                kirokuAdapter
                                    store
                                    KirokuAdapterConfig
                                        { subscriptionName = subName
                                        , subscriptionTarget = subTarget
                                        , batchSize = bs
                                        , bufferSize = buf
                                        , queueCapacity = qCap
                                        , consumerGroup = Just (ConsumerGroup{member = m, size = n})
                                        , eventTypeFilter = etf
                                        , selector = sel
                                        }
                            let pid = ProcessorId (name <> "-member-" <> T.pack (show m))
                            -- Built directly (not via 'mkProcessor', which hardcodes
                            -- Unordered/Serial) so the group policy is pinned.
                            pure (pid, QueueProcessor adapter (guardKirokuHandler handler) ordering conc)
                        )
                        [0 .. n - 1]
                pure (Right processors)
