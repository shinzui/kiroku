---
id: 48
slug: render-subscription-registry-status-in-the-operator-cli
title: "Render subscription registry status in the operator CLI"
kind: exec-plan
created_at: 2026-05-31T17:42:01Z
intention: "intention_01kszhy0dbeqnb1hkkhkrkwmw8"
master_plan: "docs/masterplans/8-embeddable-operator-cli-for-kiroku-subscription-status.md"
---

# Render subscription registry status in the operator CLI

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan adds the first useful operator command to `kiroku-cli`: list live subscriptions and show each subscription's current status and global cursor. After this change, a caller with a live `KirokuStore` can run the parsed command and see rows built from `subscriptionStates store`, including subscription name, consumer-group member, state phase, and `GlobalPosition`.

The command is intentionally registry-backed. It shows what is live in the current process's `KirokuStore`, not historical or durable subscription rows from PostgreSQL. The user can see it working through pure renderer tests and a database-backed test that starts subscriptions, invokes the CLI runner against the same store, and observes the expected status output.


## Progress

- [x] Extend the `KirokuCommand` type and parser with `subscriptions status`. Completed 2026-05-31 with `KirokuSubscriptions (SubscriptionStatus StatusOptions)` and parser coverage for default and JSON formats.
- [x] Add output-format options for a human table and JSON. Completed 2026-05-31 with `--format table|json`, defaulting to table.
- [x] Convert `Map (SubscriptionName, Int32) SubscriptionStateView` into stable CLI row values. Completed 2026-05-31 in `Kiroku.Cli.Subscription.Status.subscriptionStatusRows`, sorted by subscription name and member.
- [x] Render the rows as a table with subscription, member, phase, and global position columns. Completed 2026-05-31 with `SUBSCRIPTION`, `MEMBER`, `PHASE`, and `GLOBAL_POSITION` headers.
- [x] Render the same rows as JSON for scripts. Completed 2026-05-31 with an array of objects containing `subscription`, `member`, `phase`, and `global_position`.
- [x] Add pure renderer/parser tests. Completed 2026-05-31 in `kiroku-cli/test/Main.hs`.
- [x] Add a registry-backed integration test with a live `KirokuStore` and at least one subscription. Completed 2026-05-31 using `kiroku-test-support`'s migrated PostgreSQL fixture and the library runner against the same store.


## Surprises & Discoveries

**2026-05-31 — The existing registry view already contains all requested fields.** `kiroku-store/src/Kiroku/Store/Subscription.hs` defines `SubscriptionStateView` with `subscriptionName`, `member`, `state`, `statePhase`, and `cursor`. `cursor` is a `GlobalPosition`, which satisfies the requirement to display the current global position the worker is on.

**2026-05-31 — Stopped subscriptions must be represented by absence, not a row.** MasterPlan 7 and `docs/user/observability.md` state that the FSM never writes `Stopped` into the registry cell; a stopped, cancelled, crashed, or superseded subscription disappears from `subscriptionStates`. The CLI must not invent a `"stopped"` row for absent subscriptions.

**2026-05-31 — The existing shared PostgreSQL test fixture is enough for the CLI integration test.** `kiroku-test-support` exposes `withMigratedTestDatabase`, so `kiroku-cli-test` can open a real `KirokuStore`, start a subscription, and run `renderKirokuCommandWithStore` without depending on `kiroku-store`'s internal test module.


## Decision Log

- Decision: Implement `subscriptions status` as the initial command path.
  Rationale: The command group leaves room for later subscription operator commands while making the current status behavior explicit and discoverable.
  Date: 2026-05-31

- Decision: Render table output by default and JSON via an explicit flag.
  Rationale: Operators need a readable terminal default, while automation needs a stable machine-readable representation. Both should share one row type to avoid drift.
  Date: 2026-05-31

- Decision: Put status execution in the library runner, not the standalone executable.
  Rationale: Embedded host CLIs must get the same behavior as the standalone `kiroku` binary. The executable should only parse process options, acquire a store, and delegate.
  Date: 2026-05-31

- Decision: Use `--format table|json` instead of a single `--json` switch.
  Rationale: The status command now has an explicit output-format vocabulary that later operator commands can reuse without introducing parallel flags.
  Date: 2026-05-31


## Outcomes & Retrospective

Completed on 2026-05-31. `kiroku-cli` now parses `subscriptions status`, renders table output by default, renders JSON via `--format json`, converts `subscriptionStates` snapshots into stable sorted rows, and exposes `renderKirokuCommandWithStore` / `runKirokuCommandWithStore` for embedded host CLIs. The standalone executable still cannot run status meaningfully until EP-3 adds connection-setting acquisition; for now it shows correct leaf help and the library runner is fully tested against a live store.

Validation completed:

```text
cabal test kiroku-cli-test
11 examples, 0 failures

cabal run kiroku -- subscriptions status --help
Usage: kiroku subscriptions status [--format table|json]
Available options include --format table|json.

cabal build all
Build completed successfully.
```


## Context and Orientation

This plan depends on `docs/plans/47-bootstrap-embeddable-kiroku-cli-package-and-command-api.md`, which creates the `kiroku-cli` package and public command/parser/runner modules. The status implementation should extend those modules rather than create a second CLI entry point.

The registry source is `Kiroku.Store.Subscription.subscriptionStates` in `kiroku-store/src/Kiroku/Store/Subscription.hs`. It has this public shape:

```haskell
subscriptionStates :: KirokuStore -> IO (Map (SubscriptionName, Int32) SubscriptionStateView)
```

`SubscriptionStateView` has fields `subscriptionName :: SubscriptionName`, `member :: Int32`, `state :: SubscriptionState`, `statePhase :: Text`, and `cursor :: GlobalPosition`. The store's convention is to read record fields with `generic-lens`, for example `view ^. #statePhase`.

