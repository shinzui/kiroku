---
id: 17
slug: add-nix-build-using-shared-haskell-nix
title: "Add Nix build using shared haskell-nix"
kind: exec-plan
created_at: 2026-05-16T19:31:51Z
intention: "intention_01krs49hsze77rydzy1qpcdqkv"
---

# Add Nix build using shared haskell-nix

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku currently provides a `nix develop` shell, but its flake does not expose buildable Haskell packages. The `Justfile` already has `nix-build` defined as `nix build .#kiroku-store`, so a user can ask Nix to build `kiroku-store`, but the flake has no `packages.kiroku-store` output for that command to resolve.

After this change, Kiroku uses the shared `/Users/shinzui/Keikaku/bokuno/haskell-nix` flake in the same style as `/Users/shinzui/Keikaku/bokuno/rei-project/rei` and `/Users/shinzui/Keikaku/bokuno/mori-project/mori`. A user can run `just nix-build` or `nix build .#kiroku-store` from the repository root and get a real Nix-built Haskell library. The shared `haskell-nix` input supplies cross-project Haskell package fixes for GHC 9.12.2, while a small Kiroku-local Haskell overlay tells Nix how to build the repository's local Cabal packages.


## Progress

- [x] Add `haskell-nix` as a flake input and thread it through `outputs`. Completed 2026-05-16T19:44:00Z.
- [x] Add `nix/haskell-overlay.nix` with Kiroku-local `callCabal2nix` package definitions. Completed 2026-05-16T19:44:00Z.
- [x] Change `flake.nix` to build `haskellPackages` from shared `haskell-nix` plus the local overlay. Completed 2026-05-16T19:44:00Z.
- [x] Expose package outputs for `kiroku-store`, `kiroku-store-migrations`, `shibuya-kiroku-adapter`, `kiroku-otel`, and a conservative `default`. Completed 2026-05-16T19:44:00Z.
- [x] Update the development shell to use the composed Haskell package set for GHC and HLS. Completed 2026-05-16T19:44:00Z.
- [x] Add the smallest needed local dependency overlay for `hasql-notifications`, discovered during Nix validation. Completed 2026-05-16T19:52:00Z.
- [x] Add local Nix pins for `codd` and current `shibuya-core`, discovered during package-output validation. Completed 2026-05-16T20:05:00Z.
- [x] Update `shibuya-kiroku-adapter` for the current Shibuya `Envelope.attributes` field. Completed 2026-05-16T20:05:00Z.
- [x] Update `kiroku-store`'s Shibuya overhead benchmark for `Envelope.attributes`. Completed 2026-05-16T20:10:00Z.
- [x] Keep Cabal's aggregate `build all` focused on Kiroku targets by disabling upstream `codd` tests and benchmarks. Completed 2026-05-16T20:10:00Z.
- [x] Run formatting and Nix validation, then record any follow-up decisions or failures in this plan. Completed 2026-05-16T20:13:00Z.


## Surprises & Discoveries

- `nix build .#kiroku-store` cannot see a new overlay file until it is staged in Git. Flakes evaluate the Git-tracked view of the repository, so untracked files referenced from `flake.nix` are invisible. Evidence:

```text
error: Path 'nix/haskell-overlay.nix' in the repository "/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku" is not tracked by Git.
```

- The first tracked `nix build .#kiroku-store` reached dependency solving and failed because nixpkgs selected `hasql-notifications-0.2.4.0`, whose Cabal bounds require `hasql <1.10` and `hasql-pool <1.4`. The local `mori`-registered source at `/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-notifications/hasql-notifications.cabal` is version `0.2.5.0` and supports `hasql >= 1.10 && < 1.11` and `hasql-pool >= 1.4 && < 1.5`. Evidence from the failed build:

```text
Encountered missing or private dependencies:
    hasql >=1.9 && <1.10, hasql-pool >=1.3 && <1.4
```

- `nix build .#kiroku-store-migrations` failed because the nixpkgs `codd` package did not expose the `codd` library dependency needed by `kiroku-store-migrations`. The registered `mzabani/codd` source is version `0.1.8` and has a library stanza exposing module `Codd`; that version is not at `https://hackage.haskell.org/package/codd-0.1.8/codd-0.1.8.tar.gz`, so the local overlay pins the official `mzabani/codd` GitHub tag `v0.1.8` at commit `29478ff469b1c0466a7d126d64ab3dc1dbff4756`. Evidence:

```text
Encountered missing or private dependencies:
    codd
```

Evidence that Hackage cannot provide the needed release:

```text
trying https://hackage.haskell.org/package/codd-0.1.8/codd-0.1.8.tar.gz
curl: (22) The requested URL returned error: 404
```

Evidence for the official GitHub tag:

```text
git ls-remote https://github.com/mzabani/codd.git HEAD 'refs/tags/*'
29478ff469b1c0466a7d126d64ab3dc1dbff4756	refs/tags/v0.1.8
```

- `nix build .#shibuya-kiroku-adapter` initially used the older shared `shibuya-core` pin from `haskell-nix`, where `Envelope` did not match the current adapter source. The registered Shibuya repository at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` is at `shibuya-core` version `0.5.0.0`, where `Envelope` has both `attempt` and `attributes`; the adapter must populate `attributes = HashMap.empty` for the common case where it has no broker-specific OpenTelemetry attributes. Evidence from the older shared pin:

```text
Constructor 'Envelope' does not have field 'attempt'
```

- Building `codd` through Nix reaches its known `haxl-2.5.1.1` compatibility problem under the GHC 9.12.2 package set. This is the Nix equivalent of the `allow-newer: haxl:time` Cabal workaround already recorded in `docs/plans/16-evaluate-codd-for-first-class-schema-migrations.md`, so the local overlay must jailbreak `haxl`.

- After the adapter library was updated for `Envelope.attributes`, `cabal build all` found the same required field in `kiroku-store/bench/ShibuyaOverhead.hs`. That benchmark constructs a Shibuya `Envelope` directly and needs `attributes = HashMap.empty` for the no-adapter-attributes case. The same `cabal build all` run also tried to build upstream `codd` tests and failed before Kiroku validation could complete because the external package's `codd-test` could not execute `hspec-discover`.


## Decision Log

- Decision: Use the direct `haskellExtension` composition style from the shared `haskell-nix` documentation instead of importing `inputs.haskell-nix.overlays.default` into top-level `pkgs`.
  Rationale: `/Users/shinzui/Keikaku/bokuno/haskell-nix/docs/user/consumer-integration.md` says the overlay approach is fragile when a consumer also calls `.override { overrides = ...; }`, because that can replace existing overrides. Kiroku needs local package definitions, so explicit `pkgs.lib.composeExtensions` is the safer pattern.
  Date: 2026-05-16

- Decision: Model the Kiroku integration on the `rei` and `mori` flakes.
  Rationale: `/Users/shinzui/Keikaku/bokuno/rei-project/rei/flake.nix` and `/Users/shinzui/Keikaku/bokuno/mori-project/mori/flake.nix` both use `inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs` as the first composed extension, then compose a local `nix/haskell-overlay.nix` after it. This gives local overrides precedence while retaining shared patches.
  Date: 2026-05-16

- Decision: Keep this plan scoped to Nix build wiring and avoid changing Haskell source code.
  Rationale: The requested outcome is a Nix build using shared `haskell-nix`. Existing Cabal files already describe the libraries, tests, benchmarks, and executable. Nix should consume those Cabal descriptions rather than introduce a parallel build description by hand.
  Date: 2026-05-16

- Decision: Add a local `hasql-notifications` Nix override in Kiroku's overlay instead of changing Haskell source or relaxing Kiroku's Cabal bounds.
  Rationale: `kiroku-store` already depends on `hasql-notifications >=0.2`, and Cabal uses the local optional package path successfully. The Nix failure is caused by nixpkgs selecting an older Hackage release, so pinning the compatible Hackage release in `nix/haskell-overlay.nix` is the smallest project-local fix.
  Date: 2026-05-16

- Decision: Override `shibuya-core` locally for Kiroku's Nix build and update the adapter to populate `Envelope.attributes`.
  Rationale: Kiroku's `cabal.project` already uses the local registered Shibuya source, whose `Envelope` API has advanced beyond the old shared `haskell-nix` pin. Building the adapter against the current Shibuya API keeps Nix aligned with the Cabal workspace and requires only an empty attribute map in Kiroku's conversion layer.
  Date: 2026-05-16

- Decision: Jailbreak `haxl` in the Kiroku overlay while building `codd`.
  Rationale: `codd` depends on `haxl`, and this repository already needs a targeted Cabal `allow-newer: haxl:time` for GHC 9.12.2. The Nix analogue is a narrow `haxl = dontCheck (doJailbreak prev.haxl)` override.
  Date: 2026-05-16

- Decision: Add `package codd` settings in `cabal.project` with `tests: False` and `benchmarks: False`.
  Rationale: `codd` is an external optional package used as a library dependency of `kiroku-store-migrations`. Kiroku's aggregate build should validate Kiroku's packages, tests, and benchmarks, not upstream `codd`'s own test and benchmark suites.
  Date: 2026-05-16


## Outcomes & Retrospective

Implemented Nix package outputs for `kiroku-store`, `kiroku-store-migrations`, `shibuya-kiroku-adapter`, `kiroku-otel`, and `default`. The flake now composes shared `haskell-nix` patches with `nix/haskell-overlay.nix`, and the development shell uses the same composed Haskell package set for GHC and Haskell Language Server.

The implementation needed three local dependency adjustments. `hasql-notifications` is pinned to Hackage `0.2.5.0` because nixpkgs selected `0.2.4.0`, whose bounds are for the older `hasql` stack. `codd` is pinned to official GitHub tag `v0.1.8` because that version has the library API needed by `kiroku-store-migrations` but is not downloadable from Hackage. `shibuya-core` is pinned to current project commit `f2441d45f52bdd57c8463f3771eedb1d79a01e8b` so the Nix build matches the `cabal.project` optional package API.

The Shibuya API update required Kiroku code changes in the adapter and benchmark: both direct `Envelope` constructors now populate `attributes = HashMap.empty`, and the relevant Cabal stanzas declare `unordered-containers`. `cabal.project` now disables upstream `codd` tests and benchmarks so `cabal build all` validates Kiroku's own packages instead of failing on external package test tooling.

Validation completed on 2026-05-16. `nix fmt` completed successfully. These package builds all succeeded: `nix build .#kiroku-store`, `nix build .#kiroku-store-migrations`, `nix build .#shibuya-kiroku-adapter`, and `nix build .#kiroku-otel`. `nix flake check` passed for the local `aarch64-darwin` system, with incompatible systems skipped by Nix. `cabal build all` also passed.


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. It is a Haskell project with four Cabal packages listed in `cabal.project`: `kiroku-store`, `kiroku-store-migrations`, `shibuya-kiroku-adapter`, and `kiroku-otel`. A Cabal package is a build unit described by a `.cabal` file. In this repository, those files are `kiroku-store/kiroku-store.cabal`, `kiroku-store-migrations/kiroku-store-migrations.cabal`, `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`, and `kiroku-otel/kiroku-otel.cabal`.

