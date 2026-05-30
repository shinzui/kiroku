{- | Turn a Kiroku subscription worker's lifecycle into OpenTelemetry spans.

A Kiroku /subscription/ is a long-lived worker that reads events in order and
feeds them to a handler, remembering progress in a durable checkpoint. The
worker is an explicit finite state machine — at any instant it is in exactly one
of @CatchingUp@, @Live@, @Paused@, @Reconnecting@, @Retrying@, or @Stopped@
(see @Kiroku.Store.Subscription.Fsm@) — and it announces every transition as a
structured 'KirokuEvent' delivered synchronously to the optional
@eventHandler :: Maybe (KirokuEvent -> IO ())@ callback an operator installs on
their connection settings.

This module bridges that event stream to OpenTelemetry traces. Call
'subscriptionTraceHandler' with a 'Tracer' to obtain a ready-made
@'KirokuEvent' -> IO ()@; install it as the subscription @eventHandler@ and
thereafter every subscription emits spans. On a trace timeline an operator can
then watch a subscription catch up, go live, pause under backpressure, reconnect
after a database outage, retry a poison event, and dead-letter it — each span
tagged with the subscription name, the consumer-group member, the checkpoint
position, the attempt counter, and batch sizes (the @kiroku.*@ attribute keys
exported below).

== Span model and the export-on-end constraint

A span is only exported to the backend when it /ends/ — the SDK's span
processors fire @onEnd@, never on a snapshot of an in-flight span (verified in
@hs-opentelemetry@: @endSpan@ → @tracerProviderOnEnd@ → @spanProcessorOnEnd@,
with no partial export). A single span held open for the worker's whole lifetime
would therefore be invisible while the worker runs and lost entirely on a crash.

So this module uses __short, promptly-ending spans__, never one lifetime span:

* __Episode spans__ open on a state-entry event and end on the matching exit
  event, so a /completed/ episode shows its real duration:

    * @kiroku.subscription.catchup@ — opened on @Started@, ended on @CaughtUp@.
    * @kiroku.subscription.paused@ — opened on @Paused@, ended on @Resumed@.
    * @kiroku.subscription.reconnecting@ — opened on the first @Reconnecting@,
      ended on the next @CaughtUp@; later reconnect attempts add a
      @reconnect.attempt@ span event.
    * @kiroku.subscription.retrying@ — keyed per poison event by its global
      position; opened on the first @Retrying@ for that position, ended either
      when a @DeadLettered@ for the same position arrives (status @Error@) or
      when the worker moves on (a @Fetched@/@CaughtUp@, status @Ok@).

* __Per-batch work spans__ open and end immediately during @Live@:

    * @kiroku.subscription.fetch@ — one per live fetch, carrying
      @kiroku.batch.rows@. These export continuously, giving live visibility
      without a long-lived @Live@ span.

* __Standalone spans__ for point events with no open episode:
  @kiroku.subscription.dead_letter@ (an immediate dead-letter, no retry) and
  @kiroku.subscription.db_error@ (a DB error with no episode span open; when one
  /is/ open the error is recorded as a @kiroku.db_error@ span event on it).

The honest limitation: an /in-progress/ (unresolved) episode does not appear in
the backend until it ends. Real-time "what state is this worker in right now" is
served instead by the @currentState@ subscription-handle accessor and the
'KirokuEvent' log stream (and, eventually, by a deferred state-gauge metric).

== Threading and the batch-processor requirement

The @eventHandler@ callback runs __synchronously on the worker's emit-site
thread__, and a consumer group runs one worker per member on separate threads.
The open-span bookkeeping is therefore held in a thread-safe 'MVar' keyed by
@(subscription name, member)@ so two members never collide. Opening and ending a
span is cheap and in-memory; it is the /export/ that may block. Configure the
'Tracer''s 'TracerProvider' with a __batch span processor__ (the SDK default)
so export happens on a background thread and the synchronous callback never
stalls the worker loop.

This module is a pure read-side consumer of the 'KirokuEvent' surface: it adds
no behavior to the worker, changes no core type, and adds no @hs-opentelemetry@
dependency to @kiroku-store@. The 'KirokuEvent' constructor set is /additive/,
so a future subscription constructor surfaces here as a
@-Wincomplete-patterns@ warning rather than a silent miss.
-}
module Kiroku.Otel.Subscription (
    -- * Handler factory
    subscriptionTraceHandler,

    -- * Span names
    spanCatchup,
    spanFetch,
    spanPaused,
    spanReconnecting,
    spanRetrying,
    spanDeadLetter,
    spanDbError,

    -- * Attribute keys
    attrSubName,
    attrState,
    attrAttempt,
    attrCheckpoint,
    attrGroupMember,
    attrGroupSize,
    attrBatchRows,
    attrEventPos,
    attrDeadLetterReason,
    attrStopReason,
    attrDbPhase,
) where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar)
import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int32, Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Kiroku.Store.Observability (
    KirokuEvent (..),
    SubscriptionGroupContext (..),
 )
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (GlobalPosition (..))
import OpenTelemetry.Attributes (Attribute, ToAttribute (toAttribute))
import OpenTelemetry.Context qualified as Context
import OpenTelemetry.Trace.Core (
    NewEvent (..),
    Span,
    SpanStatus (..),
    Tracer,
    addAttribute,
    addEvent,
    createSpan,
    defaultSpanArguments,
    endSpan,
    setStatus,
 )

