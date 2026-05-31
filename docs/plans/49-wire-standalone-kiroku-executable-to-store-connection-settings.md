---
id: 49
slug: wire-standalone-kiroku-executable-to-store-connection-settings
title: "Wire standalone kiroku executable to store connection settings"
kind: exec-plan
created_at: 2026-05-31T17:42:01Z
intention: "intention_01kszhy0dbeqnb1hkkhkrkwmw8"
master_plan: "docs/masterplans/8-embeddable-operator-cli-for-kiroku-subscription-status.md"
---

# Wire standalone kiroku executable to store connection settings

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan makes the standalone `kiroku` executable usable. After it is complete, an operator can run `kiroku subscriptions status` with connection options or environment defaults, the executable opens a `KirokuStore`, delegates to the same library runner used by embedded CLIs, and exits with a sensible status code.

The live subscription registry is process-local. Therefore the standalone executable cannot inspect subscriptions running inside a different already-running service process. This plan must make that limitation visible in help text and empty-status output while still proving the executable wiring works and shares behavior with the embeddable API.


## Progress

- [x] Add standalone process options for database connection, schema, pool size, and output behavior. Completed 2026-05-31 with `--database-url`, `--schema`, `--pool-size`, and the existing `subscriptions status --format table|json` option.
- [x] Parse process options together with the shared `KirokuCommand`. Completed 2026-05-31 in `Kiroku.Cli.Standalone.standaloneOptionsParser`.
- [x] Build `ConnectionSettings` from flags and environment defaults. Completed 2026-05-31 with `resolveStandaloneOptions`, including `KIROKU_DATABASE_URL` fallback and flag precedence.
- [x] Open `withStore` and delegate to the library status runner. Completed 2026-05-31 in `runStandaloneCommand`; the executable only resolves process setup, catches boundary exceptions, and prints output.
- [x] Return meaningful exit codes for parse errors, connection failures, and successful empty status. Completed 2026-05-31: optparse handles parse failures, missing database settings and store exceptions exit non-zero, and empty status exits success with explanatory table-mode text.
- [x] Add tests for option parsing and empty-registry standalone behavior. Completed 2026-05-31 with `standaloneParserInfo`, `resolveStandaloneOptions`, and migrated-store `runStandaloneCommand` tests in `kiroku-cli/test/Main.hs`.
- [x] Validate `cabal run kiroku -- subscriptions status --help` and a runtime invocation against a migrated test database. Completed 2026-05-31; the runtime path is covered by the migrated-store standalone test, and manual executable help/missing-configuration checks passed.


## Surprises & Discoveries

**2026-05-31 — Existing migration executable uses Codd settings, but store acquisition does not run migrations.** `kiroku-store-migrations/app/Main.hs` calls `getCoddSettings` and `runKirokuMigrationsNoCheck`; `kiroku-store/src/Kiroku/Store/Connection.hs` documents that `withStore` assumes migrations already exist. The standalone status command should not silently run migrations.

**2026-05-31 — Store connection settings already cover the required runtime knobs.** `Kiroku.Store.Connection.defaultConnectionSettings` takes a PostgreSQL connection string and provides `schema`, `poolSize`, `extraSearchPath`, `idleInTransactionTimeout`, `statementTimeout`, `observationHandler`, `eventHandler`, and `storeSettings`. The CLI only needs a small subset for status.

**2026-05-31 — The standalone runtime can be tested below `main` without process spawning.** `Kiroku.Cli.Standalone.runStandaloneCommand` accepts resolved settings, opens `withStore`, and returns `Text`, so the test suite can exercise the same runtime path against `kiroku-test-support`'s migrated PostgreSQL fixture without shelling out to `cabal run`.


## Decision Log

- Decision: Do not run migrations from `kiroku subscriptions status`.
  Rationale: Status is an operator read command. Running schema migrations as a side effect would be surprising and could be unsafe in production. The existing `kiroku-store-migrate` executable remains responsible for schema management.
  Date: 2026-05-31

- Decision: Treat an empty registry as success.
  Rationale: An empty live registry can mean there are no subscriptions in this process, and for standalone status it is also the expected result when no subscriptions were started by that process. It should not be an error, but the output/help should explain the process-local semantics.
  Date: 2026-05-31

- Decision: Keep standalone flags separate from embedded command parsing.
  Rationale: Host CLIs such as Keiro already own their process configuration and can pass an existing `KirokuStore`. The Kiroku library parser should not force standalone-only database flags into embedded command trees.
  Date: 2026-05-31

- Decision: Put standalone process setup in `Kiroku.Cli.Standalone`.
  Rationale: Keeping option parsing, environment resolution, settings construction, and `withStore` delegation below `app/Main.hs` makes the standalone behavior directly testable while preserving `app/Main.hs` as a process-boundary wrapper.
  Date: 2026-05-31


## Outcomes & Retrospective

Completed on 2026-05-31. The `kiroku` executable now parses standalone database options, resolves `KIROKU_DATABASE_URL`, opens a `KirokuStore` with configurable schema and pool size, and delegates subscription status rendering through the same library code used by embedded callers. Table-mode empty status includes a process-local registry explanation; JSON mode remains stable JSON.

Validation completed:

```text
cabal test kiroku-cli-test
16 examples, 0 failures

cabal run kiroku -- subscriptions status --help
Usage: kiroku subscriptions status [--format table|json]
Available options include --format table|json.

cabal run kiroku -- --help
Shows --database-url, --schema, --pool-size, and the process-local registry description.

cabal run kiroku -- subscriptions status
Exited non-zero and printed: missing database connection string; pass --database-url or set KIROKU_DATABASE_URL.

cabal build all
Build completed successfully.
```


## Context and Orientation

This plan depends on `docs/plans/47-bootstrap-embeddable-kiroku-cli-package-and-command-api.md` and `docs/plans/48-render-subscription-registry-status-in-the-operator-cli.md`. EP-1 creates `kiroku-cli/app/Main.hs` and the shared parser/runner API. EP-2 adds `subscriptions status` and a runner that can operate against an existing `KirokuStore`.

The store is acquired with `withStore` from `kiroku-store/src/Kiroku/Store/Connection.hs`. A typical settings value starts from:

```haskell
defaultConnectionSettings connString
```

and can override `schema` or `poolSize` through record updates or `generic-lens`. `withStore` starts a pool, notifier, publisher, and a fresh empty in-memory subscription registry. Because the registry starts empty and is populated only by `subscribe` calls in the same process, a standalone `kiroku subscriptions status` invocation will usually show no live subscriptions unless this executable also starts subscriptions in the future.

`kiroku-store-migrations` is a separate package and executable. Do not mix migration behavior into this status command.


## Plan of Work

Milestone 1 defines standalone process options. Add a module such as `Kiroku.Cli.Standalone` or extend `Kiroku.Cli.Parser` with a standalone-only parser. The standalone options should include:

- connection string from `--database-url URL` or an environment variable such as `KIROKU_DATABASE_URL`;
- schema from `--schema SCHEMA`, defaulting to `kiroku`;
- pool size from `--pool-size INT`, defaulting to a small value suitable for an operator command, for example `2`;
- the shared `KirokuCommand` parser from EP-1/EP-2.

Avoid putting these options in the embedded parser. Host CLIs should pass a `KirokuStore` directly.

Milestone 2 builds settings and delegates. In `kiroku-cli/app/Main.hs`, parse standalone options, construct `ConnectionSettings`, call `withStore settings`, and then call the shared runner from EP-2. Keep all command behavior in the library; the executable should only handle process setup and exception-to-exit-code translation.

Milestone 3 handles empty status and failures. If the status command returns no rows, print a clear empty table or JSON array and include a short note in table mode that the live registry is process-local. Do not print the note in JSON mode because scripts need stable JSON. If connection acquisition fails, print the exception to stderr and exit non-zero. Successful empty status exits zero.

Milestone 4 tests and validates. Add parser tests for environment/flag precedence if the parsing layer is pure enough. Add an integration or smoke test that opens a migrated ephemeral store and runs the standalone runner for `subscriptions status`, observing empty output and exit success. If invoking the actual executable in tests is too heavy, test the standalone function below `main` and validate the executable manually with `cabal run`.


## Concrete Steps

Inspect the current CLI package first:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
sed -n '1,220p' kiroku-cli/kiroku-cli.cabal
sed -n '1,200p' kiroku-cli/app/Main.hs
rg -n "subscriptions status|runKirokuCommandWithStore|ConnectionSettings" kiroku-cli
```

Edit `kiroku-cli` modules and, if new modules are created, update `kiroku-cli/kiroku-cli.cabal`.

Run focused tests:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal test kiroku-cli-test
```

Run help:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal run kiroku -- subscriptions status --help
```

Expected output includes the status command, output-format option, and enough description to understand that status reads the live in-process registry.

Run a smoke invocation against a migrated local database if available:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal run kiroku -- --database-url "$KIROKU_DATABASE_URL" --schema kiroku subscriptions status
```

Expected table-mode output has headers and either live subscription rows or an empty-registry message. A connection error should exit non-zero and report the connection problem.

Run the full build:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal build all
```


## Validation and Acceptance

Acceptance is met when `cabal test kiroku-cli-test` passes, `cabal run kiroku -- subscriptions status --help` works, and a runtime invocation against a migrated database exits zero with empty status output when no subscriptions are running in the standalone process. `cabal build all` must succeed.

The executable must delegate to the same library command runner used by embedding. No command-specific subscription-status logic should live only in `app/Main.hs`.


## Idempotence and Recovery

Re-running the executable is safe because status is read-only. It opens and closes its own `KirokuStore` with bracket semantics. Failed connection attempts do not modify the database. If a test database has not been migrated, the command should fail with a database error rather than trying to create schema objects.


## Interfaces and Dependencies

Use `Kiroku.Store.Connection.defaultConnectionSettings` and `withStore` from `kiroku-store`. Use `optparse-applicative` for process flags and command parsing. Use `System.Environment.lookupEnv` if environment fallback is implemented outside the parser; keep that logic small and testable.

The final executable structure should remain close to:

```haskell
main :: IO ()
main = do
  opts <- execParser standaloneParserInfo
  settings <- buildConnectionSettings opts
  withStore settings $ \store ->
    runKirokuCommandWithStore store (optsCommand opts)
```

If the runner returns `ExitCode`, `main` should call `exitWith` after printing output. If the runner throws exceptions, catch only at the process boundary and leave embedded callers free to choose their own error handling.


## Revision Notes

2026-05-31: Implemented standalone process option parsing, environment resolution, settings construction, `withStore` delegation, empty-registry messaging, tests, and validation evidence because the plan is now complete.
