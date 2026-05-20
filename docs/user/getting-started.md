# Getting Started

Kiroku is a PostgreSQL event store. Application code talks to it through the
`Kiroku.Store` module: open a store handle, then run store operations as an
`effectful` `Store` effect. This guide opens a store, performs one append,
and reads it back.

## Prerequisites

- PostgreSQL 17 or newer. (PostgreSQL 18 supplies a built-in `uuidv7()`;
  PostgreSQL 17 receives a Kiroku-managed fallback — see
  [Schema Migrations](schema-migrations.md).)
- The `kiroku-store` package as a dependency.

By default `withStore` creates the schema on startup, so a fresh database
needs no manual setup for local development. Production deployments should
apply the schema with `kiroku-store-migrations` and disable startup DDL; see
[Schema Migrations](schema-migrations.md).

## Opening A Store

`withStore` is a bracket: it acquires the connection pool, optionally
initializes the schema, starts the notification listener and event
publisher, runs your action, and tears everything down in reverse order on
either normal exit or an exception.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Kiroku.Store

main :: IO ()
main =
  withStore (defaultConnectionSettings "host=/tmp port=5432 dbname=kiroku") $
    \store -> do
      -- use `store` here
      pure ()
```

`defaultConnectionSettings` takes a PostgreSQL connection string (a libpq URI
or `key=value` string). The string reaches libpq verbatim — Kiroku does no
parsing or substitution, and it may contain a password.

## Running Store Operations

Store operations such as `appendToStream` and `readStreamForward` are members
of the `Store` effect. The simplest interpreter is `runStoreIO`, which runs a
small fixed effect stack and returns `IO (Either StoreError a)`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Kiroku.Store

main :: IO ()
main =
  withStore (defaultConnectionSettings "host=/tmp port=5432 dbname=kiroku") $
    \store -> do
      result <- runStoreIO store $ do
        ar <-
          appendToStream
            (StreamName "orders-1")
            NoStream
            [ EventData
                { eventId = Nothing
                , eventType = EventType "OrderPlaced"
                , payload = object ["sku" .= ("ABC-1" :: Text), "qty" .= (3 :: Int)]
                , metadata = Nothing
                , causationId = Nothing
                , correlationId = Nothing
                }
            ]
        events <- readStreamForward (StreamName "orders-1") (StreamVersion 0) 100
        pure (ar, events)
      case result of
        Left err -> putStrLn ("store error: " <> show err)
        Right (ar, events) -> do
          print ar
          mapM_ print events
```

`runStoreIO` is the right starting point. It is equivalent to running the
`Store` interpreter (`runStorePool`), a `StoreError` error handler, and `IOE`
at once:

```haskell
runStoreIO store = runEff . runErrorNoCallStack . runStorePool store
```

## Integrating With A Larger Effect Stack

Applications that already run inside `Eff` should interpret `Store` against
their own stack rather than collapsing to `IO` per call:

- `runStorePool store` interprets `Store` when you hold a `KirokuStore` and
  already have `IOE` and `Error StoreError` in scope.
- `withKirokuStore` / `runStoreResource` carry the handle in the effect stack
  itself, so call sites do not thread `store` explicitly.

```haskell
{-# LANGUAGE TypeApplications #-}

import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Kiroku.Store

app :: IO (Either StoreError AppendResult)
app =
  runEff
    . runErrorNoCallStack @StoreError
    . withKirokuStore (defaultConnectionSettings "host=/tmp port=5432 dbname=kiroku")
    . runStoreResource
    $ appendToStream (StreamName "orders-1") NoStream [ {- ... -} ]
```

`getKirokuStore` retrieves the raw `KirokuStore` from the stack when you need
it directly — for example to start a subscription (see
[Subscriptions](subscriptions.md)).

The effectful `Subscription` interpreter (`runSubscription`,
`runSubscriptionResource`) is re-exported from `Kiroku.Store`, but the
effectful `subscribe` wrapper is **not**, to avoid clashing with the
`MonadIO`-based `subscribe`. Import `Kiroku.Store.Subscription.Effect`
explicitly to use it.

## Connection Settings

`defaultConnectionSettings` returns a `ConnectionSettings` record you can
override field-by-field with `generic-lens` labels:

```haskell
import Control.Lens ((&), (.~))

settings :: ConnectionSettings
settings =
  defaultConnectionSettings "host=/tmp port=5432 dbname=kiroku"
    & #poolSize .~ 20
    & #statementTimeout .~ Just 30
    & #schemaInitialization .~ SkipSchemaInitialization
```

| Field | Default | Meaning |
| --- | --- | --- |
| `connString` | (required) | PostgreSQL connection string passed to libpq verbatim. |
| `poolSize` | `10` | Connection pool size. See `docs/PRODUCTION-TUNING.md` for sizing. |
| `schema` | `"public"` | **LISTEN channel name only.** It does *not* qualify table names — those follow the connection's `search_path`. See note below. |
| `idleInTransactionTimeout` | `30` | `idle_in_transaction_session_timeout`, in seconds, set on each pooled connection. |
| `statementTimeout` | `Nothing` | When `Just s`, sets `statement_timeout = s` seconds. Bounds any single statement; protects pool slots from pathological queries. |
| `observationHandler` | `Nothing` | Callback for `hasql-pool` connection-lifecycle events. See [Observability](observability.md). |
| `eventHandler` | `Nothing` | Callback for store-emitted operational events (`KirokuEvent`). See [Observability](observability.md). |
| `storeSettings` | no-op | Append/read hooks for cross-cutting concerns such as trace context. See [OpenTelemetry](opentelemetry.md). |
| `schemaInitialization` | `InitializeSchemaOnAcquire` | Whether `withStore` runs schema DDL on startup. Use `SkipSchemaInitialization` when migrations manage the schema. |

The `schema` field controls only the `LISTEN <schema>.events` channel name.
With the defaults (`schema = "public"` and PostgreSQL's default
`search_path`) the listener channel and the trigger's notification channel
coincide. If you set a non-default `schema`, you must also ensure the
application user's `search_path` resolves `streams` in that same schema, or
the listener silently receives no notifications and subscriptions fall back
to the 30-second safety poll. Genuine schema-per-tenant table isolation is
not provided by this field; run a separate `KirokuStore` per tenant with
`search_path` set in the connection string.

## What Happens On Acquire

`withStore` performs, in order:

1. Acquire the `hasql-pool` connection pool with the configured size and the
   idle/statement timeout init session.
2. If `schemaInitialization` is `InitializeSchemaOnAcquire`, run the embedded
   schema DDL (idempotent). On failure it throws a `SchemaInitError`.
3. Start the notifier on a dedicated connection: `LISTEN <schema>.events`.
4. Start the event publisher that consumes notifier ticks and broadcasts new
   events to subscribers.

Release cancels the publisher, stops the notifier, and releases the pool.

## Next Steps

- [Appending Events](appending-events.md) — concurrency control and
  idempotency.
- [Reading Events](reading-events.md) — streams, `$all`, and categories.
- [Subscriptions](subscriptions.md) — react to new events.