{- | Build a 'KirokuEvent' handler that turns subscription state into
OpenTelemetry spans, drawn from the given 'Tracer'.

@
import Kiroku.Otel.Subscription (subscriptionTraceHandler)
-- tracer :: OpenTelemetry.Trace.Core.Tracer  (from the app's TracerProvider)
handler <- subscriptionTraceHandler tracer
-- install on the connection\/subscription settings:
--   settings { eventHandler = Just handler }
@

The returned handler is thread-safe (a consumer group drives it from one thread
per member) and keeps its open-span state in an internal 'MVar' keyed by
@(subscription name, member)@. See the module documentation for the span model
and the batch-span-processor requirement.
-}
subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())
subscriptionTraceHandler tracer = do
    cell <- newMVar Map.empty
    pure (onEvent tracer cell)

-- | Identifies one worker: subscription name plus consumer-group member (if any).
type SpanKey = (Text, Maybe Int32)

-- | The spans currently open for a single 'SpanKey'.
data OpenState = OpenState
    { osCatchup :: !(Maybe Span)
    -- ^ Initial catch-up episode (opened on @Started@).
    , osReconnect :: !(Maybe Span)
    -- ^ Reconnect episode (opened on the first @Reconnecting@).
    , osPause :: !(Maybe Span)
    -- ^ Backpressure pause episode (opened on @Paused@).
    , osRetries :: !(Map Int64 Span)
    -- ^ Per-poison-event retry episodes, keyed by global position.
    }

emptyOpenState :: OpenState
emptyOpenState = OpenState Nothing Nothing Nothing Map.empty

{- | The most relevant single open episode span for a key, preferring an
in-flight reconnect, then catch-up, then pause. Used to attach DB-error span
events and the stop reason.
-}
primaryEpisode :: OpenState -> Maybe Span
primaryEpisode st = osReconnect st <|> osCatchup st <|> osPause st

