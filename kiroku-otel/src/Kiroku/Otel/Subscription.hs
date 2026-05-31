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
      when the worker moves on (a live @Delivered@/@CaughtUp@, status @Ok@).

* __Per-batch work spans__ open and end immediately on every delivered batch:

    * @kiroku.subscription.deliver@ — one per non-empty batch handed to the
      handler, on __every__ target (@$all@, category, consumer group) and in
      __both__ phases. It carries @kiroku.batch.rows@ and a
      @kiroku.subscription.state@ of @"catchup"@ or @"live"@, so an @$all@
      subscription's live phase is now traced (previously it emitted no
      per-batch event and so went dark while live). These export continuously,
      giving live visibility without a long-lived @Live@ span.
      (@KirokuEventSubscriptionFetched@ — the DB-driven live-fetch-rate signal —
      is intentionally __not__ traced; the deliver span subsumes it, so the
      category\/consumer-group live path does not emit two spans per batch.)

* __Standalone spans__ for point events with no open episode:
  @kiroku.subscription.dead_letter@ (an immediate dead-letter, no retry),
  @kiroku.subscription.db_error@ (a DB error with no episode span open; when one
  /is/ open the error is recorded as a @kiroku.db_error@ span event on it), and
  @kiroku.subscription.stopped@ — __always__ emitted on @Stopped@, carrying the
  @kiroku.subscription.stop_reason@ and the @kiroku.checkpoint.global_position@,
  so the terminal state is present in the trace even for a healthy worker that
  stops from @Live@ with no open episode span.

The honest limitation: an /in-progress/ (unresolved) episode does not appear in
the backend until it ends. Real-time "what state is this worker in right now" is
served instead by the @currentState@ subscription-handle accessor and the
'KirokuEvent' log stream (and, eventually, by a deferred state-gauge metric).

== Threading and the batch-processor requirement

The @eventHandler@ callback runs __synchronously on the worker's emit-site
thread__, and a consumer group runs one worker per member on separate threads.
The open-span bookkeeping is therefore held in a striped, lock-free registry
keyed by @(subscription name, member)@ so two members never collide: each key
has its own single-writer 'IORef' 'OpenState' and the outer registry is mutated
only when a key is first seen or removed, so the per-batch deliver-span work
never serializes workers on a shared lock. Opening and ending a span is cheap
and in-memory; it is the /export/ that may block. Configure the 'Tracer''s
'TracerProvider' with a __batch span processor__ (the SDK default) so export
happens on a background thread and the synchronous callback never stalls the
worker loop.

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
    spanDeliver,
    spanPaused,
    spanReconnecting,
    spanRetrying,
    spanDeadLetter,
    spanDbError,
    spanStopped,

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
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Kiroku.Store.Observability (
    KirokuEvent (..),
    SubscriptionDeliveryPhase (..),
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
per member) and keeps its open-span state in a striped, lock-free per-key
registry keyed by @(subscription name, member)@: each key has its own
single-writer 'IORef' 'OpenState', and the outer registry is mutated only when a
key is first seen or removed. See the module documentation for the span model and
the batch-span-processor requirement.
-}
subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())
subscriptionTraceHandler tracer = do
    cells <- newIORef Map.empty
    pure (onEvent tracer cells)

