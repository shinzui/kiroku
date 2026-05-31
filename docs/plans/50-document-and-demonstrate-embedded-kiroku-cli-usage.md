---
id: 50
slug: document-and-demonstrate-embedded-kiroku-cli-usage
title: "Document and demonstrate embedded Kiroku CLI usage"
kind: exec-plan
created_at: 2026-05-31T17:42:18Z
intention: "intention_01kszhy0dbeqnb1hkkhkrkwmw8"
master_plan: "docs/masterplans/8-embeddable-operator-cli-for-kiroku-subscription-status.md"
---

# Document and demonstrate embedded Kiroku CLI usage

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan makes the new CLI understandable and safe to adopt. After this change, repository docs explain how to run the standalone `kiroku` executable and how a host application such as Keiro can embed Kiroku's operator subcommands under its own CLI while passing the host's live `KirokuStore`.

The most important documentation outcome is clarity about live subscription status. The status command reads an in-memory registry on the current process's store handle. Embedded use is therefore the authoritative way for a host service to expose its own live subscriptions. A separately launched standalone process cannot inspect another service process's registry unless a future remote endpoint is added.


## Progress

- [ ] Update repository/package docs to mention `kiroku-cli` and the standalone executable.
- [ ] Add a user doc for operator CLI usage.
- [ ] Document `subscriptions status` table and JSON output.
- [ ] Document the process-local registry limitation prominently.
- [ ] Add a compile-tested embedding example showing a host CLI mounting Kiroku commands.
- [ ] Validate docs examples by building/tests.


## Surprises & Discoveries

**2026-05-31 — There is already a user-facing observability doc to link.** `docs/user/observability.md` explains `subscriptionStates`, `SubscriptionStateView`, state phases, cursor semantics, and the fact that stopped subscriptions are absent. The CLI docs should link to it instead of duplicating the whole registry design.

**2026-05-31 — README currently lists four packages and must be updated.** `README.md` lists `kiroku-store`, `kiroku-store-migrations`, `kiroku-otel`, and `shibuya-kiroku-adapter`. After EP-1 creates `kiroku-cli`, this plan should add it to the package list and repository layout.


## Decision Log

- Decision: Document embedded usage as first-class, not an advanced aside.
  Rationale: The user's crucial requirement is that Kiroku's CLI can be embedded in another CLI such as Keiro. The docs should lead with the library API and explain the standalone executable as a wrapper.
  Date: 2026-05-31

- Decision: Include a compile-tested host embedding example inside `kiroku-cli`.
  Rationale: A prose snippet can drift. A small example or test module proves that the exported parser and runner are sufficient for a host CLI to mount Kiroku commands.
  Date: 2026-05-31

- Decision: Keep Keiro modifications out of scope.
  Rationale: The Keiro repo currently has no CLI parser integration point, and this MasterPlan is for Kiroku. Kiroku should provide a stable embedding contract; Keiro can consume it in its own later work.
  Date: 2026-05-31


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan depends on the CLI package from `docs/plans/47-bootstrap-embeddable-kiroku-cli-package-and-command-api.md` and the status command from `docs/plans/48-render-subscription-registry-status-in-the-operator-cli.md`. It should be finalized after `docs/plans/49-wire-standalone-kiroku-executable-to-store-connection-settings.md` settles standalone flag names.

The relevant existing docs are:

- `README.md`, which lists packages and common development commands.
- `docs/user/README.md`, which indexes user documentation.
- `docs/user/observability.md`, which explains `subscriptionStates` and the subscription-state registry.
- `docs/user/subscriptions.md`, which explains subscription lifecycle and state meanings.

The Keiro project is registered as `mori://shinzui/keiro` at `/Users/shinzui/Keikaku/bokuno/keiro`, but this plan should not edit Keiro. It only documents how a host CLI would import Kiroku's parser and runner.


## Plan of Work

Milestone 1 updates package-level docs. Add `kiroku-cli` to `README.md` under "What It Provides" and "Repository Layout". Mention that it supplies an embeddable CLI library plus the standalone `kiroku` executable.

