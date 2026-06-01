# Operator CLI

The `kiroku-cli` package provides two surfaces:

- an embeddable library API under `Kiroku.Cli`, intended for host services that
  already own a live `KirokuStore` and read its in-process registry directly;
- a standalone `kiroku` executable that is a **pure remote client**: it opens no
  store of its own and queries a running worker's `kiroku-metrics`
  `/subscriptions` endpoint over HTTP.

The first operator command is subscription status. It lists every live
subscription — the subscription name, consumer-group member, finite-state-machine
phase, and global cursor position.

## Standalone Usage

The standalone binary inspects a **running worker** over HTTP. Point it at that
worker's `kiroku-metrics` server (see
[Metrics And Event Streaming](metrics.md#subscription-status-over-http)) with
`--remote-url` or the `KIROKU_REMOTE_URL` environment variable. It never opens a
database; the `--database-url`/`--schema`/`--pool-size` options no longer exist.

```bash
export KIROKU_REMOTE_URL='http://worker-host:9091'
kiroku subscriptions status
```

Equivalent explicit flag:

```bash
kiroku subscriptions status --remote-url http://worker-host:9091
```

Table output is the default:

```text
SUBSCRIPTION          MEMBER  PHASE  GLOBAL_POSITION
invoice-projection    0       live   1284
billing-projection    1       live   1284
```

For scripts, request JSON:

```bash
kiroku subscriptions status --remote-url http://worker-host:9091 --format json
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

With neither `--remote-url` nor `KIROKU_REMOTE_URL` set, the command exits
non-zero with guidance (the standalone binary runs no subscriptions of its own, so
there is nothing local to read). An unreachable endpoint prints a readable error,
not a Haskell exception dump.

## How Status Is Sourced

The worker side serves `/subscriptions` from `subscriptionStates store`, which
snapshots the worker's in-memory registry — populated by `subscribe` calls in that
worker process and removed from when those workers stop, are cancelled, crash, or
are superseded. The standalone `kiroku` client fetches and renders it.

For an **in-process** read with no HTTP hop, use the embeddable library: mount the
Kiroku parser inside the service's own CLI and pass the service's live
`KirokuStore` to `renderKirokuCommandWithStore`/`runKirokuCommandWithStore` (see
below). That path also accepts an optional `--remote-url` to query a sibling worker
instead.

Stopped, cancelled, and crashed subscriptions are represented by absence; the
CLI does not invent a `"stopped"` row. `global_position` is the worker
finite-state-machine cursor, a cheap live-progress signal, not a durable
checkpoint guarantee. See [Observability](observability.md#snapshotting-every-live-subscription)
for the full registry model and [Metrics And Event Streaming](metrics.md) for the
HTTP endpoint that exposes it.

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
