---
id: 18
slug: upgrade-shibuya-packages-to-latest-hackage-releases
title: "Upgrade Shibuya packages to latest Hackage releases"
kind: exec-plan
created_at: 2026-05-16T20:04:36Z
intention: intention_01khv3gg6xe91tt2pyqvxw1832
---

# Upgrade Shibuya packages to latest Hackage releases

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku currently builds its Shibuya integration against a local checkout of `shibuya-core`, even though `shibuya-core` is now published on Hackage at the same API level. After this change, the Cabal workspace and the Nix build should use the latest released Shibuya packages from Hackage where possible, with the `shibuya-kiroku-adapter` and the `kiroku-shibuya-overhead` benchmark compiling against the released API instead of relying on an adjacent local repository.

A user can see the change working by running the Shibuya adapter test suite and the Shibuya overhead benchmark build from the repository root. The adapter should still deliver catch-up events, live events, category subscriptions, failure isolation, and coordinated shutdown while Cabal resolves `shibuya-core-0.5.0.0` from Hackage rather than from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/shibuya-core.cabal`.


## Progress

- [x] Confirm the Hackage Shibuya release target and record any API differences that matter to Kiroku. Completed 2026-05-16T20:26:43Z.
- [x] Update Cabal dependency declarations so `shibuya-core` resolves to the latest Hackage release and no longer floats down to old API versions. Completed 2026-05-16T20:26:43Z.
- [x] Update or confirm Kiroku source compatibility with the latest Shibuya `Envelope` and tracing API. Completed 2026-05-16T20:26:43Z.
- [x] Update the Nix overlay so Nix builds use the Hackage Shibuya release instead of a GitHub source checkout unless Hackage cannot build under the pinned GHC. Completed 2026-05-16T20:26:43Z.
- [x] Run focused Shibuya adapter validation and then the broader project validation. Completed 2026-05-16T20:26:43Z.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: `cabal get shibuya-core-0.5.0.0 --destdir=/tmp/kiroku-shibuya-hackage-plan` reported that `/tmp/kiroku-shibuya-hackage-plan/shibuya-core-0.5.0.0/` already existed and was not empty. The existing unpacked source was still usable; `diff -qr /tmp/kiroku-shibuya-hackage-plan/shibuya-core-0.5.0.0/src /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src` exited successfully with no output.
  Evidence: empty `diff -qr` output means no source differences were found.
  Date: 2026-05-16

- Discovery: `final.callHackageDirect` can fetch `shibuya-core-0.5.0.0`, but the pinned Nix Cabal parser cannot parse the package's `cabal-version: 3.14`.
  Evidence: `nix build .#shibuya-kiroku-adapter` failed with `Unsupported cabal format version in cabal-version field: 3.14`.
  Date: 2026-05-16

- Discovery: `nix flake check` initially failed only on treefmt Cabal alignment after the dependency-bound edits.
  Evidence: the check showed diffs changing `shibuya-core          >=0.5 && <0.6` to treefmt's aligned `shibuya-core          >=0.5  && <0.6` style.
  Date: 2026-05-16


## Decision Log

Record every decision made while working on the plan.

- Decision: Target `shibuya-core-0.5.0.0` as the upgrade version for this repository.
  Rationale: On 2026-05-16, `cabal list shibuya-core --simple-output` reported versions `0.1.0.0` through `0.5.0.0`, and the Hackage/Flora package listing also reported `0.5.0.0` as the latest release dated 2026-05-05. The current Kiroku repository depends directly only on `shibuya-core`; it does not depend on `shibuya-metrics`, `shibuya-pgmq-adapter`, or `shibuya-kafka-adapter`.
  Date: 2026-05-16

- Decision: Prefer Hackage `shibuya-core` for Cabal and Nix, but keep unrelated dependency pins until validation proves they can be removed.
  Rationale: The user asked to upgrade Shibuya packages to latest from Hackage. The existing `hs-opentelemetry` `source-repository-package` blocks are shared by `shibuya-core` and `kiroku-otel`, so removing them is a separate solver decision and should not be bundled into the Shibuya source change unless `cabal build` proves Hackage versions work for the full workspace.
  Date: 2026-05-16

- Decision: Associate implementation commits for this plan with `intention_01khv3gg6xe91tt2pyqvxw1832`.
  Rationale: The ExecPlan implementation instructions require intention tracking when available, and the repository-local `mina.kdl` declares `default-parent intention_01khv3gg6xe91tt2pyqvxw1832`.
  Date: 2026-05-16

