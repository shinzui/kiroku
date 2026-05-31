---
id: 47
slug: bootstrap-embeddable-kiroku-cli-package-and-command-api
title: "Bootstrap embeddable kiroku-cli package and command API"
kind: exec-plan
created_at: 2026-05-31T17:41:53Z
intention: "intention_01kszhy0dbeqnb1hkkhkrkwmw8"
master_plan: "docs/masterplans/8-embeddable-operator-cli-for-kiroku-subscription-status.md"
---

# Bootstrap embeddable kiroku-cli package and command API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan creates the package foundation for Kiroku's operator CLI. After it is complete, the repository has a new `kiroku-cli` Cabal package with a library that host applications can import and a placeholder executable that compiles. The important outcome is not a useful operator command yet; it is the embedding contract: Kiroku exposes an `optparse-applicative` parser and command runner as normal Haskell values instead of hiding them inside `main`.

The result can be seen by running the new package's tests, building the workspace, and asking the executable for help. A later plan adds the first real `subscriptions status` command.


## Progress

- [x] 2026-05-31: Add `kiroku-cli` to the workspace and create its Cabal package.
- [x] 2026-05-31: Create the public module layout under `kiroku-cli/src/Kiroku/Cli`.
- [x] 2026-05-31: Define the root command type, parser, parser info, and runner placeholders.
- [x] 2026-05-31: Create a thin `kiroku-cli/app/Main.hs` executable that calls the exported parser and runner.
- [x] 2026-05-31: Add parser tests proving top-level and nested parser composition.
- [x] 2026-05-31: Run the package tests and `cabal build all`.


## Surprises & Discoveries

**2026-05-31 — `optparse-applicative` has no curated mori docs but local source is available.** `mori registry show pcapriotti/optparse-applicative --full` reports the source path `/Users/shinzui/Keikaku/hub/haskell/optparse-applicative-project`. Its README documents `Parser`, `ParserInfo`, `execParser`, `helper`, `subparser`, and `command`; its tests include composable command parser examples.

**2026-05-31 — Keiro does not yet provide a CLI parser to target directly.** `mori registry show shinzui/keiro --full` identifies Keiro's source at `/Users/shinzui/Keikaku/bokuno/keiro`, and a scoped search for `Options.Applicative` found no existing CLI integration point. This plan therefore defines Kiroku's own generic embedding surface.

**2026-05-31 — A host CLI needs a wrapper-aware subparser helper.** A plain `Mod CommandFields KirokuCommand` is useful only when Kiroku is the entire command sum. The implemented `kirokuSubparser :: (KirokuCommand -> command) -> Mod CommandFields command` lets a host write `subparser (hostCommand <> kirokuSubparser HostKiroku)`, which is the composition shape proven by `kiroku-cli-test`.


## Decision Log

- Decision: Create a new package named `kiroku-cli` with both a library and an executable.
  Rationale: A separate package avoids adding CLI dependencies to `kiroku-store` while still allowing the standalone executable and embedded host CLIs to share all parser and runner code.
  Date: 2026-05-31

- Decision: Export parser values and runner functions from the library.
  Rationale: Keiro or another host CLI must be able to mount Kiroku commands under its own command tree. That requires `Parser`/`ParserInfo` values and a function that runs a parsed `KirokuCommand`, not only `main :: IO ()`.
  Date: 2026-05-31

- Decision: Keep this plan's runner behavior minimal.
  Rationale: This plan is the package foundation. The first real operator command is implemented in `docs/plans/48-render-subscription-registry-status-in-the-operator-cli.md`, so this plan should compile and expose extension points without pretending the status command exists yet.
  Date: 2026-05-31

- Decision: Make `kirokuSubparser` accept a wrapper function.
  Rationale: Embedded host CLIs usually parse into their own command data type. Accepting a wrapper function keeps Kiroku's parser mountable under a host `subparser` without requiring the host to parse only `KirokuCommand`.
  Date: 2026-05-31


## Outcomes & Retrospective

Completed on 2026-05-31. The repository now has a `kiroku-cli` package with a library facade, root command type, parser entry points, wrapper-aware subparser helper, placeholder runner, thin `kiroku` executable, and parser tests. Validation passed with the focused package test, executable help, and full workspace build:

```text
cabal test kiroku-cli-test
3 examples, 0 failures
1 of 1 test suites (1 of 1 test cases) passed.
```

```text
cabal run kiroku -- --help
kiroku - operator commands for Kiroku event stores

Usage: kiroku 

  Run Kiroku operator commands.

Available options:
  -h,--help                Show this help text
```

```text
cabal build all
Build completed successfully for all configured workspace components.
```


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. It is a Cabal workspace using GHC 9.12.2. After this plan, `cabal.project` lists `kiroku-store`, `kiroku-store-migrations`, `kiroku-test-support`, `shibuya-kiroku-adapter`, `kiroku-otel`, `kiroku-jitsurei`, and `kiroku-cli`. `README.md` describes `kiroku-store` as the core library, `kiroku-store-migrations` as the migration executable, `kiroku-otel` as trace-context helpers, and `shibuya-kiroku-adapter` as the Shibuya adapter.

