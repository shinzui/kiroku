---
title: "Embeddable operator CLI"
type: Capability
description: "Embed a kiroku operator command group into a host CLI, or run the standalone kiroku binary as a remote client that reports subscription status from a running worker's HTTP endpoint."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-18
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-cli
interface:
  - Kiroku.Cli.Parser
  - Kiroku.Cli.Standalone
  - Kiroku.Cli.Subscription.Status
requires:
  - CAP-11
  - CAP-17
evidence:
  - kind: test
    resource: kiroku-cli/test/Main.hs
    proves: Parser composition (help text, subcommands, --format), rendering, and store-backed subscription-status rendering against an ephemeral database.
  - kind: guide
    resource: docs/user/operator-cli.md
    proves: Standalone and embedded operator CLI usage.
---

# Embeddable operator CLI

Embed the `kiroku` command group into a host operator CLI with `kirokuSubparser` (reading the
in-process [subscription](live-subscriptions.md) registry via `runKirokuCommandWithStore`), or ship
the standalone `kiroku` binary. Today the command tree is `kiroku subscriptions status`, with
`--format table|json` and an optional `--remote-url`. The `SubscriptionStatusRow` codec is the
single wire contract shared with the [metrics `/subscriptions` endpoint](operational-http-endpoints.md).

## Usage

```bash
kiroku subscriptions status --remote-url "$KIROKU_REMOTE_URL" --format json
```

## Limits

- Since `0.2.0.0` the standalone binary is a **pure remote client**: it no longer opens a store and
  the `--database-url`/`--schema`/`--pool-size` options are gone. With neither `--remote-url` nor
  `KIROKU_REMOTE_URL` set it exits with guidance instead of connecting — the remote path depends on
  a running worker serving the metrics `/subscriptions` endpoint. The embeddable library path still
  reads the in-process registry directly.
- The command surface is currently a single family (`subscriptions status`); it is an operator tool,
  not a general administration CLI.
