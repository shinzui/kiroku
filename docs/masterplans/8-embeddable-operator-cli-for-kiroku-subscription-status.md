---
id: 8
slug: embeddable-operator-cli-for-kiroku-subscription-status
title: "Embeddable operator CLI for Kiroku subscription status"
kind: master-plan
created_at: 2026-05-31T17:41:49Z
intention: "intention_01kszhy0dbeqnb1hkkhkrkwmw8"
---

# Embeddable operator CLI for Kiroku subscription status

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Kiroku needs an operator-facing command line surface for day-to-day runtime questions. The first useful operator command is subscription status: list every live subscription, show its current finite-state-machine phase, and show the live global cursor position reported by the subscription-state registry introduced by `docs/masterplans/7-subscription-state-registry-and-complete-fsm-state-observability.md`.

After this initiative, the repository contains a new `kiroku-cli` package with both a library and a standalone executable. The library is the primary artifact: it exposes an `optparse-applicative` parser, a command data type, a pure renderer, and runner functions that accept an existing `KirokuStore`. A host application such as Keiro can import this library and mount Kiroku operator subcommands under its own CLI without re-parsing Kiroku internals or forking a separate process. The standalone executable is a thin wrapper around that same library, so `kiroku subscriptions status` behaves the same as the embedded command when it is given a store handle from the current process.

The status command reads `Kiroku.Store.Subscription.subscriptionStates`, which returns a `Map (SubscriptionName, Int32) SubscriptionStateView`. Each row includes the subscription name, consumer-group member, stable state label such as `"live"` or `"reconnecting"`, and the `GlobalPosition` cursor. The command renders a readable table by default and a JSON form for scripts.

The in-memory nature of the registry is a scope boundary. A standalone process that only connects to the same PostgreSQL database cannot inspect another already-running service's in-memory `KirokuStore.subscriptionRegistry`. Therefore the standalone executable is useful for commands that operate on the store it opens itself, and for validating the CLI wiring, but live subscription status is authoritative only when the CLI is embedded in the process that owns the subscriptions or when a future remote admin endpoint exposes that process's registry. This initiative does not build such a remote endpoint, a Prometheus exporter, a terminal UI, durable subscription-state storage, or Keiro's full CLI. It creates the Kiroku CLI package and proves the embedding contract Keiro can consume later.


## Decomposition Strategy

The work splits into four child plans by functional concern.

EP-1 bootstraps the package and command API. It creates the `kiroku-cli` package, adds it to `cabal.project`, declares the `optparse-applicative` dependency discovered through `mori` at `mori://pcapriotti/optparse-applicative/packages/optparse-applicative`, and defines the public command/parser/runner modules. This is the hard foundation for every later plan.

EP-2 implements the subscription status behavior over the registry snapshot. It owns the domain-specific command, output rows, table rendering, JSON rendering, and tests over constructed `SubscriptionStateView` values. It depends on EP-1's command and module structure.

EP-3 wires the standalone executable. It owns process entry, connection-setting flags and environment fallbacks, `withStore`, exit behavior, and help text. It depends on EP-1's executable skeleton and EP-2's runnable status command.

EP-4 documents and demonstrates embedded usage. It owns README/user docs and a small compile-tested embedding example that shows a host CLI importing the parser and running against an already-live `KirokuStore`. It depends on the API and behavior from EP-1 through EP-3.

Alternatives considered and rejected: putting the executable into `kiroku-store` was rejected because it would mix operator UI dependencies into the core store package and make embedding awkward. Creating only a standalone executable was rejected because it cannot satisfy the Keiro embedding requirement and cannot observe another process's in-memory registry. Building a remote admin service now was rejected because the user asked to bootstrap the CLI and registry-backed status, not to introduce a new server protocol.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Bootstrap embeddable kiroku-cli package and command API | docs/plans/47-bootstrap-embeddable-kiroku-cli-package-and-command-api.md | None | None | Complete |
| 2 | Render subscription registry status in the operator CLI | docs/plans/48-render-subscription-registry-status-in-the-operator-cli.md | EP-1 | None | Complete |
| 3 | Wire standalone kiroku executable to store connection settings | docs/plans/49-wire-standalone-kiroku-executable-to-store-connection-settings.md | EP-1, EP-2 | None | Not Started |
| 4 | Document and demonstrate embedded Kiroku CLI usage | docs/plans/50-document-and-demonstrate-embedded-kiroku-cli-usage.md | EP-1, EP-2 | EP-3 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 must land first because it creates the `kiroku-cli` package, module names, command type, and public parser/runner API that the later plans extend. EP-2 depends on EP-1 because it adds the first real subcommand and tests inside the package EP-1 creates. EP-3 depends on both EP-1 and EP-2 because the standalone executable should be a thin wrapper around already-defined command behavior, not a separate implementation. EP-4 depends on EP-1 and EP-2 because embedded documentation must reference real exported symbols and real status output; it has a soft dependency on EP-3 so the docs can mention the standalone executable once its flags are final.