`SubscriptionName` is a newtype over `Text` in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`. `GlobalPosition` is a newtype over an integer position in `kiroku-store/src/Kiroku/Store/Types.hs`. The CLI row conversion should unwrap these newtypes into stable text/number values at the edge.

Tests can reuse patterns from `kiroku-store/test/Test/SubscriptionRegistry.hs`. That module starts a real migrated PostgreSQL test store with `withTestStore`, starts several subscriptions, waits until entries reach `"live"`, and reads `subscriptionStates store`. Do not duplicate helper logic unnecessarily; either keep the CLI integration test inside `kiroku-cli` with a test-support dependency or write a smaller pure test if the package boundary makes database setup too heavy. A real registry-backed test is preferred because it proves the runner consumes the actual store API.


## Plan of Work

Milestone 1 extends the command model and parser. Add a subscriptions command group to the command type from EP-1. A concrete shape is:

```haskell
data KirokuCommand
  = KirokuSubscriptions SubscriptionCommand

data SubscriptionCommand
  = SubscriptionStatus StatusOptions

data OutputFormat = OutputTable | OutputJson
```

The parser should accept `subscriptions status`, with a `--json` switch or a `--format table|json` option. Prefer `--format` if future commands are likely to share formats; prefer `--json` if the codebase values short operator flags. The parser help must mention that status reads the live in-process registry.

Milestone 2 implements row conversion and rendering. Add a module such as `Kiroku.Cli.Subscription.Status` with a row type independent of `SubscriptionStateView`, for example:

```haskell
data SubscriptionStatusRow = SubscriptionStatusRow
  { subscription :: Text
  , member :: Int32
  , phase :: Text
  , globalPosition :: Int64
  }
```

Provide a conversion from the registry snapshot to sorted rows. Sort by subscription name and member so output is stable across runs. Implement a table renderer with fixed headers `SUBSCRIPTION`, `MEMBER`, `PHASE`, and `GLOBAL_POSITION`. Implement JSON as an array of objects with lower-case field names such as `subscription`, `member`, `phase`, and `global_position`.

Milestone 3 wires runner behavior. Add a runner function that accepts an existing `KirokuStore`, reads `subscriptionStates`, renders according to options, and writes to a caller-supplied output sink or `stdout`. To keep embedding testable, prefer a pure function that returns `Text` or `ByteString` from rows, plus a small IO runner that writes the chosen output. Host CLIs should not need to capture stdout to reuse the status data.

Milestone 4 tests behavior. Pure tests should cover sorting, empty output, table headers, JSON shape, and integer extraction from `GlobalPosition`. Integration tests should start a real store, append at least one event, wait for the publisher, start a subscription, poll until the registry shows `"live"`, run the CLI status runner against the same store, and assert the output contains the subscription name, member `0`, phase `"live"`, and a non-negative global position.


## Concrete Steps

From the repository root, inspect the package foundation first:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
sed -n '1,220p' kiroku-cli/kiroku-cli.cabal
rg -n "KirokuCommand|kirokuCommandParser|runKiroku" kiroku-cli
```

Edit the `kiroku-cli` library modules created by EP-1. If a new module is introduced for status rendering, add it to `kiroku-cli/kiroku-cli.cabal` under `exposed-modules` or `other-modules` as appropriate.

Run focused tests:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal test kiroku-cli-test
```

Expected success is a passing CLI test suite that includes parser, renderer, and registry-backed status coverage.

Run the command help after EP-3 or with a test-only parser harness if EP-3 is not complete:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal run kiroku -- subscriptions status --help
```

Expected output should include the `subscriptions status` command and the output-format flag.

Run the full build:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal build all
```


## Validation and Acceptance

Acceptance is met when `cabal test kiroku-cli-test` passes and includes tests for `subscriptions status`, table rendering, JSON rendering, and at least one real `subscriptionStates` read through the CLI runner. If a database-backed integration test cannot be added inside `kiroku-cli` without creating an undesirable dependency cycle, record that in Surprises & Discoveries and add a focused `kiroku-store` or test-support-backed test that still proves the runner consumes a live `KirokuStore`.

The human table for a live non-group subscription should contain the subscription name, member `0`, a phase such as `live`, and the global position number. JSON output should be an array of objects, stable enough for scripts and golden-style tests.


## Idempotence and Recovery

Parser and renderer changes are pure and can be rerun safely. Database-backed tests should use the existing ephemeral PostgreSQL helpers so each test gets a fresh migrated store. If an integration test flakes because a subscription has not reached `"live"` yet, follow the polling pattern in `kiroku-store/test/Test/SubscriptionRegistry.hs` rather than adding a fixed sleep.


## Interfaces and Dependencies

This plan uses `kiroku-store` for `KirokuStore`, `subscriptionStates`, `SubscriptionStateView`, `SubscriptionName`, and `GlobalPosition`. It uses `containers` for `Map`, `text` for output, `aeson` for JSON, and `optparse-applicative` for parser extensions. If JSON is rendered as lazy bytestring, add the appropriate `bytestring` dependency.

The important public function at the end of this plan should have a shape close to one of these:

```haskell
runKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO ExitCode
renderSubscriptionStatusRows :: OutputFormat -> [SubscriptionStatusRow] -> Text
subscriptionStatusRows :: Map (SubscriptionName, Int32) SubscriptionStateView -> [SubscriptionStatusRow]
```

The exact names may differ, but the separation must remain: snapshot-to-rows is pure, rendering is pure, and the IO runner only reads the store and writes output.


## Revision Notes

2026-05-31: Implemented the full EP-2 status command, added parser/renderer/live-registry tests, recorded the `--format` decision, and captured validation output because the plan is now complete.