- Decision: Use a Hackage tarball plus the existing Cabal-version patching pattern for Nix instead of `callHackageDirect`.
  Rationale: `callHackageDirect` reached the Hackage source, but cabal2nix in the pinned Nix package set could not parse `cabal-version: 3.14`. Fetching the Hackage tarball and patching only that field keeps the source on Hackage while preserving compatibility with the current Nix tooling.
  Date: 2026-05-16


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed on 2026-05-16. Cabal now resolves `shibuya-core-0.5.0.0` from Hackage because the local `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/shibuya-core.cabal` optional package was removed from `cabal.project`, and all direct Kiroku dependencies on `shibuya-core` are bounded to `>=0.5 && <0.6`. No Haskell source changes were needed because Kiroku already populated `attempt = Nothing` and `attributes = HashMap.empty` at both direct `Envelope` construction sites.

Nix also no longer fetches `shibuya-core` from the `shinzui/shibuya` GitHub repository. It fetches the `shibuya-core-0.5.0.0` Hackage tarball, patches only `cabal-version: 3.14` to `3.4` for the pinned Cabal parser, and then builds it with `callCabal2nix`.

Validation completed successfully:

```text
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter
  5 examples, 0 failures
cabal build kiroku-store:bench:kiroku-shibuya-overhead
cabal build all
nix build .#shibuya-kiroku-adapter
nix flake check
```

`nix flake check` initially failed on formatting only. After `nix fmt` formatted the Cabal alignment, rerunning `nix flake check` passed `checks.aarch64-darwin.formatting` and `checks.aarch64-darwin.pre-commit-check`. The check reported that incompatible systems `aarch64-linux`, `x86_64-darwin`, and `x86_64-linux` were omitted, which is expected for a local check on this machine.


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. It is a Haskell project built with Cabal and GHC 9.12.2. A Cabal package is a build unit described by a `.cabal` file. The root `cabal.project` lists four local packages: `kiroku-store`, `kiroku-store-migrations`, `shibuya-kiroku-adapter`, and `kiroku-otel`.

The Shibuya-related package in this repository is `shibuya-kiroku-adapter`, described by `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`. Its library exposes `Shibuya.Adapter.Kiroku` and `Shibuya.Adapter.Kiroku.Convert`. `Shibuya.Adapter.Kiroku` starts a Kiroku subscription stream and wraps it in a Shibuya `Adapter es RecordedEvent`. `Shibuya.Adapter.Kiroku.Convert` converts each Kiroku `RecordedEvent` into a Shibuya `Ingested es RecordedEvent`, which contains an `Envelope` with normalized message metadata and an acknowledgment handle.

The root `cabal.project` currently includes this local optional package:

```yaml
optional-packages:
  /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/shibuya-core.cabal
```

That path makes Cabal prefer the adjacent local Shibuya checkout instead of resolving `shibuya-core` from Hackage. The registered dependency source was found with `mori registry show shinzui/shibuya --full`; its local repository is `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. Its `shibuya-core/shibuya-core.cabal` is version `0.5.0.0`, and its `CHANGELOG.md` says the breaking changes since Kiroku's original `>=0.1` bound are: in `0.4.0.0`, `Envelope` gained `attempt :: Maybe Attempt`; in `0.5.0.0`, `Envelope` gained `attributes :: HashMap Text Attribute`.

The Hackage source package was inspected with:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal get shibuya-core-0.5.0.0 --destdir=/tmp/kiroku-shibuya-hackage-plan
```