onEvent :: Tracer -> MVar (Map SpanKey OpenState) -> KirokuEvent -> IO ()
onEvent tracer cell = \case
    KirokuEventSubscriptionStarted name pos grp ->
        withKey cell (keyOf name grp) $ \st -> do
            -- Defensively close a catch-up span left open by a prior episode.
            mapM_ closeSpan (osCatchup st)
            sp <-
                openSpan tracer spanCatchup $
                    baseAttrs name grp
                        ++ [(attrState, toAttribute ("catchup" :: Text)), (attrCheckpoint, posAttr pos)]
            pure st{osCatchup = Just sp}
    KirokuEventSubscriptionCaughtUp name pos grp ->
        withKey cell (keyOf name grp) $ \st -> do
            let endAttrs = [(attrCheckpoint, posAttr pos)]
            -- A CaughtUp closes whichever of catch-up / reconnect is open.
            mapM_ (`closeSpanWith` endAttrs) (osCatchup st)
            mapM_ (\sp -> setStatus sp Ok >> closeSpanWith sp endAttrs) (osReconnect st)
            -- The worker has moved on, so any open retry succeeded.
            mapM_ (\sp -> setStatus sp Ok >> closeSpan sp) (Map.elems (osRetries st))
            pure st{osCatchup = Nothing, osReconnect = Nothing, osRetries = Map.empty}
    KirokuEventSubscriptionFetched name rows grp ->
        withKey cell (keyOf name grp) $ \st -> do
            sp <-
                openSpan tracer spanFetch $
                    baseAttrs name grp
                        ++ [(attrState, toAttribute ("live" :: Text)), (attrBatchRows, intAttr rows)]
            closeSpan sp
            -- A live fetch means the worker advanced past any retried event.
            mapM_ (\rsp -> setStatus rsp Ok >> closeSpan rsp) (Map.elems (osRetries st))
            pure st{osRetries = Map.empty}
    KirokuEventSubscriptionPaused name pos grp ->
        withKey cell (keyOf name grp) $ \st -> do
            mapM_ closeSpan (osPause st) -- defensive
            sp <-
                openSpan tracer spanPaused $
                    baseAttrs name grp
                        ++ [(attrState, toAttribute ("paused" :: Text)), (attrCheckpoint, posAttr pos)]
            pure st{osPause = Just sp}
    KirokuEventSubscriptionResumed name pos grp ->
        withKey cell (keyOf name grp) $ \st -> do
            -- Ignore a resume with no matching open pause span.
            mapM_ (`closeSpanWith` [(attrCheckpoint, posAttr pos)]) (osPause st)
            pure st{osPause = Nothing}
    KirokuEventSubscriptionReconnecting name attempt grp ->
        withKey cell (keyOf name grp) $ \st ->
            case osReconnect st of
                Nothing -> do
                    sp <-
                        openSpan tracer spanReconnecting $
                            baseAttrs name grp
                                ++ [(attrState, toAttribute ("reconnecting" :: Text)), (attrAttempt, intAttr attempt)]
                    pure st{osReconnect = Just sp}
                Just sp -> do
                    spanEvent sp "reconnect.attempt" [(attrAttempt, intAttr attempt)]
                    setAttrs sp [(attrAttempt, intAttr attempt)]
                    pure st
    KirokuEventSubscriptionRetrying name pos attempt grp ->
        withKey cell (keyOf name grp) $ \st -> do
            let GlobalPosition p = pos
            case Map.lookup p (osRetries st) of
                Nothing -> do
                    sp <-
                        openSpan tracer spanRetrying $
                            baseAttrs name grp
                                ++ [ (attrState, toAttribute ("retrying" :: Text))
                                   , (attrEventPos, toAttribute p)
                                   , (attrAttempt, intAttr attempt)
                                   ]
                    pure st{osRetries = Map.insert p sp (osRetries st)}
                Just sp -> do
                    spanEvent sp "retry.attempt" [(attrAttempt, intAttr attempt)]
                    setAttrs sp [(attrAttempt, intAttr attempt)]
                    pure st
    KirokuEventSubscriptionDeadLettered name pos reason grp ->
        withKey cell (keyOf name grp) $ \st -> do
            let GlobalPosition p = pos
                dlAttrs = [(attrDeadLetterReason, toAttribute (T.pack (show reason)))]
            case Map.lookup p (osRetries st) of
                Just sp -> do
                    -- A retry that exhausted: close the open retry span as dead-lettered.
                    setAttrs sp dlAttrs
                    spanEvent sp "dead_letter" dlAttrs
                    setStatus sp (Error "dead-lettered")
                    closeSpan sp
                    pure st{osRetries = Map.delete p (osRetries st)}
                Nothing -> do
                    -- An immediate dead-letter (no retry): a short standalone span.
                    sp <-
                        openSpan tracer spanDeadLetter $
                            baseAttrs name grp ++ [(attrEventPos, toAttribute p)] ++ dlAttrs
                    closeSpan sp
                    pure st
    KirokuEventSubscriptionDbError name phase _err grp ->
        withKey cell (keyOf name grp) $ \st -> do
            let phaseAttrs = [(attrDbPhase, toAttribute (T.pack (show phase)))]
            case primaryEpisode st of
                Just sp -> do
                    -- Annotate the open episode rather than spawn a competing span.
                    spanEvent sp "kiroku.db_error" phaseAttrs
                    pure st
                Nothing -> do
                    sp <- openSpan tracer spanDbError (baseAttrs name grp ++ phaseAttrs)
                    closeSpan sp
                    pure st
    KirokuEventSubscriptionStopped name pos reason grp ->
        dropKey cell (keyOf name grp) $ \st -> do
            let stopAttrs =
                    [ (attrStopReason, toAttribute (T.pack (show reason)))
                    , (attrCheckpoint, posAttr pos)
                    ]
            -- Record the stop reason on the most relevant open episode, then
            -- end every span so none leaks when the worker stops.
            mapM_ (`setAttrs` stopAttrs) (primaryEpisode st)
            mapM_ closeSpan (osCatchup st)
            mapM_ closeSpan (osReconnect st)
            mapM_ closeSpan (osPause st)
            mapM_ closeSpan (Map.elems (osRetries st))
    -- Non-subscription operational events are not traced here.
    KirokuEventNotifierReconnecting{} -> pure ()
    KirokuEventNotifierReconnected -> pure ()
    KirokuEventPublisherPoolError{} -> pure ()
    KirokuEventHardDeleteIssued{} -> pure ()

-- Span / state-cell helpers ---------------------------------------------------

{- | Run a state-update action against the 'OpenState' for a key, inserting the
result back. Serialized through the 'MVar'; span operations are cheap and
in-memory.
-}
withKey :: MVar (Map SpanKey OpenState) -> SpanKey -> (OpenState -> IO OpenState) -> IO ()
withKey cell key f = modifyMVar_ cell $ \m -> do
    st' <- f (Map.findWithDefault emptyOpenState key m)
    pure $! Map.insert key st' m