The current `flake.nix` defines a development shell and formatting checks. It imports `nixpkgs`, picks `ghcVersion = "ghc9122"`, sets `hsPkgs = pkgs.haskell.packages.${ghcVersion}`, and puts `hsPkgs.ghc`, `pkgs.cabal-install`, and `hsPkgs.haskell-language-server` in `devShells.default`. It does not define a `packages` attribute. A Nix flake package output is the value that commands such as `nix build .#kiroku-store` build. Because Kiroku does not expose `packages.kiroku-store`, `Justfile` recipe `nix-build` currently points at an output that the flake does not provide.

The `Justfile` contains the user-facing commands. The relevant recipes are `build`, which runs `cabal build all`; `test`, which runs `cabal test all`; `nix-build`, which runs `nix build .#kiroku-store`; `nix-check`, which runs `nix flake check`; and `fmt`, which runs `nix fmt`. These commands should keep their names and basic behavior.

The shared Nix helper is `/Users/shinzui/Keikaku/bokuno/haskell-nix`. Its `README.md` describes it as a shared flake that provides GHC compatibility patches as a composable Haskell package set extension. Its `flake.nix` exposes `lib.haskellExtension`, and its `overlays/registry.nix` contains shared patches for packages Kiroku uses, including `hasql`, `hasql-pool`, `hasql-transaction`, `hasql-notifications` dependencies, `streamly`, `streamly-core`, `codd`, OpenTelemetry-related packages, `shibuya-core`, and `ephemeral-pg`. A Haskell package set extension is a Nix function shaped like `hself: hsuper: { ... }`; it changes or adds packages inside `pkgs.haskell.packages.<compiler>`.