The unpacked Hackage source at `/tmp/kiroku-shibuya-hackage-plan/shibuya-core-0.5.0.0/src` matched the registered local source at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src` by `diff -qr`. This means Kiroku can use the Hackage release without adapting to a different API than the current local checkout.

The existing Kiroku code already contains the latest `Envelope` fields in two direct constructors. `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` imports `Data.HashMap.Strict qualified as HashMap` and sets `attempt = Nothing` and `attributes = HashMap.empty`. `kiroku-store/bench/ShibuyaOverhead.hs` does the same for the benchmark-local `mkIngested` helper. The implementation still needs to confirm this state remains true after the dependency declaration changes and after dependency solving chooses Hackage.

Nix builds are configured in `flake.nix` and `nix/haskell-overlay.nix`. The overlay currently defines `shibuya-core` by fetching GitHub repository `shinzui/shibuya` at commit `f2441d45f52bdd57c8463f3771eedb1d79a01e8b`, copying the `shibuya-core` subdirectory, and patching `cabal-version: 3.14` down to `3.4`. Because the installed Cabal is `3.16.1.0`, the Cabal workflow can read the Hackage package's `cabal-version: 3.14` directly. Nix may still need either a Hackage direct package with a Cabal-version patch or a newer Haskell package set; this plan makes that an explicit validation step rather than assuming it away.


## Plan of Work

Milestone 1 proves the target release and the current compatibility surface. At the end of this milestone, the implementer has confirmed that `shibuya-core-0.5.0.0` is the latest Hackage release and that Kiroku's direct `Envelope` construction sites include `attempt = Nothing` and `attributes = HashMap.empty`. Run the `mori`, `cabal list`, `cabal get`, `diff`, and `rg` commands from Concrete Steps. Acceptance is that the Hackage source matches the local registered Shibuya source and no direct `Envelope` constructor is missing either field.

Milestone 2 updates the Cabal workspace to resolve Shibuya from Hackage. Edit `cabal.project` to remove the local `shibuya-core` path from `optional-packages`. Then edit `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` so the library and test-suite dependency on `shibuya-core` explicitly requires the current API, for example `shibuya-core >=0.5 && <0.6`. Edit `kiroku-store/kiroku-store.cabal` so the `kiroku-shibuya-overhead` benchmark dependency on `shibuya-core` uses the same `>=0.5 && <0.6` bound. This bound is narrow on purpose: it prevents Cabal from selecting the old `0.1.0.0` API and forces a deliberate review for the next breaking Shibuya series.

Milestone 3 validates source compatibility. Build the adapter and the benchmark after the Cabal dependency change. If compilation fails with an error about missing `Envelope` fields, add the exact field shown by the `shibuya-core-0.5.0.0` source. For the current working tree, no source changes are expected beyond dependency declarations because `Shibuya.Adapter.Kiroku.Convert.toEnvelope` and `kiroku-store/bench/ShibuyaOverhead.mkIngested` already set both `attempt` and `attributes`.

Milestone 4 updates Nix to match the Cabal source decision. Replace the GitHub `fetchFromGitHub` based `shibuya-core` overlay in `nix/haskell-overlay.nix` with a Hackage-based derivation for `shibuya-core-0.5.0.0`. Use `callHackageDirect` when it works with the project package set. If Nix still cannot parse Cabal `3.14`, keep the existing patching pattern but apply it to a fetched Hackage tarball rather than to the GitHub checkout. Acceptance is that `nix build .#shibuya-kiroku-adapter` succeeds and the overlay no longer names `owner = "shinzui"; repo = "shibuya";` for `shibuya-core`.

Milestone 5 runs focused and full validation. Run `cabal build shibuya-kiroku-adapter`, `cabal test shibuya-kiroku-adapter`, `cabal build kiroku-store:bench:kiroku-shibuya-overhead`, and `cabal build all`. Then run `nix build .#shibuya-kiroku-adapter`. If time allows, run `nix flake check`. Acceptance is that the adapter tests pass and both Cabal and Nix no longer depend on the local Shibuya checkout for Kiroku's Shibuya package.


## Concrete Steps

Run all commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

First, confirm the repository and dependency identity with Mori. Mori is the local dependency registry; use it before guessing at APIs.

```bash
mori show --full
mori registry show shinzui/shibuya --full
mori registry docs shinzui/shibuya
```

Expected evidence includes `shinzui/kiroku` with package `shibuya-kiroku-adapter`, and `shinzui/shibuya` with package `shibuya-core` at local path `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core`.

Confirm Hackage versions:

```bash
cabal list shibuya-core --simple-output
cabal list shibuya-metrics --simple-output
cabal list shibuya-pgmq-adapter --simple-output
cabal list shibuya-kafka-adapter --simple-output
```

Expected output for the direct dependency is:

```text
shibuya-core 0.1.0.0
shibuya-core 0.2.0.0
shibuya-core 0.3.0.0
shibuya-core 0.4.0.0
shibuya-core 0.5.0.0
```

Inspect the Hackage package source and compare it with the local registered source:

```bash
cabal get shibuya-core-0.5.0.0 --destdir=/tmp/kiroku-shibuya-hackage-plan
diff -qr /tmp/kiroku-shibuya-hackage-plan/shibuya-core-0.5.0.0/src /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src
```

Expected output from `diff -qr` is empty. Empty output means no file differences were found.

Find direct `Envelope` construction sites in Kiroku:

```bash
rg "Envelope\\s*\\{|attempt =|attributes =|shibuya-core" shibuya-kiroku-adapter kiroku-store cabal.project nix/haskell-overlay.nix -n
```