There is no parallel implementation before EP-1 completes. After EP-1, EP-2 can proceed independently; EP-3 should wait for EP-2's status runner; EP-4 can begin after EP-2 but should be finalized after EP-3's CLI flags settle.


## Integration Points

**`kiroku-cli/kiroku-cli.cabal` and `cabal.project`.** EP-1 creates the new package, adds it to the workspace, and declares the core dependencies. EP-2 adds any renderer/test dependencies such as `aeson` or `containers` if EP-1 did not already include them. EP-3 adds executable-only dependencies if needed. Later plans must preserve the package split: public embedding code belongs in the library, while `app/Main.hs` remains a thin standalone wrapper.

**Public CLI modules under `kiroku-cli/src/Kiroku/Cli`.** EP-1 owns the module layout and exported API. The implemented surface is `Kiroku.Cli` as the import-friendly facade, `Kiroku.Cli.Command` for the command data type, `Kiroku.Cli.Parser` for `optparse-applicative` parsers, and `Kiroku.Cli.Run` for command execution. The embedding helper is `kirokuSubparser :: (KirokuCommand -> command) -> Mod CommandFields command`, so a host can wrap Kiroku commands into its own command sum. EP-2 extends the command type with subscription status behavior and adds renderer modules. EP-3 consumes the parser and runner from `app/Main.hs`. EP-4 documents these exact imports.

**`Kiroku.Store.Subscription.subscriptionStates` and `SubscriptionStateView`.** EP-2 is responsible for turning the registry snapshot into operator rows. It must treat the registry as process-local: presence means live, absence means not live, and `"stopped"` must not be invented because MasterPlan 7 documents stopped subscriptions as absent. EP-3 and EP-4 must repeat that limitation in user-facing text so operators do not expect a separate process to inspect another service's in-memory registry.

**`optparse-applicative` parser composition.** EP-1 defines composable parsers rather than hiding everything behind `execParser`. EP-3 may use `execParser` or `customExecParser` in the executable, but the library exports `kirokuCommandParser`, `kirokuParserInfo`, and `kirokuSubparser`, which another CLI can mount under its own `subparser`. This is the central embedding contract.

**Documentation surfaces.** EP-4 updates the repository-level README and user docs. If EP-3 changes flag names, EP-4 must consume the final names. The docs must distinguish embedded status, which can see live subscriptions in the host process, from standalone status, which only sees the `KirokuStore` opened by the standalone command.


## Progress

- [x] EP-1: create the `kiroku-cli` library/executable package, add it to `cabal.project`, and expose the command/parser/runner foundation.
- [x] EP-1: add parser-level tests proving the Kiroku parser can be used both as a top-level parser and as a nested subcommand.
- [x] EP-2: implement subscription status rows from `subscriptionStates`, including state phase and global cursor.
- [x] EP-2: implement table and JSON output plus renderer tests.
- [ ] EP-3: implement the standalone `kiroku` executable with connection settings, help text, and process-local status semantics.
- [ ] EP-3: validate `cabal run kiroku -- subscriptions status --help` and the empty-registry runtime path.
- [ ] EP-4: document standalone and embedded usage, including the in-memory registry limitation.
- [ ] EP-4: add a compile-tested embedding example for host CLIs such as Keiro.


## Surprises & Discoveries

