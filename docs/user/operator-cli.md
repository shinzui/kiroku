# Operator CLI

The `kiroku-cli` package provides two surfaces:

- an embeddable library API under `Kiroku.Cli`, intended for host services that
  already own a live `KirokuStore`;
- a standalone `kiroku` executable that opens its own store from command-line
  or environment configuration and delegates to the same command runner.

The first operator command is subscription status. It lists every live
subscription known to the current process's `KirokuStore`, showing the
subscription name, consumer-group member, finite-state-machine phase, and
global cursor position.

## Standalone Usage

Run the standalone executable with a PostgreSQL connection string from either
`--database-url` or `KIROKU_DATABASE_URL`. The store schema defaults to
`kiroku`, and the operator command uses a small pool by default.

```bash
export KIROKU_DATABASE_URL='host=/tmp dbname=kiroku user=kiroku'
kiroku subscriptions status
```

Equivalent explicit flags:

```bash
kiroku --database-url 'host=/tmp dbname=kiroku user=kiroku' --schema kiroku --pool-size 2 subscriptions status
```

Table output is the default:

```text
SUBSCRIPTION          MEMBER  PHASE  GLOBAL_POSITION
invoice-projection    0       live   1284
billing-projection    1       live   1284
```

For scripts, request JSON:

```bash
kiroku subscriptions status --format json
```

```json
[
  {
    "subscription": "invoice-projection",
    "member": 0,
    "phase": "live",
    "global_position": 1284
  }
]
```

If the standalone process has no live subscriptions in its own store handle,
table mode prints the headers plus a short message explaining that the registry
is process-local. JSON mode prints an empty array.

## Process-Local Status

`subscriptions status` reads `subscriptionStates store`, which snapshots an
in-memory registry on the current `KirokuStore`. That registry is populated by
`subscribe` calls made in the same process and is removed from when those
workers stop, are cancelled, crash, or are superseded.

This means embedded use is the authoritative status path for a running service:
mount the Kiroku parser inside the service's own CLI or admin command and pass
the service's live `KirokuStore` to the runner. A separately launched
standalone `kiroku` process opens a separate store handle with a separate empty
registry. It cannot inspect subscriptions running inside another service
process unless a future remote admin endpoint exposes that process's registry.

Stopped, cancelled, and crashed subscriptions are represented by absence; the
CLI does not invent a `"stopped"` row. `global_position` is the worker
finite-state-machine cursor, a cheap live-progress signal, not a durable
checkpoint guarantee. See [Observability](observability.md#snapshotting-every-live-subscription)
for the full registry model.

## Embedding In A Host CLI

A host application can mount Kiroku subcommands under its own parser by wrapping
`KirokuCommand` in the host's command type. The host owns database and process
configuration; Kiroku only receives the already-live `KirokuStore`.

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

import Kiroku.Cli
import Kiroku.Store (KirokuStore)
import Options.Applicative

data HostCommand
  = HostOwnCommand
  | HostKiroku KirokuCommand

hostCommandParser :: Parser HostCommand
hostCommandParser =
  subparser
    ( command "host" (info (pure HostOwnCommand) (progDesc "Run a host command."))
        <> kirokuSubparser HostKiroku
    )

runHostCommand :: KirokuStore -> HostCommand -> IO ()
runHostCommand store = \case
  HostOwnCommand ->
    putStrLn "host command"
  HostKiroku command ->
    runKirokuCommandWithStore store command
```

With that parser, a host can accept:

```bash
host-cli kiroku subscriptions status --format json
```

and Kiroku status reads the same store handle that owns the host service's live
subscriptions.