Confirm `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` and `kiroku-store/bench/ShibuyaOverhead.hs` both import `Data.HashMap.Strict qualified as HashMap` and set these fields:

```haskell
attempt = Nothing
attributes = HashMap.empty
```

Edit `cabal.project` by deleting only the local `shibuya-core` optional package line. Keep the local `hasql-notifications` optional package and the `hs-opentelemetry` `source-repository-package` blocks until validation proves they are unnecessary. The target shape is:

```yaml
optional-packages:
  /Users/shinzui/Keikaku/hub/haskell/codd-project/codd/codd.cabal
  /Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-notifications/hasql-notifications.cabal
```

Edit `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`. In the library `build-depends`, change:

```cabal
, shibuya-core          >=0.1
```

to:

```cabal
, shibuya-core          >=0.5 && <0.6
```

In the same file's test-suite `build-depends`, change the unconstrained `shibuya-core` dependency to the same bounded dependency:

```cabal
, shibuya-core          >=0.5 && <0.6
```

Edit `kiroku-store/kiroku-store.cabal`. In the `benchmark kiroku-shibuya-overhead` stanza, change the unconstrained `shibuya-core` dependency to:

```cabal
, shibuya-core          >=0.5 && <0.6
```

Run focused Cabal validation:

```bash
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter
cabal build kiroku-store:bench:kiroku-shibuya-overhead
```

Expected adapter test output should end with zero failures. The exact number of examples may grow, but at plan creation the suite contains five adapter examples.

Then run broader Cabal validation:

```bash
cabal build all
```

If `cabal build all` tries to build optional dependency test suites and fails outside Kiroku-owned packages, record the failure in Surprises & Discoveries and run the owned package tests explicitly:

```bash
cabal test kiroku-store:kiroku-store-test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test kiroku-otel:kiroku-otel-test kiroku-store-migrations:kiroku-store-migrations-test
```

Update `nix/haskell-overlay.nix` so `shibuya-core` comes from Hackage. First try this direct form:

```nix
  shibuya-core = dontCheck (
    doJailbreak (
      final.callHackageDirect {
        pkg = "shibuya-core";
        ver = "0.5.0.0";
        sha256 = "<fill with the hash Nix reports>";
      } { }
    )
  );
```

Run:

```bash
nix build .#shibuya-kiroku-adapter
```

If Nix reports a hash mismatch, copy the reported `got:` hash into the `sha256` field and rerun the same command. If Nix fails only because its Cabal library cannot parse `cabal-version: 3.14`, replace the direct Hackage form with a fetched Hackage tarball plus the existing patching pattern. Keep the source as Hackage, not GitHub:

```nix
  shibuya-core =
    let
      src = pkgs.fetchurl {
        url = "https://hackage.haskell.org/package/shibuya-core-0.5.0.0/shibuya-core-0.5.0.0.tar.gz";
        hash = "<fill with the hash Nix reports>";
      };

      patched = pkgs.runCommand "shibuya-core-0.5.0.0-patched" { } ''
        mkdir -p $out
        tar -xzf ${src} --strip-components=1 -C $out
        chmod -R u+w $out
        ${pkgs.gnused}/bin/sed -i 's/^cabal-version: *3\.14/cabal-version: 3.4/' $out/shibuya-core.cabal
      '';
    in
    dontCheck (doJailbreak (final.callCabal2nix "shibuya-core" patched { }));
```

Finish with:

```bash
nix build .#shibuya-kiroku-adapter
nix flake check
```

If `nix flake check` is too slow for the immediate implementation, record that it was not run and keep `nix build .#shibuya-kiroku-adapter` as the required Nix acceptance gate.


## Validation and Acceptance