Two local projects provide the desired integration pattern. `/Users/shinzui/Keikaku/bokuno/rei-project/rei/flake.nix` and `/Users/shinzui/Keikaku/bokuno/mori-project/mori/flake.nix` both add `haskell-nix.url = "github:shinzui/haskell-nix"` as an input, define `haskellPackages = pkgs.haskell.packages.${ghcVersion}.override { overrides = pkgs.lib.composeExtensions (inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs) (import ./nix/haskell-overlay.nix { ... }); };`, and expose their CLI package as `packages.default`. Their local overlays use `final.callCabal2nix` to turn local Cabal package directories into Nix Haskell derivations. `callCabal2nix` reads a `.cabal` file and creates a Nix build derivation from it, so the Cabal file remains the source of truth for dependencies and build targets.

Do not search, read, or traverse `/nix/store` while implementing this plan. If dependency APIs or package source layouts are unclear, use `mori registry list`, `mori registry search <name>`, `mori registry show <project> --full`, and direct reads of the registered source paths outside `/nix/store`.


## Plan of Work

Milestone 1 adds the missing Nix package definitions without changing how Cabal builds the project. Create a new file `nix/haskell-overlay.nix`. This file should accept `{ pkgs }`, import the helper functions `doJailbreak` and `dontCheck` from `pkgs.haskell.lib.compose`, and return a Haskell package set extension `final: prev: { ... }`. Inside that extension, define the four local packages with `final.callCabal2nix`: `kiroku-store` from `../kiroku-store`, `kiroku-store-migrations` from `../kiroku-store-migrations`, `shibuya-kiroku-adapter` from `../shibuya-kiroku-adapter`, and `kiroku-otel` from `../kiroku-otel`.

Use `dontCheck (doJailbreak (...))` for the initial Nix package derivations. `doJailbreak` relaxes Cabal version bounds inside the Nix build when the shared package set has compatible versions that the original bounds do not admit. `dontCheck` disables package-internal tests during `nix build` so package outputs build libraries and executables without recursively requiring test databases or long-running integration checks. This matches the local package overlay style in `rei` and `mori` and keeps `nix build .#kiroku-store` focused on producing the package. Tests remain available through `cabal test all` and, if a future plan wants it, explicit Nix checks.

Milestone 2 wires the shared patch set into `flake.nix`. Add `haskell-nix.url = "github:shinzui/haskell-nix";` under `inputs`. Add `haskell-nix` to the `outputs = { self, nixpkgs, flake-utils, treefmt-nix, pre-commit-hooks, ... }@inputs:` argument set or otherwise ensure the `inputs` binding is available where `haskellPackages` is defined. Replace the current `hsPkgs = pkgs.haskell.packages.${ghcVersion};` binding with a composed `haskellPackages` binding:

```nix
haskellPackages = pkgs.haskell.packages.${ghcVersion}.override {
  overrides = pkgs.lib.composeExtensions
    (inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs)
    (import ./nix/haskell-overlay.nix { inherit pkgs; });
};
```

Keep the shared `haskell-nix` extension first and Kiroku's local overlay second. This ordering means shared package compatibility fixes are available to local Kiroku package derivations, and local project package definitions can still override or extend the shared package set when needed.

Milestone 3 exposes package outputs and updates the development shell to use the same composed package set. Add a `packages` attribute alongside `checks`, `formatter`, and `devShells.default` inside the `eachDefaultSystem` result. It should expose at least:

```nix
packages = {
  kiroku-store = haskellPackages.kiroku-store;
  kiroku-store-migrations = haskellPackages.kiroku-store-migrations;
  shibuya-kiroku-adapter = haskellPackages.shibuya-kiroku-adapter;
  kiroku-otel = haskellPackages.kiroku-otel;
  default = haskellPackages.kiroku-store;
};
```

In `devShells.default.nativeBuildInputs`, replace `hsPkgs.ghc` with either `haskellPackages.ghc` or `haskellPackages.ghcWithPackages (ps: [ ps.haskell-language-server ])`, and replace `hsPkgs.haskell-language-server` with the equivalent from `haskellPackages`. The `rei` and `mori` projects use `haskellPackages.ghcWithPackages (ps: [ ps.haskell-language-server ])`, which is preferable because the compiler and HLS come from the same patched package set. Keep `pkgs.cabal-install`, `postgresql`, `pkgs.pkg-config`, `pkgs.zlib`, `pkgs.just`, and `pkgs.process-compose` in the shell.

