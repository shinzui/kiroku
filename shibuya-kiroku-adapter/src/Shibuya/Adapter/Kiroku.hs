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
                , consumerGroup = Nothing
                }

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
streams are processed in parallel. To run all four members in one process, build
one adapter per member index and wire each into its own processor:

@
main :: IO ()
main = withStore settings $ \\store ->
    runEff $ runTracingNoop $ do
        let mkMemberAdapter m =
                kirokuAdapter store
                    KirokuAdapterConfig
                        { subscriptionName = SubscriptionName \"orders-projection\"
                        , subscriptionTarget = Category (CategoryName \"orders\")
                        , batchSize = 100
                        , bufferSize = 256
                        , consumerGroup = Just (ConsumerGroup { member = m, size = 4 })
                        }

        adapters <- mapM mkMemberAdapter [0, 1, 2, 3]

        let processors =
                [ (ProcessorId (\"orders-\" <> T.pack (show m)), mkProcessor (adapters !! m) handler)
                | m <- [0 .. 3]
                ]

        Right appHandle <- runApp IgnoreFailures 100 processors
        waitApp appHandle
  where
    handler ingested = do
        -- process ingested.envelope.payload :: RecordedEvent
        pure AckOk
@

To run members across separate processes instead, give each process one adapter
with its own 'member' index and the same 'subscriptionName'. Kiroku's per-member
checkpoint (keyed by @(subscriptionName, member)@) lets each process resume from
its own position after a restart. Exactly one live process must own each member
index at a time.

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

== Backpressure

The @bufferSize@ field in 'KirokuAdapterConfig' controls the 'TBQueue'
capacity. Because delivery is ack-coupled, the Kiroku subscription worker blocks
on each event until the Shibuya handler finalizes its decision, providing natural
backpressure.
-}
module Shibuya.Adapter.Kiroku (
    -- * Adapter
    kirokuAdapter,

    -- * Configuration
    KirokuAdapterConfig (..),

    -- * Consumer-group helpers
    KirokuConsumerGroupConfig (..),
    defaultConsumerGroupConfig,
    consumerGroupPolicy,
    kirokuConsumerGroupProcessors,

    -- * Re-exports from kiroku-store
    SubscriptionName (..),
    SubscriptionTarget (..),
    ConsumerGroup (..),
) where

import Data.Int (Int32)
import Data.Text qualified as T
import Effectful (Eff, IOE, liftIO, (:>))
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Subscription.Stream (subscriptionAckStream)
import Kiroku.Store.Subscription.Types (
    ConsumerGroup (..),
    OverflowPolicy (..),
    SubscriptionConfigM (..),
    SubscriptionName (..),
    SubscriptionResult (..),
    SubscriptionTarget (..),
    defaultSubscriptionConfig,
 )
import Kiroku.Store.Types (RecordedEvent)
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku.Convert (toIngestedAck)
import Shibuya.App (ProcessorId (..), QueueProcessor (..))
import Shibuya.Core.Error (PolicyError (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), Ordering (..), validatePolicy)
import Streamly.Data.Stream qualified as Stream
import Prelude hiding (Ordering)

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
kirokuAdapter store (KirokuAdapterConfig subName subTarget bs buf cg) = do
    -- Build from 'defaultSubscriptionConfig' and override only the non-default
    -- fields. Using the smart constructor (rather than a full record literal)
    -- means any future field added to 'SubscriptionConfigM' is inherited at its
    -- default automatically — e.g. EP-2's 'consumerGroupGuard', left 'False' here.
    let subConfig =
            (defaultSubscriptionConfig subName subTarget (\_ -> pure Continue))
                { batchSize = bs
                , queueCapacity = 16
                , overflowPolicy = DropSubscription
                , consumerGroup = cg
                }

    (ioStream, cancelAction) <- liftIO $ subscriptionAckStream store subConfig buf

    let ingestedStream = fmap (toIngestedAck cancelAction) (Stream.morphInner liftIO ioStream)

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
    -- ^ Per-member 'TBQueue' capacity (backpressure threshold).
    , memberConcurrency :: !Concurrency
    -- ^ Per-member concurrency; must be 'Serial' (validated).
    }

{- | A 'KirokuConsumerGroupConfig' with sensible defaults: @memberConcurrency =
'Serial'@ (the only legal per-member concurrency), @batchSize = 100@,
@bufferSize = 256@. Supply the subscription name, target, and group size.
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
        , memberConcurrency = Serial
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
        , memberConcurrency = mc
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
                                        , consumerGroup = Just (ConsumerGroup{member = m, size = n})
                                        }
                            let pid = ProcessorId (name <> "-member-" <> T.pack (show m))
                            -- Built directly (not via 'mkProcessor', which hardcodes
                            -- Unordered/Serial) so the group policy is pinned.
                            pure (pid, QueueProcessor adapter handler ordering conc)
                        )
                        [0 .. n - 1]
                pure (Right processors)