**2026-05-31 — The subscription registry is process-local, which shapes the CLI contract.** `KirokuStore` owns `subscriptionRegistry :: TVar (Map (SubscriptionName, Int32) (Unique, TVar SubscriptionState))` in `kiroku-store/src/Kiroku/Store/Connection.hs`, initialized by `withStore` and populated by `subscribe` in `kiroku-store/src/Kiroku/Store/Subscription.hs`. It is not stored in PostgreSQL. Therefore a separately launched `kiroku` process cannot see subscriptions running in a different service process. The CLI must be embeddable-first for live status, and the standalone executable must be honest about this limitation.

**2026-05-31 — `optparse-applicative` supports the exact composition shape required.** The local dependency source at `/Users/shinzui/Keikaku/hub/haskell/optparse-applicative-project/optparse-applicative` documents `Parser`, `ParserInfo`, `subparser`, `command`, `helper`, `execParser`, and `customExecParser`. The tests under `optparse-applicative/tests/Examples/Commands.hs` show nested command parsers built from `subparser (command "..." (info ...))`, which is the pattern Kiroku should expose for Keiro.

**2026-05-31 — Keiro currently has no CLI parser to integrate with.** `mori registry show shinzui/keiro --full` found the Keiro repository at `/Users/shinzui/Keikaku/bokuno/keiro`, and a scoped search for `Options.Applicative`/`execParser` found no existing Keiro CLI package. This MasterPlan should therefore provide a generic embedding API and a local example, not modify Keiro directly.

**2026-05-31 — EP-1 settled the subparser helper as wrapper-aware.** The implemented `kirokuSubparser :: (KirokuCommand -> command) -> Mod CommandFields command` is more directly embeddable than a bare `Mod CommandFields KirokuCommand` because host CLIs usually parse into their own command type. `kiroku-cli-test` proves `subparser (hostCommand <> kirokuSubparser HostKiroku)` works.

**2026-05-31 — EP-2 can integration-test live status without copying store test internals.** `kiroku-test-support` exposes `withMigratedTestDatabase`, which is sufficient for `kiroku-cli-test` to open a real store, start a subscription, wait for `"live"` in the registry, and render status through the embeddable runner.


## Decision Log

- Decision: Create a separate `kiroku-cli` package rather than adding an executable to `kiroku-store`.
  Rationale: The CLI needs `optparse-applicative`, renderers, and embedding modules that should not become part of the core event-store library's dependency surface. A separate package lets standalone users build the executable while host CLIs depend only on the embeddable library.
  Date: 2026-05-31

- Decision: Make the library API the source of truth and make the standalone executable a thin wrapper.
  Rationale: The user explicitly requires the CLI to run on its own or be embedded in another CLI such as Keiro. A parser and runner exported from the library satisfy both; an executable-only design would duplicate code or make embedding impossible.
  Date: 2026-05-31

- Decision: Treat subscription status as process-local in the first CLI.
  Rationale: The registry introduced by MasterPlan 7 is in-memory on `KirokuStore`; it is not durable or remotely queryable. Accurately listing live subscriptions requires running inside the process that owns the subscriptions, so the embedded path is the authoritative status path.
  Date: 2026-05-31

- Decision: Plan for both table and JSON output in the first status command.
  Rationale: Operators need a readable default at a terminal, while automation and tests need a stable machine-readable form. Both render from the same row type, keeping behavior shared.
  Date: 2026-05-31

- Decision: Use a wrapper-aware `kirokuSubparser` for embedding.
  Rationale: Host CLIs such as Keiro need to wrap parsed Kiroku commands into their own command data type. Accepting the wrapper function keeps the embedding helper reusable without sacrificing the standalone parser.
  Date: 2026-05-31

- Decision: Use `--format table|json` for subscription status output selection.
  Rationale: A named format option makes the output contract explicit and leaves room for future operator commands to share the same option vocabulary.
  Date: 2026-05-31


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revision Notes

2026-05-31: Marked EP-1 complete, recorded its wrapper-aware parser helper decision, and propagated that API shape to the EP-4 embedding-example guidance.

2026-05-31: Marked EP-2 complete after adding `subscriptions status`, table and JSON renderers, an embeddable store-backed runner, parser/renderer tests, and a live-registry integration test.