Milestone 4 validates the build and records results. Run `nix flake update haskell-nix` after adding the input so `flake.lock` records the new dependency. Run `nix fmt`, `nix build .#kiroku-store`, `nix build .#kiroku-store-migrations`, `nix build .#shibuya-kiroku-adapter`, `nix build .#kiroku-otel`, and `nix flake check`. Also run `just build` or `cabal build all` to ensure Cabal still works outside Nix. If a build fails because a Haskell dependency is missing from nixpkgs or needs a source override, inspect the dependency with `mori` and add the smallest local overlay entry needed in `nix/haskell-overlay.nix`. If the missing or broken package is broadly useful across projects, update `/Users/shinzui/Keikaku/bokuno/haskell-nix` first and then run `nix flake update haskell-nix` in Kiroku, following the deployment sequencing in the shared `haskell-nix` docs.


## Concrete Steps

All commands in this section run from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

First, inspect the current repository and shared dependency context. These commands are safe to rerun.

```bash
mori show --full
mori registry show shinzui/rei --full
mori registry show shinzui/mori --full
sed -n '1,260p' flake.nix
sed -n '1,220p' cabal.project
sed -n '1,260p' /Users/shinzui/Keikaku/bokuno/haskell-nix/docs/user/consumer-integration.md
sed -n '1,180p' /Users/shinzui/Keikaku/bokuno/rei-project/rei/flake.nix
sed -n '1,180p' /Users/shinzui/Keikaku/bokuno/mori-project/mori/flake.nix
```

The important expected facts are that `mori show --full` names this project as `shinzui/kiroku` with Haskell packages `kiroku-store`, `shibuya-kiroku-adapter`, and `kiroku-otel`; `cabal.project` also lists `kiroku-store-migrations`; and the `rei` and `mori` flakes compose `inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs` with a local overlay.

Create `nix/haskell-overlay.nix` with this shape:

```nix
{ pkgs }:
let
  inherit (pkgs.haskell.lib.compose) doJailbreak dontCheck;
in
final: prev: {
  kiroku-store = dontCheck (doJailbreak (final.callCabal2nix "kiroku-store" ../kiroku-store { }));

  kiroku-store-migrations = dontCheck (doJailbreak (final.callCabal2nix "kiroku-store-migrations" ../kiroku-store-migrations { }));

  shibuya-kiroku-adapter = dontCheck (doJailbreak (final.callCabal2nix "shibuya-kiroku-adapter" ../shibuya-kiroku-adapter { }));

  kiroku-otel = dontCheck (doJailbreak (final.callCabal2nix "kiroku-otel" ../kiroku-otel { }));
}
```

Then edit `flake.nix`. In `inputs`, add:

```nix
haskell-nix.url = "github:shinzui/haskell-nix";
```

In the `let` block inside `eachDefaultSystem`, replace the old `hsPkgs` binding with:

```nix
haskellPackages = pkgs.haskell.packages.${ghcVersion}.override {
  overrides = pkgs.lib.composeExtensions
    (inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs)
    (import ./nix/haskell-overlay.nix { inherit pkgs; });
};
```

Inside the flake outputs attrset for each system, add:

```nix
packages = {
  kiroku-store = haskellPackages.kiroku-store;
  kiroku-store-migrations = haskellPackages.kiroku-store-migrations;
  shibuya-kiroku-adapter = haskellPackages.shibuya-kiroku-adapter;
  kiroku-otel = haskellPackages.kiroku-otel;
  default = haskellPackages.kiroku-store;
};
```

In `devShells.default.nativeBuildInputs`, use the composed package set for the compiler and HLS:

```nix
(haskellPackages.ghcWithPackages (ps: [
  ps.haskell-language-server
]))
pkgs.cabal-install
```

After editing, update the lock and format:

```bash
nix flake update haskell-nix
nix fmt
```

A successful targeted lock update should mention only the `haskell-nix` input as added or updated. `nix fmt` should complete with no output or only normal formatter messages.

Validate each package output:

```bash
nix build .#kiroku-store
nix build .#kiroku-store-migrations
nix build .#shibuya-kiroku-adapter
nix build .#kiroku-otel
```

Each successful command should exit with status 0 and leave or update the local `result` symlink. The symlink target is in the Nix store, but do not inspect that target. The proof is the successful command exit and the presence of `result` as a symlink.

Run the existing aggregate checks:

```bash
nix flake check
cabal build all
```

`nix flake check` should run formatting and pre-commit checks successfully. `cabal build all` should still succeed, proving the Nix changes did not break the normal Cabal workflow.


## Validation and Acceptance

The change is accepted when a user can build the Kiroku packages through Nix from the repository root. The most important user-visible command is:

```bash
just nix-build
```