The primary behavior to preserve is that Kiroku events still flow through the Shibuya processing pipeline when using the released Hackage `shibuya-core` API. Run:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal test shibuya-kiroku-adapter
```

Acceptance is that the suite exits successfully. The tests exercise catch-up delivery, live delivery, multiple concurrent category subscriptions, isolation of a failing subscription from healthy subscriptions, and coordinated shutdown. Passing these tests proves the adapter still works against `shibuya-core-0.5.0.0`.

The benchmark compatibility check is:

```bash
cabal build kiroku-store:bench:kiroku-shibuya-overhead
```

Acceptance is that the benchmark builds. This proves the benchmark-local `Adapter`, `Ingested`, and `Envelope` construction code also matches the released Shibuya API.

The dependency-source acceptance check is:

```bash
rg "/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya|owner = \"shinzui\"|repo = \"shibuya\"" cabal.project nix/haskell-overlay.nix
```

Acceptance is that this command prints no reference to the local Shibuya checkout for `shibuya-core`. It is acceptable for source comments or future documentation to mention Shibuya by name, but build inputs must not come from the local checkout.

The broad Cabal acceptance check is:

```bash
cabal build all
```

Acceptance is that all Kiroku-owned packages build. If optional third-party package suites fail outside Kiroku code, record the exact package and error in Surprises & Discoveries and run the owned package tests explicitly as shown in Concrete Steps.

The Nix acceptance check is:

```bash
nix build .#shibuya-kiroku-adapter
```

Acceptance is that Nix builds the adapter using Hackage `shibuya-core-0.5.0.0`, either through `callHackageDirect` or through a Hackage tarball patched only for Cabal-version compatibility.


## Idempotence and Recovery

All inspection commands are safe to repeat. `cabal get` writes under `/tmp/kiroku-shibuya-hackage-plan`; if that directory already exists, remove only that temporary directory or choose a new temporary destination. Do not delete repository files to retry source inspection.

The Cabal edits are small and reversible. If removing the local `shibuya-core` optional package causes dependency solving to fail, first run `cabal update` and retry. If it still fails, record the solver error in Surprises & Discoveries. The recovery path is to restore the local optional package temporarily while keeping the `>=0.5 && <0.6` bounds, because the local registered source is also version `0.5.0.0`; then investigate which transitive Hackage dependency is missing or incompatible.

The Nix hash-update loop is expected. When Nix reports a hash mismatch, use the hash it prints and rerun the exact same `nix build` command. If `callHackageDirect` cannot handle the package because of Cabal-version parsing, switch to the Hackage tarball patching fallback described in Concrete Steps. Do not restore the GitHub Shibuya checkout unless the Hackage tarball itself is unavailable or corrupted; if that happens, record the reason and the exact command output.

This repository may already have unrelated uncommitted changes. Before editing, run:

```bash
git status --short
```

Do not revert changes that are outside this plan. If a file touched by this plan already has user edits, read it and apply only the minimal dependency-source update needed for this plan.


## Interfaces and Dependencies

The direct Shibuya dependency for this repository is Hackage package `shibuya-core`, target version `0.5.0.0`. The relevant modules and types are:

`Shibuya.Adapter` from `shibuya-core` exposes:

```haskell
data Adapter es msg = Adapter
  { adapterName :: Text
  , source :: Stream (Eff es) (Ingested es msg)
  , shutdown :: Eff es ()
  }
```

`Shibuya.Core.Ingested` exposes an `Ingested es msg` record containing `envelope`, `ack`, and `lease`. Kiroku constructs this in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`.

`Shibuya.Core.Types` exposes `Envelope msg`. In `shibuya-core-0.5.0.0`, direct constructors must provide these fields:

```haskell
Envelope
  { messageId :: MessageId
  , cursor :: Maybe Cursor
  , partition :: Maybe Text
  , enqueuedAt :: Maybe UTCTime
  , traceContext :: Maybe TraceHeaders
  , attempt :: Maybe Attempt
  , attributes :: HashMap Text Attribute
  , payload :: msg
  }
```

For Kiroku, `attempt` should remain `Nothing` because Kiroku event subscriptions do not track queue-style redelivery attempts. `attributes` should remain `HashMap.empty` because the adapter currently does not add broker-specific OpenTelemetry attributes. This keeps behavior identical while satisfying the `0.5.0.0` API.

`Shibuya.Core.Ack` exposes `AckDecision`. `Shibuya.Adapter.Kiroku.Convert.toIngested` must continue to treat `AckOk`, `AckRetry`, and `AckDeadLetter` as no-ops, and `AckHalt` as a call to the subscription cancel action. This preserves Kiroku's current checkpoint model, where checkpoint advancement is managed by the Kiroku subscription worker rather than by a Shibuya acknowledgment.

`Kiroku.Store.Subscription.Stream.subscriptionStream` remains the bridge from Kiroku to Shibuya. Its output stream is an `IO` stream of `RecordedEvent`; `Shibuya.Adapter.Kiroku.kirokuAdapter` must continue to lift it with `Stream.morphInner liftIO` before returning an `Adapter es RecordedEvent`.

The Hackage package index is the external source of release metadata. The implementation should use `cabal list`, `cabal get`, and the Hackage package URL `https://hackage.haskell.org/package/shibuya-core` to confirm release state. Mori remains the source of local dependency source paths and documentation; use `mori registry show shinzui/shibuya --full` before reading local Shibuya source.