Milestone 2 adds user documentation. Create a new page such as `docs/user/operator-cli.md` and link it from `docs/user/README.md`. The page should show standalone commands:

```bash
kiroku subscriptions status
kiroku subscriptions status --format json
```

Use the final flag names from EP-3 for database settings. Show representative table output with columns for subscription, member, phase, and global position. Show representative JSON output as a short array of objects.

Milestone 3 explains status semantics. In the operator CLI doc, state that `subscriptions status` reads `subscriptionStates store`, which is an in-memory registry on the current `KirokuStore`. Explain that stopped/cancelled/crashed subscriptions disappear rather than appearing as `"stopped"`, and that `global_position` is the FSM cursor, not a durable checkpoint guarantee. Link to `docs/user/observability.md` for the detailed registry model.

Milestone 4 adds a compile-tested embedding example. Prefer a small test module in `kiroku-cli/test/Main.hs` or `kiroku-cli/test/Test/Embedding.hs` that defines a host command type, mounts Kiroku's parser under a host `subparser`, and runs the parsed Kiroku command against a supplied `KirokuStore` function. It does not need to start Keiro. It should prove the exported API supports this shape:

```haskell
data HostCommand
  = HostOwnCommand
  | HostKiroku KirokuCommand
```

The test should parse a command like `["kiroku", "subscriptions", "status", "--format", "json"]` and produce `HostKiroku ...`. If a live-store runner is too heavy for this test, keep runner validation in EP-2/EP-3 and use this test to prove parser embedding.

EP-1 implemented the embedding helper as `kirokuSubparser :: (KirokuCommand -> command) -> Mod CommandFields command`, so the host example should mount Kiroku with the wrapper constructor, for example `kirokuSubparser HostKiroku`.

Milestone 5 validates docs and examples. Run the CLI tests and build all packages. If the repository has a markdown lint command in `Justfile`, run it; otherwise inspect the new Markdown for bare code fences and broken local links.


## Concrete Steps

Read the final CLI API and flags after EP-1 through EP-3:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
rg -n "kirokuParser|kirokuSubparser|runKirokuCommand|subscriptions status|database-url|format" kiroku-cli
sed -n '1,180p' README.md
sed -n '1,220p' docs/user/README.md
sed -n '120,210p' docs/user/observability.md
```

Edit `README.md`, add or update `docs/user/operator-cli.md`, update `docs/user/README.md`, and add the embedding parser test in `kiroku-cli/test` if it does not already exist.

Run focused tests:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal test kiroku-cli-test
```

Run the workspace build:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal build all
```

Optionally run formatting if the repository exposes it:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
just fmt
```

Only run `just fmt` if it is available and appropriate for the changed files.


## Validation and Acceptance

Acceptance is met when the README lists `kiroku-cli`, user docs explain standalone and embedded use, the docs clearly state the process-local registry limitation, and `cabal test kiroku-cli-test` plus `cabal build all` pass.

The embedding example must compile or be covered by tests. The docs must contain no bare Markdown fences; all command/output snippets use language tags such as `bash`, `haskell`, `json`, or `text`.


## Idempotence and Recovery

Documentation edits are safe to repeat. If final flag names change in EP-3, update all command snippets in one pass with `rg "subscriptions status|database-url|format" README.md docs/user kiroku-cli/test`. If the embedding test fails because exported function names changed, prefer updating the docs and test to the final API over adding compatibility aliases solely for the test.


## Interfaces and Dependencies

The docs should reference the public `Kiroku.Cli` facade created by EP-1 and extended by EP-2. The embedding example should import `Options.Applicative` and `Kiroku.Cli`, not internal modules unless the facade deliberately omits parser helpers.

The example should show the host application passing an existing `KirokuStore` to Kiroku's runner. It should not create a second store in the host process for live status, because that would create a separate empty registry and defeat the point of embedding.


## Revision Notes

2026-05-31: Updated the embedding-example guidance after EP-1 finalized `kirokuSubparser` as a wrapper-aware helper that accepts the host command constructor.