-- | Run a finalizing action against a key's 'OpenState', then drop the key.
dropKey :: MVar (Map SpanKey OpenState) -> SpanKey -> (OpenState -> IO ()) -> IO ()
dropKey cell key f = modifyMVar_ cell $ \m -> do
    f (Map.findWithDefault emptyOpenState key m)
    pure $! Map.delete key m

-- | Open a root span with the given name and initial attributes.
openSpan :: Tracer -> Text -> [(Text, Attribute)] -> IO Span
openSpan tracer name attrs = do
    sp <- createSpan tracer Context.empty name defaultSpanArguments
    setAttrs sp attrs
    pure sp

{- | Set attributes on a span, overriding any existing value for the same key.
Uses the singular 'addAttribute' (an @insert@) rather than the bulk
@addAttributes@, whose left-biased union would keep a key's existing value and
silently drop the update (e.g. refreshing a checkpoint or attempt counter).
-}
setAttrs :: Span -> [(Text, Attribute)] -> IO ()
setAttrs sp = mapM_ (\(k, v) -> addAttribute sp k v)

-- | End a span at the current time.
closeSpan :: Span -> IO ()
closeSpan sp = endSpan sp Nothing

-- | Add final attributes to a span and then end it.
closeSpanWith :: Span -> [(Text, Attribute)] -> IO ()
closeSpanWith sp attrs = do
    setAttrs sp attrs
    endSpan sp Nothing

-- | Add a timestamped span event with the given name and attributes.
spanEvent :: Span -> Text -> [(Text, Attribute)] -> IO ()
spanEvent sp name attrs =
    addEvent
        sp
        NewEvent
            { newEventName = name
            , newEventAttributes = HashMap.fromList attrs
            , newEventTimestamp = Nothing
            }

-- | Build the 'SpanKey' identifying the worker that emitted an event.
keyOf :: SubscriptionName -> SubscriptionGroupContext -> SpanKey
keyOf (SubscriptionName nm) grp = (nm, memberOf grp)

-- | The member index of a group context (Nothing for a non-grouped worker).
memberOf :: SubscriptionGroupContext -> Maybe Int32
memberOf NonGroup = Nothing
memberOf (GroupMember m _) = Just m

{- | The baseline attribute set set on every span: the subscription name and,
for a group member, its index and the group size.
-}
baseAttrs :: SubscriptionName -> SubscriptionGroupContext -> [(Text, Attribute)]
baseAttrs (SubscriptionName nm) grp =
    (attrSubName, toAttribute nm)
        : case grp of
            NonGroup -> []
            GroupMember m sz -> [(attrGroupMember, intAttr m), (attrGroupSize, intAttr sz)]

-- | A 'GlobalPosition' as an 'Int64' attribute.
posAttr :: GlobalPosition -> Attribute
posAttr (GlobalPosition p) = toAttribute p

-- | Any small integral count as an 'Int64' attribute.
intAttr :: (Integral a) => a -> Attribute
intAttr n = toAttribute (fromIntegral n :: Int64)

-- Span name constants ---------------------------------------------------------

spanCatchup, spanFetch, spanPaused, spanReconnecting, spanRetrying, spanDeadLetter, spanDbError :: Text
spanCatchup = "kiroku.subscription.catchup"
spanFetch = "kiroku.subscription.fetch"
spanPaused = "kiroku.subscription.paused"
spanReconnecting = "kiroku.subscription.reconnecting"
spanRetrying = "kiroku.subscription.retrying"
spanDeadLetter = "kiroku.subscription.dead_letter"
spanDbError = "kiroku.subscription.db_error"

-- Attribute key constants -----------------------------------------------------

attrSubName, attrState, attrAttempt, attrCheckpoint :: Text
attrGroupMember, attrGroupSize, attrBatchRows, attrEventPos :: Text
attrDeadLetterReason, attrStopReason, attrDbPhase :: Text
attrSubName = "kiroku.subscription.name"
attrState = "kiroku.subscription.state"
attrAttempt = "kiroku.subscription.attempt"
attrCheckpoint = "kiroku.checkpoint.global_position"
attrGroupMember = "kiroku.consumer_group.member"
attrGroupSize = "kiroku.consumer_group.size"
attrBatchRows = "kiroku.batch.rows"
attrEventPos = "kiroku.event.global_position"
attrDeadLetterReason = "kiroku.dead_letter.reason"
attrStopReason = "kiroku.subscription.stop_reason"
attrDbPhase = "kiroku.db.phase"
