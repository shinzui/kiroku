# Observability

Kiroku surfaces what is happening inside the store through two callbacks you
wire at construction time:

- `eventHandler` receives **store-emitted operational events** (`KirokuEvent`)
  — notifier reconnection, publisher errors, subscription lifecycle, and
  hard-delete issuance.
- `observationHandler` receives **connection-pool lifecycle observations**
  from `hasql-pool`.

Together they cover the store's runtime; for request-level tracing of
individual events see [OpenTelemetry](opentelemetry.md).

## Wiring The Callbacks

Both are fields on `ConnectionSettings`, defaulting to `Nothing`:

```haskell
import Control.Lens ((&), (.~))
import Kiroku.Store

settings :: ConnectionSettings
settings =
  defaultConnectionSettings connStr
    & #eventHandler .~ Just logKirokuEvent
    & #observationHandler .~ Just logPoolObservation

logKirokuEvent :: KirokuEvent -> IO ()
logKirokuEvent = \case
  KirokuEventSubscriptionStarted name pos ->
    logInfo ("subscription started" , name, pos)
  KirokuEventSubscriptionStopped name pos reason ->
    logInfo ("subscription stopped" , name, pos, reason)
  other ->
    logInfo ("kiroku" , other)
```

`KirokuEvent`, the supporting enums, and the `hasql-pool` `Observation` types
are all re-exported from `Kiroku.Store`, so a single import suffices.

> **Callbacks run synchronously on the emit-site thread** (notifier loop,
> publisher loop, subscription worker, store interpreter). A slow callback
> stalls that loop. For anything that may block — network I/O to a metrics
> backend, disk — fan out asynchronously: write to a `TBQueue` and drain it
> from a dedicated thread.

The `KirokuEvent` constructor set is *additive*: new constructors are added
rather than existing ones changed, so an incomplete pattern match surfaces as
a `-Wincomplete-patterns` warning, never a silent regression. Keep a
catch-all branch if you only care about specific events.

## The `KirokuEvent` Taxonomy

| Constructor | When it fires | What to do |
| --- | --- | --- |
| `KirokuEventNotifierReconnecting !Int !SomeException` | The dedicated `LISTEN` connection failed and the listener is about to reconnect. The `Int` is the consecutive failure count (drives backoff, capped at 30s). | Alert on a sustained / rising count — subscriptions are on the safety poll until reconnect. |
| `KirokuEventNotifierReconnected` | The `LISTEN` connection was re-established; the failure counter resets. | Pairs with the reconnecting event; clear the alert. |
| `KirokuEventPublisherPoolError !UsageError` | The publisher's read query returned a pool error; it retries on the next tick or the 30s poll. | Sustained emissions indicate pool exhaustion or a persistent server error. |
| `KirokuEventSubscriptionDbError !SubscriptionName !SubscriptionDbPhase !UsageError` | A subscription worker hit a database error in a specific phase. The worker continues with safe defaults. | This is your only signal it happened — investigate the phase (below). |
| `KirokuEventSubscriptionStarted !SubscriptionName !GlobalPosition` | A subscription worker started, beginning from the recorded position. | Useful as a liveness signal and to confirm the resumed checkpoint. |
| `KirokuEventSubscriptionCaughtUp !SubscriptionName !GlobalPosition` | The subscription reached the publisher's last-published position and switched from catch-up to live. Fires at most once per run. | Track catch-up latency after a restart. |
| `KirokuEventSubscriptionStopped !SubscriptionName !GlobalPosition !SubscriptionStopReason` | The worker stopped. | Branch on the reason (below) to distinguish normal completion from failure. |
| `KirokuEventHardDeleteIssued !StreamName !StreamId` | A hard-delete transaction committed. Not emitted when the stream did not exist. | A fail-safe audit signal — see [Stream Lifecycle](lifecycle.md). |

### `SubscriptionDbPhase`

Identifies which database phase a `KirokuEventSubscriptionDbError` came from:

- `LoadCheckpoint` — failed to read the saved checkpoint at startup. The
  worker continues at position 0; correct for a fresh subscription, but
  silently re-processes for an existing one.
- `FetchBatch` — a catch-up or category-live fetch errored. The worker
  substitutes an empty batch and may prematurely switch to live mode at a
  stale cursor.
- `SaveCheckpoint` — the checkpoint write failed. The subscription keeps
  running, but the next restart with the same name re-processes events.

### `SubscriptionStopReason`

Discriminates the `KirokuEventSubscriptionStopped` cause:

- `StopHandlerRequested` — the handler returned `Stop`. Normal completion;
  checkpoint saved at that event.
- `StopCancelled` — the caller cancelled. No checkpoint advance guaranteed;
  in-flight events replay on restart.
- `StopOverflowed` — the publisher dropped the subscription under
  `DropSubscription` (its queue overflowed). See
  [Subscriptions](subscriptions.md).
- `StopWorkerCrashed !SomeException` — an uncaught exception (typically from
  the handler) killed the worker. The exception carries the cause.

## Connection-Pool Observations

`observationHandler` forwards `hasql-pool`'s `Observation` values —
connection establishment, readiness, and termination, each carrying a
`ConnectionStatus` / `ConnectionReadyForUseReason` /
`ConnectionTerminationReason`. Use it for pool-health metrics: connection
churn, establishment failures, and pool saturation. It complements
`eventHandler`, which covers events the pool layer cannot see.

```haskell
logPoolObservation :: Observation -> IO ()
logPoolObservation obs = recordMetric "kiroku.pool" obs
```

## Forwarding To Logs And Metrics

A practical pattern:

1. In `eventHandler`, increment counters keyed by constructor (and for
   subscriptions, by `SubscriptionName`) and emit a structured log line.
2. Alert on `KirokuEventNotifierReconnecting` with a high failure count,
   sustained `KirokuEventPublisherPoolError`, any
   `KirokuEventSubscriptionDbError`, and `StopWorkerCrashed` /
   `StopOverflowed` stop reasons.
3. Treat `KirokuEventHardDeleteIssued` as an audit event. Because it is
   fail-safe rather than compliance-grade, also record an application-level
   event **before** the hard delete; see [Stream Lifecycle](lifecycle.md) and
   `docs/PRODUCTION-DEPLOYMENT.md`.
4. Keep both callbacks fast; fan out blocking work asynchronously.

## See Also

- [Subscriptions](subscriptions.md) — the lifecycle these events report on.
- [OpenTelemetry](opentelemetry.md) — per-event trace context.
- [Stream Lifecycle](lifecycle.md) — the hard-delete audit pattern.