{- | A per-key span-state registry. The outer 'IORef' is read-mostly — mutated
only when a key is first seen (@Started@) or removed (@Stopped@), via
'atomicModifyIORef''. Each key's inner 'IORef' 'OpenState' is single-writer (one
worker thread emits that key's events), so the per-batch hot path reads the outer
map lock-free and mutates only the key's own cell — no shared lock, no
cross-worker contention.
-}
type SpanCells = IORef (Map SpanKey (IORef OpenState))

-- | Identifies one worker: subscription name plus consumer-group member (if any).
type SpanKey = (Text, Maybe Int32)

-- | The spans currently open for a single 'SpanKey'.
data OpenState = OpenState
    { catchup :: !(Maybe Span)
    -- ^ Initial catch-up episode (opened on @Started@).
    , reconnect :: !(Maybe Span)
    -- ^ Reconnect episode (opened on the first @Reconnecting@).
    , pause :: !(Maybe Span)
    -- ^ Backpressure pause episode (opened on @Paused@).
    , retries :: !(Map Int64 Span)
    -- ^ Per-poison-event retry episodes, keyed by global position.
    }
    deriving stock (Generic)

emptyOpenState :: OpenState
emptyOpenState = OpenState Nothing Nothing Nothing Map.empty

{- | The most relevant single open episode span for a key, preferring an
in-flight reconnect, then catch-up, then pause. Used to attach DB-error span
events and the stop reason.
-}
primaryEpisode :: OpenState -> Maybe Span
primaryEpisode st = reconnect st <|> catchup st <|> pause st

onEvent :: Tracer -> SpanCells -> KirokuEvent -> IO ()
onEvent tracer cell = \case
    KirokuEventSubscriptionStarted name pos grp ->
        withKey cell (keyOf name grp) $ \st -> do
            -- Defensively close a catch-up span left open by a prior episode.
            mapM_ closeSpan (catchup st)
            sp <-
                openSpan tracer spanCatchup $
                    baseAttrs name grp
                        ++ [(attrState, toAttribute ("catchup" :: Text)), (attrCheckpoint, posAttr pos)]
            pure st{catchup = Just sp}
    KirokuEventSubscriptionCaughtUp name pos grp ->
        withKey cell (keyOf name grp) $ \st -> do
            let endAttrs = [(attrCheckpoint, posAttr pos)]
            -- A CaughtUp closes whichever of catch-up / reconnect is open.
            mapM_ (`closeSpanWith` endAttrs) (catchup st)
            mapM_ (\sp -> setStatus sp Ok >> closeSpanWith sp endAttrs) (reconnect st)
            -- The worker has moved on, so any open retry succeeded.
            mapM_ (\sp -> setStatus sp Ok >> closeSpan sp) (Map.elems (retries st))
            pure st{catchup = Nothing, reconnect = Nothing, retries = Map.empty}
    KirokuEventSubscriptionDelivered name count phase grp ->
        withKey cell (keyOf name grp) $ \st -> do
            let stateText = case phase of
                    DeliveredCatchUp -> "catchup" :: Text
                    DeliveredLive -> "live"
            sp <-
                openSpan tracer spanDeliver $
                    baseAttrs name grp
                        ++ [(attrState, toAttribute stateText), (attrBatchRows, intAttr count)]
            closeSpan sp
            case phase of
                -- A live batch means the worker advanced past any retried event,
                -- so any still-open retry span succeeded: close them as Ok.
                DeliveredLive -> do
                    mapM_ (\rsp -> setStatus rsp Ok >> closeSpan rsp) (Map.elems (retries st))
                    pure st{retries = Map.empty}
                DeliveredCatchUp -> pure st
    KirokuEventSubscriptionPaused name pos grp ->
        withKey cell (keyOf name grp) $ \st -> do
            mapM_ closeSpan (pause st) -- defensive
            sp <-
                openSpan tracer spanPaused $
                    baseAttrs name grp
                        ++ [(attrState, toAttribute ("paused" :: Text)), (attrCheckpoint, posAttr pos)]
            pure st{pause = Just sp}
    KirokuEventSubscriptionResumed name pos grp ->
        withKey cell (keyOf name grp) $ \st -> do
            -- Ignore a resume with no matching open pause span.
            mapM_ (`closeSpanWith` [(attrCheckpoint, posAttr pos)]) (pause st)
            pure st{pause = Nothing}
    KirokuEventSubscriptionReconnecting name attempt grp ->
        withKey cell (keyOf name grp) $ \st ->
            case reconnect st of
                Nothing -> do
                    sp <-
                        openSpan tracer spanReconnecting $
                            baseAttrs name grp
                                ++ [(attrState, toAttribute ("reconnecting" :: Text)), (attrAttempt, intAttr attempt)]
                    pure st{reconnect = Just sp}
                Just sp -> do
                    spanEvent sp "reconnect.attempt" [(attrAttempt, intAttr attempt)]
                    setAttrs sp [(attrAttempt, intAttr attempt)]
                    pure st
    KirokuEventSubscriptionRetrying name pos attempt grp ->
        withKey cell (keyOf name grp) $ \st -> do
            let GlobalPosition p = pos
            case Map.lookup p (retries st) of
                Nothing -> do
                    sp <-
                        openSpan tracer spanRetrying $
                            baseAttrs name grp
                                ++ [ (attrState, toAttribute ("retrying" :: Text))
                                   , (attrEventPos, toAttribute p)
                                   , (attrAttempt, intAttr attempt)
                                   ]
                    pure st{retries = Map.insert p sp (retries st)}
                Just sp -> do
                    spanEvent sp "retry.attempt" [(attrAttempt, intAttr attempt)]
                    setAttrs sp [(attrAttempt, intAttr attempt)]
                    pure st
    KirokuEventSubscriptionDeadLettered name pos reason grp ->
        withKey cell (keyOf name grp) $ \st -> do
            let GlobalPosition p = pos
                dlAttrs = [(attrDeadLetterReason, toAttribute (T.pack (show reason)))]
            case Map.lookup p (retries st) of
                Just sp -> do
                    -- A retry that exhausted: close the open retry span as dead-lettered.
                    setAttrs sp dlAttrs
                    spanEvent sp "dead_letter" dlAttrs
                    setStatus sp (Error "dead-lettered")
                    closeSpan sp
                    pure st{retries = Map.delete p (retries st)}
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
            -- Always emit a short standalone terminal span so the Stopped state is
            -- present in the trace even for a healthy worker that stops from Live
            -- with no open episode span.
            term <- openSpan tracer spanStopped (baseAttrs name grp ++ stopAttrs)
            closeSpan term
            -- Also record the stop reason on the most relevant open episode (if any),
            -- then end every open span so none leaks when the worker stops.
            mapM_ (`setAttrs` stopAttrs) (primaryEpisode st)
            mapM_ closeSpan (catchup st)
            mapM_ closeSpan (reconnect st)
            mapM_ closeSpan (pause st)
            mapM_ closeSpan (Map.elems (retries st))
    -- Fetched is now a no-op: the DB-driven live loops emit both Fetched and
    -- Delivered per batch, and the deliver span (above) is keyed on Delivered so
    -- the live path does not produce two spans per batch. Matched for exhaustiveness.
    KirokuEventSubscriptionFetched{} -> pure ()
    -- Non-subscription operational events are not traced here.
    KirokuEventNotifierReconnecting{} -> pure ()
    KirokuEventNotifierReconnected -> pure ()
    KirokuEventPublisherPoolError{} -> pure ()
    KirokuEventHardDeleteIssued{} -> pure ()

-- Span / state-cell helpers ---------------------------------------------------

{- | The 'IORef' holding a key's 'OpenState', creating an empty cell on the key's
first touch (its @Started@ event). The outer registry is read lock-free on the hot
path; it is written (via 'atomicModifyIORef'') only to insert a new key's cell. The
inner cell is single-writer, so reads/writes of it need no lock.
-}
cellFor :: SpanCells -> SpanKey -> IO (IORef OpenState)
cellFor cells key = do
    m <- readIORef cells
    case Map.lookup key m of
        Just ref -> pure ref
        Nothing -> do
            fresh <- newIORef emptyOpenState
            atomicModifyIORef' cells $ \m' ->
                case Map.lookup key m' of
                    Just ref -> (m', ref) -- another key inserted meanwhile; reuse
                    Nothing -> (Map.insert key fresh m', fresh)

{- | Run a state-update against a key's own cell. The span IO in @f@ runs on the
key's single-writer 'IORef' with no shared lock held, so workers never serialize
on span work.

This is safe because each 'SpanKey' is __single-writer__: every
@(subscription name, member)@ is emitted by exactly one worker thread, and the
@eventHandler@ callback is synchronous on that thread, so a key's 'OpenState'
cannot change between the read and the write of its cell. The only cross-thread
structure is the outer registry, read lock-free on the hot path and mutated only
on the rare @Started@\/@Stopped@.
-}
withKey :: SpanCells -> SpanKey -> (OpenState -> IO OpenState) -> IO ()
withKey cells key f = do
    ref <- cellFor cells key
    st <- readIORef ref
    st' <- f st
    writeIORef ref st'

{- | Run a finalizer against a key's 'OpenState', then drop the key from the outer
registry. @Stopped@ is a key's last event, so nothing touches the cell afterward.
-}
dropKey :: SpanCells -> SpanKey -> (OpenState -> IO ()) -> IO ()
dropKey cells key f = do
    mref <- atomicModifyIORef' cells $ \m -> (Map.delete key m, Map.lookup key m)
    st <- maybe (pure emptyOpenState) readIORef mref
    f st

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

spanCatchup, spanDeliver, spanPaused, spanReconnecting, spanRetrying, spanDeadLetter, spanDbError, spanStopped :: Text
spanCatchup = "kiroku.subscription.catchup"
spanDeliver = "kiroku.subscription.deliver"
spanPaused = "kiroku.subscription.paused"
spanReconnecting = "kiroku.subscription.reconnecting"
spanRetrying = "kiroku.subscription.retrying"
spanDeadLetter = "kiroku.subscription.dead_letter"
spanDbError = "kiroku.subscription.db_error"
spanStopped = "kiroku.subscription.stopped"

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