Because `Justfile` defines `nix-build` as `nix build .#kiroku-store`, success means Kiroku now has a working `packages.kiroku-store` flake output. Before this plan is implemented, that output is absent from `flake.nix`. After implementation, `just nix-build` should exit 0.

Direct package builds should also work:

```bash
nix build .#kiroku-store
nix build .#kiroku-store-migrations
nix build .#shibuya-kiroku-adapter
nix build .#kiroku-otel
```

The expected behavior for each command is successful completion with no unresolved flake output error and no Cabal dependency solver failure inside Nix. If Nix prints build logs, the logs may vary, but the command must exit 0.

Run:

```bash
nix flake check
```

The expected behavior is that formatting and pre-commit checks still pass. This also proves `flake.nix` evaluates on the current system.

Run:

```bash
cabal build all
```

The expected behavior is that Cabal still builds the project with the existing `cabal.project`, proving the Nix overlay did not require changing Cabal metadata in a way that breaks the non-Nix development path.


## Idempotence and Recovery

Creating `nix/haskell-overlay.nix` and editing `flake.nix` are ordinary source changes. If a command fails partway through, inspect the error, adjust the Nix expressions, and rerun the same validation command. `nix build` and `nix flake check` are safe to rerun. `nix fmt` is safe to rerun and should converge on a stable formatting result.

`nix flake update haskell-nix` changes `flake.lock`. If the lock update pulls an unexpected revision or breaks evaluation, rerun `git diff flake.lock` to inspect the change and use a narrower pin if needed. Do not use destructive git commands to roll back unrelated user work. If only the `haskell-nix` lock entry is wrong, edit by rerunning `nix flake lock --override-input haskell-nix github:shinzui/haskell-nix/<revision>` with the intended revision, then rerun `nix flake check`.

If a local package fails in Nix because `callCabal2nix` cannot see files outside the package directory, use the `mori` overlay as an example. In `/Users/shinzui/Keikaku/bokuno/mori-project/mori/nix/haskell-overlay.nix`, `overrideCabal` adds a `prePatch` step to stage external files for packages that need them. Kiroku packages should not need that initially because their Cabal files and source trees are self-contained, but the recovery pattern is available if a Template Haskell splice or `extra-source-files` path proves otherwise.

If a dependency fails because the shared package set lacks a patch, decide whether the fix is Kiroku-specific or shared. Kiroku-specific fixes belong in `nix/haskell-overlay.nix`. Cross-project Haskell compatibility fixes belong in `/Users/shinzui/Keikaku/bokuno/haskell-nix`, followed by `nix flake update haskell-nix` in Kiroku.


## Interfaces and Dependencies

The main interface added by this plan is the flake package interface in `flake.nix`. At the end of the work, each supported system produced by `flake-utils.lib.eachDefaultSystem` must expose:

```nix
packages.kiroku-store
packages.kiroku-store-migrations
packages.shibuya-kiroku-adapter
packages.kiroku-otel
packages.default
```

`packages.default` should point at `haskellPackages.kiroku-store` because `kiroku-store` is the core library named in `mori show --full` as "Core event store library using hasql", and it is also the existing target in `Justfile` recipe `nix-build`.

The local overlay interface is the file `nix/haskell-overlay.nix`. It must be a Haskell package set extension with this shape:

```nix
{ pkgs }:
final: prev: {
  # package definitions here
}
```

Each package definition should use `final.callCabal2nix`, not hand-written derivations, so Cabal remains the source of truth. The package names in the overlay must match the package names in the `.cabal` files: `kiroku-store`, `kiroku-store-migrations`, `shibuya-kiroku-adapter`, and `kiroku-otel`.

The external dependency is the shared flake input:

```nix
inputs.haskell-nix.url = "github:shinzui/haskell-nix";
```

The consumed function is:

```nix
inputs.haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs
```

This returns a Haskell package set extension that applies shared patches from `/Users/shinzui/Keikaku/bokuno/haskell-nix/overlays/registry.nix`. The extension must be composed before Kiroku's local overlay with `pkgs.lib.composeExtensions`.

The development shell interface remains `devShells.default`. It should still export `PGHOST`, `PGDATA`, `PGLOG`, `PGDATABASE`, and `PG_CONNECTION_STRING` as the current shell does, and it should still initialize the local PostgreSQL data directory on first entry. The only intended shell behavior change is that the Haskell compiler and Haskell Language Server come from the same patched `haskellPackages` set used by Nix package builds.