The CLI dependency must be `optparse-applicative`. The local dependency lookup required by `AGENTS.md` found it with:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
mori registry search optparse-applicative
mori registry show pcapriotti/optparse-applicative --full
mori registry docs pcapriotti/optparse-applicative
```

The docs command reports no curated docs, so use the dependency source under `/Users/shinzui/Keikaku/hub/haskell/optparse-applicative-project/optparse-applicative`. The README shows a parser built as `info (sample <**> helper) (...)`, and the dependency tests show command composition with `subparser (command "hello" (info hello ...))`. Kiroku should follow that shape.

This plan does not touch `/nix/store` and must not search the filesystem root. All searches stay under the repository root or the mori-reported dependency paths.


## Plan of Work

Milestone 1 creates the package shell. Add `kiroku-cli` to the `packages:` stanza in `cabal.project`. Create `kiroku-cli/kiroku-cli.cabal` with the same metadata style as the existing packages and a `common common` stanza using `GHC2024`, `DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings`. The library should expose at least these modules: `Kiroku.Cli`, `Kiroku.Cli.Command`, `Kiroku.Cli.Parser`, and `Kiroku.Cli.Run`. Add an executable named `kiroku` with `main-is: Main.hs` and `hs-source-dirs: app`. Add a test suite `kiroku-cli-test` with `main-is: Main.hs` and `hs-source-dirs: test`.

Milestone 2 defines the embeddable API. Create `kiroku-cli/src/Kiroku/Cli/Command.hs` with a root command type. At this point it can be deliberately small, for example `data KirokuCommand = KirokuNoCommand`, or a placeholder constructor representing a future command group. Create `Kiroku.Cli.Parser` exporting both a bare command parser and a root `ParserInfo`:

```haskell
kirokuCommandParser :: Parser KirokuCommand
kirokuParserInfo :: ParserInfo KirokuCommand
```

Also expose a nested parser helper suitable for host CLIs, for example:

```haskell
kirokuSubparser :: (KirokuCommand -> command) -> Mod CommandFields command
```

The public API makes it possible for a host to write a larger `subparser` containing Kiroku's command by passing the host's wrapper constructor, such as `kirokuSubparser HostKiroku`.

Milestone 3 defines runner placeholders without store semantics. Create `Kiroku.Cli.Run` with a function such as:

```haskell
runKirokuCommand :: KirokuCommand -> IO ()
```

This initial runner may print help-oriented text or return an error for the placeholder command. Do not connect to PostgreSQL in this plan; EP-3 owns standalone connection settings.

Milestone 4 wires the executable. `kiroku-cli/app/Main.hs` should import `Kiroku.Cli` and `Options.Applicative` and call `execParser kirokuParserInfo >>= runKirokuCommand`. Keep `main` as a tiny wrapper so later plans cannot accidentally fork parser behavior between library and executable.

Milestone 5 tests parser composition. Add `kiroku-cli/test/Main.hs` using `hspec` or the repository's existing test style. Use `execParserPure defaultPrefs` from `optparse-applicative` to prove the root parser produces help and that the Kiroku parser can be nested under another host parser. A useful nested test shape is a fake host parser with commands `"host"` and `"kiroku"`; parsing `["kiroku", "--help"]` should invoke Kiroku help rather than failing as an unknown host command.


## Concrete Steps

From the repository root, create the package directories:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
mkdir -p kiroku-cli/src/Kiroku/Cli kiroku-cli/app kiroku-cli/test
```

Edit `cabal.project` and add `kiroku-cli` to the `packages:` list.

Create `kiroku-cli/kiroku-cli.cabal`, the source modules, executable `Main.hs`, and test `Main.hs`. Prefer record-field access through the existing `generic-lens`/`OverloadedLabels` style only if records are introduced; keep the initial command types simple.

Run the focused package checks:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal test kiroku-cli-test
cabal run kiroku -- --help
```

The expected result is that the test suite exits successfully and the executable prints generated help for the Kiroku command surface. The exact help text will depend on the parser names chosen during implementation.

Run the workspace build:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal build all
```

The expected result is a successful build of all existing packages plus `kiroku-cli`.


## Validation and Acceptance

Acceptance is met when `kiroku-cli` is listed in `cabal.project`, `cabal test kiroku-cli-test` passes, `cabal run kiroku -- --help` displays generated `optparse-applicative` help, and `cabal build all` succeeds.

The test suite must include an assertion that the Kiroku parser can be composed under a host parser with `subparser`/`command`. This is the behavioral proof for the user's embedding requirement at the package-foundation stage.


## Idempotence and Recovery

Creating the package directories is idempotent with `mkdir -p`. Re-running Cabal commands is safe. If the package layout is wrong, edit the Cabal file and rerun `cabal test kiroku-cli-test`; Cabal's error messages will point to missing modules or dependency declarations. Do not remove or rewrite existing package files outside `kiroku-cli` except the one-line workspace addition in `cabal.project`.


## Interfaces and Dependencies

Use `optparse-applicative` for all parsing. The Cabal dependency should be bounded consistently with the registered local version, for example `optparse-applicative >=0.19 && <0.20`, unless the local solver requires a broader bound.

The library should expose `Kiroku.Cli` as a facade re-exporting the command type, parser entry points, and runner. The executable should import only the facade and `Options.Applicative`.

This plan should not depend on `kiroku-store` yet unless the chosen runner type mentions `KirokuStore`; if it does mention `KirokuStore`, keep that dependency in the library and still avoid opening a store here. EP-2 and EP-3 will necessarily depend on `kiroku-store`.


## Revision Notes

2026-05-31: Implemented the plan, recorded validation evidence, and updated the parser-helper description from a bare `Mod CommandFields KirokuCommand` example to the final wrapper-aware API needed by host CLIs.
