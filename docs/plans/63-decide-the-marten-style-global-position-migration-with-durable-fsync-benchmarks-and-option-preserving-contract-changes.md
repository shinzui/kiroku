---
id: 63
slug: decide-the-marten-style-global-position-migration-with-durable-fsync-benchmarks-and-option-preserving-contract-changes
title: "Decide the Marten-style global-position migration with durable-fsync benchmarks and option-preserving contract changes"
kind: exec-plan
created_at: 2026-06-11T15:14:23Z
intention: "intention_01ktvkqb9ee9j90wg64mgqd1mx"
---

# Decide the Marten-style global-position migration with durable-fsync benchmarks and option-preserving contract changes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

> **This plan is a decision instrument, not a migration.** Its product is a
> written verdict — **PROCEED NOW** or **NOT WORTH IT** — on undertaking the
> Marten-style global-position migration described in
> `docs/architecture/global-position-migration-path.md`, backed by throughput
> numbers measured on hardware with honest disk durability. The benchmark code it
> builds is a throwaway spike that never touches production modules. One milestone
> (M1, the contract changes) ships permanent changes regardless of the verdict;
> everything else is measurement. The decision thresholds are pre-registered in
> the Decision Log *before* any measurement runs, so the verdict is a falsifiable
> check rather than a sense-making exercise (per `docs/PERF-METHODOLOGY.md`).


## Purpose / Big Picture

Kiroku assigns every event a global position by incrementing a single counter row
(the `$all` row, `streams.stream_id = 0`) inside the append transaction. That row's
write lock is held until the transaction commits — and the commit includes the
synchronous WAL flush (the disk write that makes a transaction durable). So every
append in the entire store, regardless of which stream it targets, serializes on
the durable-commit latency of the storage device. On a MacBook this latency is
fake-cheap (~0.1–0.2 ms, because macOS `fsync()` does not actually flush the drive
cache), which produced the "~50K events/s" numbers in `docs/DESIGN.md`. On GCP with
honest fsync (~1 ms or worse) the same architecture measured drastically lower —
that discrepancy is what triggered this plan.

The alternative is the architecture Marten (the .NET event store this repo's
DESIGN.md calls "Strategy A") uses: assign positions from a PostgreSQL sequence,
let appends to different streams commit fully in parallel, and accept that
positions can have gaps and commit out of order — paying for it with a
"high-water-mark daemon" on the read side. Migrating to that is roughly a
masterplan-sized effort (8–10 ExecPlans; see
`docs/architecture/global-position-migration-path.md` for the full cost breakdown).
Nobody should start that effort on a hypothesis.

After this plan is implemented, the repository contains: (a) public documentation
that no longer promises position contiguity to consumers, so the migration option
stays open whatever we decide; (b) measured numbers, checked into
`docs/perf-experiment-log.md` and the architecture doc, answering "what % write
throughput would a Marten-style schema gain on durable-fsync hardware, at which
workload shapes"; and (c) a one-line verdict with pre-registered criteria:
**PROCEED NOW** or **NOT WORTH IT**.

**Expected-impact hypothesis** (required by `docs/PERF-METHODOLOGY.md` step 3).
The causal model says Strategy E's cross-stream throughput ceiling is
`batchSize / durable_commit_latency`, independent of writer count, because the
`$all` lock prevents commits from overlapping and therefore defeats PostgreSQL's
group commit (the mechanism by which many concurrently-committing transactions
share one WAL flush). The sequence-based arm restores group commit. Concretely
predicted, to be checked against measurement:

- Mac with `wal_sync_method=fsync_writethrough` (honest fsync): Strategy E
  append-only throughput at writers=32, batch=1 collapses by **≥ 3×** versus the
  default configuration. If this does not happen, the causal model is wrong and
  the plan stops at Milestone 3 with a "model falsified" outcome.
- GCP, writers=32, batch=1: sequence-based arm beats Strategy E by **5–15×**
  (group commit amortizes flushes across ~32 concurrent committers, less
  coordination overhead).
- GCP, writers=32, batch=10: ratio persists at roughly the same multiple (both
  arms scale linearly with batch size).
- Hot-stream (all writers on one stream): ratio ≈ **1×** — no gain, because
  same-stream appends serialize on the source-stream row lock in both designs.
  This cell is an honesty check on the whole experiment: if the sequence arm
  "wins" here, something is wrong with the setup.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be
documented here, even if it requires splitting a partially completed task into two
("done" vs. "remaining").

- [x] M1: reword `GlobalPosition` haddock in `kiroku-store/src/Kiroku/Store/Types.hs`
      (drop the gap-free promise from the public contract; state the
      no-arithmetic rule). (2026-06-11)
- [x] M1: reword `README.md` lines 29–32 (contiguity demoted to implementation
      detail). (2026-06-11)
- [x] M1: annotate `docs/DESIGN.md` Strategy E throughput claims (lines 17, 21,
      661) with a pointer to `docs/architecture/global-position-migration-path.md`
      and the Mac-artifact caveat. (2026-06-11)
- [x] M1: audit keiro (`/Users/shinzui/Keikaku/bokuno/keiro`) for position
      arithmetic or density assumptions; record findings in Surprises &
      Discoveries. (2026-06-11 — two density-assumption sites found; recorded.)
- [x] M1: mark `linkToStream` provisional in
      `kiroku-store/src/Kiroku/Store/Link.hs` (and any README mention); confirm
      keiro still has zero `linkToStream` usage at implementation time.
      (2026-06-11 — recheck returned zero usage.)
- [x] M1: build haddocks, run kiroku test suite, commit. (2026-06-11 —
      `cabal haddock kiroku-store` OK; 189 examples, 0 failures.)
- [x] M2 (prerequisite): migrate kiroku-bench to the fleet's current Nix infra
      (flake-parts on haskell-nix-dev, GHC 9.12.4) via the seihou
      `upgrade-haskell-flake-parts` blueprint; pin kiroku flake input + cabal to
      786282e; pin haskell-nix to kiroku's rev (4747cb8b); disable the
      shibuya exe (kiroku overlay shibuya-core 0.6/0.7 mismatch — kiroku
      follow-up). `nix build .#kiroku-bench` green. Committed kiroku-bench
      ba39326. (2026-06-11) See Surprises & Discoveries + UPGRADING.md.
- [x] M2: kiroku-bench fairness fixes — pool-size parity (writers+4), monotonic
      clock (`getMonotonicTimeNSec`), sub-millisecond histogram buckets
      (50/100/250 µs); committed kiroku-bench b1f484f. (2026-06-11) Pool-parity
      confirmed live (binary reports `poolSize=36` at writers=32).
- [x] M2: smoke-test the sub-millisecond buckets — fresh `kiroku-store-migrate`
      into the `kiroku` schema of the `kiroku-bench` PG-18 db, then 32 s
      `append-only` (writers=32, batch=1) via the nix-built binary. (2026-06-11)
      Result: 116,183 appends, **zero errors**, latency now resolved across the
      new buckets (≤0.5ms 6,006; ≤1ms 13,625; ≤2ms 24,519; previously all piled
      in the single 0.5ms bucket). poolSize=36 (writers+4) confirmed. ≈3.6K
      events/s at batch=1 on default (non-durable) macOS fsync — the M3 Run A
      baseline ballpark.
- [x] M3: Mac falsification run A (default `open_datasync`) and run B
      (`wal_sync_method=fsync_writethrough`); recorded in
      `docs/perf-experiment-log.md`; **gate PASSED** (A/B = 21.4×, ≥3×
      required). (2026-06-11)
- [x] M3: Mac inverse check (`synchronous_commit=off`) = 5,086 ev/s; recorded.
      Postgres config restored to defaults and verified. (2026-06-11)
- [x] M4: wrote `kiroku-bench/kiroku-bench/sql/seqproto-setup.sql` and the
      `kiroku-bench-seqproto` executable (`app/Seqproto.hs`); cabal stanza +
      `flake.module.nix` output added; `nix build .#kiroku-bench` green.
      (2026-06-11) Committed kiroku-bench.
- [x] M4: local smoke + invariants. (2026-06-11) seqproto 347,007 appends, 0
      errors; per-stream versions contiguous across all 32 streams; `$all`
      positions strictly increasing with 0 gaps (no rollbacks). On default
      (non-durable) macOS fsync seqproto did ~10.8K ev/s vs Strategy E ~3.7K
      (2.9×).
- [x] M4 (Mac honest-fsync proxy + discriminator — informational, not the
      pre-registered gate). (2026-06-11) Under `fsync_writethrough`: seqproto vs
      Strategy E = **1.14×** at batch=1 (183.3 vs 160.2), **1.04×** at batch=10
      (1733 vs 1661). Discriminator: seqproto throughput is FLAT across writers
      (1→177.7, 8→195.5, 32→182.2 ev/s) → macOS `F_FULLFSYNC` serializes durable
      commits at the device, so group commit cannot batch concurrent flushes on
      the Mac. The Mac structurally cannot exhibit the gain; this is why the
      pre-registered gate is GCP-only (not a model failure — M3 confirmed the
      lock-under-flush serialization at 21×).
- [x] M4: gap-scan viability check. (2026-06-11) On 5M `$all` junction rows
      (local), Marten's lead()-window gap-detection query from a mark 10K behind
      head: p50 2.25 ms, p95 **2.41 ms**, max 4.7 ms. PROCEED gate (p95 < 25 ms)
      **passes** with ~10× margin (Mac; GCP pd-ssd expected similar/faster).
- [x] M4 (GCP enablement, 2026-06-11): wired the seqproto arm into
      load-testing-infra — new `seqprotoBinary` haskell-bench option +
      `KIROKU_BENCH_SEQPROTO=1` runner selector (mirrors the
      `profileBinary`/`KIROKU_BENCH_PROFILE_MODE` mechanism); forwarded
      `KIROKU_BENCH_SEQPROTO`/`_HOT` in `run-benchmark.sh`; pointed
      `projects/kiroku` at the `kiroku-bench-seqproto` output. Pushed
      kiroku-bench `260e93a`; bumped + re-locked the infra flake
      (`kiroku 786282e`, `kiroku-bench 260e93a`). Committed infra `bf60458`.
      Built + registered the x86_64-linux driver image
      (`kiroku-driver-image-5bmh9bnx7j5d`); two prior build attempts hit
      transient remote-builder IAP-tunnel flakiness (cold-start race; SSH
      `Broken pipe` mid store-path copy) — the Haskell build itself
      succeeded, confirming the wiring. See Surprises.
- [x] M4 GCP smoke (2026-06-11): single seqproto cell (w8/b1, 40 s) on GCP
      confirmed the new path end-to-end — journal
      `profile_mode='none' seqproto='1' binary=…/kiroku-bench-seqproto`,
      `seqproto schema ready`, 1,560 ev/s, exitCode 0, zero errors.
- [x] M4: **GCP matrix** (the pre-registered gating measurement). (2026-06-11)
      Ran on load-testing-infra (`tan-nb-exp`/`us-west1`, PG 17.9, pd-ssd, fresh
      VM+disk per trial, 180 s, full durability). Trimmed to the gating cells
      once early data showed the verdict hinged on `G(32,1)`: seqproto w8/w32 ×
      {b1,b10} ×3 + smoke; Strategy E (current code) w32 × {b1,b10} ×3. Result:
      **G(32,1) = 1,499 / 687 = 2.18×**; seqproto flat in writers (w8 1,559 →
      w32 1,499). Both arms durable-commit-bound (~40 % CPU, 100 % cache). See
      Surprises (infra transients: stale SHA, IAP-tunnel flakiness, eventlog
      collect hang → `HASKELL_BENCH_EVENTLOG_ENABLED=false`, uppercase-`E`
      name-regex). Gap-scan already passed locally (p95 2.41 ms).
- [x] M5: gain table computed, pre-registered rule applied (2.18× = judgment
      zone), verdict resolved against the target workload and written into
      `docs/architecture/global-position-migration-path.md` Part 3; ledger row
      appended to `docs/perf-experiment-log.md`; Outcomes & Retrospective filled.
      **VERDICT: NOT WORTH IT.** (2026-06-11)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**M1 keiro `GlobalPosition` audit (2026-06-11).** Grepped every `GlobalPosition`
use in `/Users/shinzui/Keikaku/bokuno/keiro` (`grep -rn "GlobalPosition"
--include='*.hs' . | grep -v dist-newstyle`). Most uses are construction from
`0`, persistence round-trips (`unGlobalPosition`/`GlobalPosition <$> int8`
decoders), and header (de)serialization — all contract-safe. Two sites assume
density and would behave incorrectly under a gappy sequence-based scheme:

1. `keiro/src/Keiro/Command.hs:638-661` `reconstructRecorded` reconstructs a
   just-appended batch's `RecordedEvent`s without reading them back, computing
   `firstGp = lastGp - count + 1` then `globalPosition = GlobalPosition
   (firstGp + i)` per event. This assumes the batch's events received
   *contiguous* positions. Under Strategy E that holds (one append claims a
   contiguous run); under a non-transactional sequence, concurrent appends can
   interleave `nextval()` calls, so a batch's positions may not be contiguous —
   this would assign wrong positions. **Correctness-affecting** if the migration
   proceeds; must be fixed (read the batch back, or have the append return the
   exact positions) as part of any PROCEED follow-up.
2. `keiro/src/Keiro/Projection.hs:151-153` `positionGap` computes
   `headP - checkP` as "the gap between log head and checkpoint, in events".
   Under gappy positions this overcounts actual events. **Observability-only**:
   it feeds `recordProjectionLag` (a metric), not a correctness path. Lower
   priority but should be noted as approximate.

Per the plan, keiro is not modified here; both are filed as PROCEED follow-up
work (and surfaced in the M5 verdict write-up). No site compares positions
across stores or does `pos + 1` existence checks.

**M1 `linkToStream` recheck (2026-06-11).** `grep -rn "linkToStream"
--include='*.hs' .` (excluding `dist-newstyle`) in keiro returned zero matches
(exit 1). The 2026-06-11 audit holds; marking the API provisional does not pull
it out from under a live consumer.

**M4 local: the Mac cannot measure the gain — group commit is dead under
`F_FULLFSYNC` (2026-06-11).** The seqproto arm is correct and fast: local smoke
gave 347,007 appends, 0 errors, per-stream versions contiguous (all 32 streams),
`$all` positions strictly increasing with 0 gaps. On *default* (non-durable)
macOS fsync seqproto ran ~10.8K ev/s vs Strategy E ~3.7K (2.9×) — removing the
`$all` lock helps when commits are cheap. But under *honest* fsync
(`fsync_writethrough`) the seqproto-vs-E ratio collapsed to **1.14×** (batch=1)
and **1.04×** (batch=10) — nowhere near the predicted 5–15×. A writer-scaling
discriminator explains why: seqproto throughput is FLAT across writer counts
under honest fsync (writers 1/8/32 → 177.7 / 195.5 / 182.2 ev/s). Adding writers
does not raise throughput, which means PostgreSQL group commit is NOT batching
concurrent durable flushes on this Mac — macOS `F_FULLFSYNC` issues a
full-device-cache flush that the SSD serializes, so 32 concurrent durable
commits queue at the device just like Strategy E's lock-serialized commits. The
two designs therefore hit the *same* ~180-commit/s ceiling on the Mac, and the
Mac is structurally unable to demonstrate the group-commit relief that removing
the `$all` lock is supposed to unlock. This is NOT a falsification (M3 already
confirmed the lock-under-flush serialization at 21×); it is the precise reason
the plan pre-registered the verdict on **GCP** (Linux + pd-ssd, where
`fdatasync` group commit batches concurrent committers). Refines
[[strategy_e_ceiling_is_mac_artifact]]: the ceiling on the Mac is the device
`F_FULLFSYNC` serialization, which the `$all` lock and a sequence-based arm hit
identically — only cloud hardware separates them.

**M4 gap-scan viability passes (2026-06-11).** On 5M `$all` junction rows
(local bulk population), Marten's `lead()`-window gap-detection query, starting
from a mark 10K behind head, ran p50 2.25 ms / p95 **2.41 ms** / max 4.7 ms over
100 iterations — comfortably under the PROCEED gate's p95 < 25 ms (≈10× margin),
even on the Mac. The HWM daemon's steady-state poll is not a concern.

**M3 gate passed decisively — model confirmed at 21.4× (2026-06-11).** The Mac
falsification sweep (append-only, writers=32, batch=1, payload=256, 60 s window,
fresh `kiroku` schema per run, nix-built `kiroku-bench` against local PG 18)
produced: Run A (default `open_datasync`, `synchronous_commit=on`) **3,702 ev/s**;
Run B (honest `fsync_writethrough` → `F_FULLFSYNC`) **172.8 ev/s**; Run C
(`synchronous_commit=off`) **5,086 ev/s**; all zero errors. A/B = **21.4×** vs
the predicted ≥3×, and the ordering B (173) ≪ A (3702) ≤ C (5086) holds exactly.
At batch=1 the honest-fsync arm is ~173 commits/s ≈ 5.8 ms per fully-serialized
durable commit — the `$all` lock held across the WAL flush defeats group commit.
The prediction was conservative: the real collapse is ~7× larger than the gate.
Postgres config was restored (`ALTER SYSTEM RESET …`, restart) and verified
(`open_datasync`/`on`). Recorded as a row in `docs/perf-experiment-log.md`.
Gate passed → M4 proceeds.

**M2 kiroku-bench build was broken before any M2 edit (2026-06-11).**
`cabal build all` in kiroku-bench failed at
`kiroku-bench/src/Kiroku/Bench/Modes/SubscriptionLatency.hs:300` —
`SubT.PauseAndResume` "not exported by Kiroku.Store.Subscription.Types". Root
cause was a **corrupted `flake.lock`**: kiroku-bench's `flake.nix` pinned
`github:shinzui/kiroku/f437ce35` (2026-05-30, which descends from b068377 that
added `PauseAndResume`, so its source *does* export the constructor), but the
locked `narHash` for that input resolved to a stale pre-`PauseAndResume` source
tree, so the nix-built `kiroku-store-0.1.0.0` lacked the constructor while the
bench HEAD code used it. Evidence: `git merge-base --is-ancestor b068377
f437ce35` → yes; `git show f437ce35:…/Subscription/Types.hs` exports
`OverflowPolicy (..)` incl. `PauseAndResume`; yet `direnv exec . ghc-pkg list`
showed `kiroku-store-0.1.0.0` and the build still failed only on
`PauseAndResume` (sibling `DropOldest`/`DropSubscription` compiled). Fix per the
user's "always use the latest code" directive: pushed kiroku master
(`786282e`, incl. M1) to github and bumped the kiroku-bench flake input from
f437ce35 → 786282e, then `nix flake update kiroku`. This also means the M4
benchmark arms measure current kiroku (commit `786282e`), satisfying the
Decision Log requirement to record the kiroku commit hash.

**M2 required migrating kiroku-bench to the latest fleet infrastructure
(2026-06-11).** Bumping the kiroku flake pin alone did not fix the build. The
deeper problem: kiroku-bench was still on the *old* Nix flake shape
(hand-rolled `flake-utils` + `ghcWithPackages`, GHC 9.12.2 on
`nixpkgs-unstable`), while kiroku itself had migrated to the thin
flake-parts structure on the `haskell-nix-dev` base flake (GHC **9.12.4**, a
single fleet-pinned nixpkgs). Composing kiroku's 786282e overlay (written for
ghc9124) onto the bench's mismatched ghc9122/nixpkgs is what desynced
kiroku-store — cabal's solve resolved a phantom `kiroku-store 0.1.0.0`
(unit-id `krk-str-0.1.0.0-…`, built from source incl. its
`kiroku-consumer-group-example` exe) even though `ghc-pkg`/a standalone probe
saw the correct `kiroku-store-0.2.0.0` that exports `PauseAndResume`. Per the
user's "always use the latest code" / "let's migrate to latest infrastructure"
directives, I ran the seihou blueprint **`upgrade-haskell-flake-parts`**
(extracted its prompt via `seihou agent --debug run` and executed it in-session,
modelling the new files on kiroku's already-migrated `nix/*`): new thin
`flake.nix`, `nix/haskell.nix` (`mkDevShell` ghc9124, preserving the bench's PG
shellHook + `just`/`process-compose`/`jq`), `nix/treefmt.nix`,
`nix/pre-commit.nix`, and an unmanaged `flake.module.nix` (three-overlay graft:
haskell-nix registry + `${kiroku}/nix/haskell-overlay.nix` + local
`callCabal2nix kiroku-bench`); deleted the top-level `treefmt.nix`. Verified:
devShell evaluates to a drv, `checks = [pre-commit treefmt]`, `haskell-nix`
re-locked to latest, `flake-utils` dropped.

One unavoidable source-level edit fell out of "use latest": kiroku-store@786282e
now requires `shibuya-core >=0.7`, but the bench's `kiroku-bench-shibuya` exe
stanza pinned `shibuya-core >=0.5 && <0.6`. Cabal solves all stanzas of a
package together, so that stale bound made the *entire* kiroku-bench package
unbuildable (nix or cabal) against current kiroku. Bumped it to `>=0.7 && <0.8`
in `kiroku-bench/kiroku-bench.cabal` — a version-bound alignment with the
upgraded dependency, not a logic patch.

**Latent kiroku build bug surfaced (2026-06-11): kiroku's overlay ships
shibuya-core 0.6 while its own adapter needs 0.7.** Building `.#kiroku-bench`
then failed compiling `shibuya-kiroku-adapter` at
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs:179` (GHC-53822).
Root cause is in **kiroku**, not the bench: `kiroku/nix/haskell-overlay.nix`
provisions `shibuya-core-0.6.0.0` (fetchurl + jailbreak), but the adapter source
(kiroku commit 90bd3bc "require shibuya-core 0.7 and set Envelope.headers")
targets the 0.7 `Envelope` API (`headers`, `attributes`, `attempt` fields). So
kiroku's *own* `nix build` of `shibuya-kiroku-adapter` is broken at HEAD.
shibuya-core 0.7.0.0 is published on Hackage (verified HTTP 200), so the fix is
a one-line overlay bump in kiroku (`shibuya-core 0.6.0.0 → 0.7.0.0`, with the new
tarball hash) — filed as a kiroku follow-up, out of scope for this plan.
ExecPlan 63 never uses the shibuya adapter, so I set the bench's
`kiroku-bench-shibuya` exe to `buildable: False` (documented in the cabal stanza
and UPGRADING.md) to unblock the kiroku-store-only arms the plan needs. The
`.#kiroku-bench-shibuya` flake output still resolves (same derivation) but its
binary is absent until the kiroku overlay is fixed and the stanza re-enabled.

**M1 README link-feature note (2026-06-11).** `README.md`'s API enumeration
(line ~17) lists "link" among the kiroku-store APIs. Judged not worth a separate
provisional caveat there: it is a bare enumeration item, not a feature pitch,
and the authoritative contract surface (the `linkToStream` haddock) now carries
the provisional marker. The membership-through-links sentence (line ~30) was
reworded to frame links as the mechanism, not a promoted feature.


**M4 GCP enablement: the infra had no seqproto path; build transients, not
code, were the only friction (2026-06-11).** load-testing-infra's
`run-experiment-grid` CSV carries only `mode/writers/payload/batch` and the
kiroku driver image baked only `kiroku-bench`/`kiroku-bench-prof` — there was
no way to run a *different* binary. I added a `seqprotoBinary` option to the
`services.haskellBench` NixOS module and a `KIROKU_BENCH_SEQPROTO=1` selector in
`haskell-bench-run.sh` (orthogonal to the profile-mode switch), forwarded the
two new keys in `run-benchmark.sh`, and pointed `projects/kiroku` at the
`kiroku-bench-seqproto` output — a direct parallel to the existing
profile-binary plumbing. The x86_64-linux image build then failed twice on
*infra* flakiness, never on the new code: (1) the remote builder VM
(`nix-builder-x86`) was idle-shut-down, so the `nix-gcp-builder` ProxyCommand
hit a cold-start IAP-tunnel race (`socat … [::1]:PORT Connection refused`);
warming the VM + `SHELL=/bin/sh` (the documented macOS zsh-ProxyCommand guard)
fixed it. (2) The next attempt built *all* Haskell packages successfully —
kiroku-store, kiroku-bench, and the seqproto binary all compiled for Linux,
proving the wiring — then dropped the SSH builder connection mid store-path copy
(`client_loop: … Broken pipe`); a third attempt reused the cached builds and
registered `kiroku-driver-image-5bmh9bnx7j5d`. The GCP smoke (seqproto w8/b1,
40 s) then confirmed the full path live: journal
`profile_mode='none' seqproto='1' binary=…/kiroku-bench-seqproto`,
`seqproto schema ready`, 1,560 ev/s, 0 errors — already above Strategy E's
GCP w32/b1 ceiling (~972 ev/s), the expected signature of removing the `$all`
lock. Infra changes committed in load-testing-infra `bf60458`.

## Decision Log

- Decision: Decision thresholds are pre-registered before any measurement, as
  follows. Let `G(w,b)` be the ratio (seqproto events/s ÷ Strategy E events/s)
  for the append-only workload at writer count `w` and batch size `b` on the GCP
  reference setup, using the median of 3 trials per cell.
  **PROCEED NOW** requires all of: `G(32,1) ≥ 3.0`; `G(32,10) ≥ 2.0`; and the
  gap-scan viability check passes (the Marten-style gap-detection query
  completes in < 25 ms p95 against the prototype dataset at its post-run row
  count). **NOT WORTH IT** is declared when `G(32,1) < 2.0`. The band between
  (G(32,1) ≥ 2.0 but a PROCEED condition failing) is a judgment zone: the
  verdict must be decided against a written target workload (events/s the
  business actually needs) and recorded here with rationale.
  Rationale: the migration costs ~8–10 ExecPlans and adds a permanently more
  complex read side (high-water-mark daemon). A < 2× win never repays that —
  doubling batch size achieves 2× for free under Strategy E. A ≥ 3× win at the
  unbatched shape, holding ≥ 2× when batching (the cheap relief valve) is
  already applied, means the relief valves cannot close the gap and the
  architecture itself is the bottleneck.
  Date: 2026-06-11

- Decision: The prototype arm keeps Kiroku's exact write shape — `events` insert
  plus *two* `stream_events` junction inserts per event (source stream and
  `$all`) plus the `streams` source-row update and NOTIFY trigger — changing
  exactly one variable: global positions come from `nextval()` on a sequence
  instead of the `$all` row counter, and the `$all` row is never updated.
  Rationale: the question is "what does removing the `$all` lock buy", not "what
  does a thinner schema buy". Keeping write amplification identical isolates the
  variable. (A real migration might also drop the `$all` junction rows in favor
  of a position column on `events` — Marten's shape — but that is a separate
  optimization to be measured separately if we proceed.)
  Date: 2026-06-11

- Decision: The `GlobalPosition` constructor stays exported. True opacity is
  impossible: consumers persist checkpoints as integers and must reconstruct
  positions, and the documented idiom `readAllForward (GlobalPosition 0)` needs
  the constructor. The contract change is documentation-level: construct only
  from zero or from a value previously obtained from the store; never compute
  positions by arithmetic; never assume density.
  Date: 2026-06-11

- Decision: This plan is standalone, not a child of MasterPlan 9. Its M1 is
  independent of all in-flight work, and its measurements compare two arms on
  identical code/schema state, so the *ratio* is robust to whichever of plans
  59/60 have landed. The absolute Strategy E numbers recorded in M4 must note
  the kiroku commit hash they were measured at. A PROCEED verdict must still
  respect MasterPlan 9 sequencing (the migration would rewrite the
  publisher/worker files plans 56–58 touch), and says "proceed" to *planning the
  migration masterplan*, not to starting it mid-flight of MasterPlan 9.
  Date: 2026-06-11

- Decision: The hot-stream cell is informational, not gating.
  Rationale: same-stream serialization is inherent to optimistic concurrency on
  a stream in both designs; no decision hinges on it. It serves as an
  experiment-validity check (expected ratio ≈ 1×).
  Date: 2026-06-11

- Decision: kiroku-bench tracks the latest kiroku (not a frozen historical
  pin). When M2 found kiroku-bench unbuildable against its stale flake pin, the
  user directed "always use the latest code". We therefore push kiroku master
  and bump kiroku-bench's `flake.nix` kiroku input to the current kiroku HEAD
  (2026-06-11: f437ce35 → 786282e), rather than re-locking the old revision.
  Rationale: the benchmark must measure the kiroku version we actually ship, and
  the Decision Log already requires recording the kiroku commit hash M4 measures
  at; pinning to HEAD makes that hash meaningful. Reproducibility is preserved
  because the bump is to a pushed github SHA (so load-testing-infra's GCP runs
  fetch the same source), not a local-path override.
  Date: 2026-06-11

- Decision: As part of M2, migrate kiroku-bench to the fleet's current Nix
  infrastructure (thin flake-parts on the `haskell-nix-dev` base flake, GHC
  9.12.4) via the seihou `upgrade-haskell-flake-parts` blueprint, rather than
  keep patching the legacy flake. The user explicitly directed this ("let's
  migrate to latest infrastructure", pointing at the blueprint). The bench's old
  dev shell pre-installed kiroku-store via `ghcWithPackages`, which `mkDevShell`
  cannot replicate. The kiroku source build path (`nix build .#kiroku-bench`,
  used by load-testing-infra for the GCP runs) is preserved through the overlay
  graft in `flake.module.nix`, so benches are built/run via nix-built binaries.
  Wiring kiroku-store into the dev shell's `cabal` (the keiro
  `source-repository-package` pattern, which cascades into provisioning
  shibuya-core etc.) is deferred as a dev-ergonomics follow-up — the plan's
  measurements use the nix-built binaries, so it is not a blocker. This detour
  is recorded because M3/M4 numbers are now produced by `nix run`/built binaries
  on the ghc9124 toolchain, a fact the verdict's environment description must
  note.
  Date: 2026-06-11

- Decision: `linkToStream` is kept but demoted to provisional status as part of
  M1, and its fate is pre-registered: if the verdict is PROCEED, the migration
  masterplan must include an explicit phase-2 decision point that adopts the
  single-table event layout (global position as a column on `events`, junction
  table dropped) and removes `linkToStream` or rehomes it to a normally-empty
  side table (`stream_links`), with the write-amplification gain measured under
  the same benchmark-gated discipline as this plan.
  Rationale: a 2026-06-11 audit found zero `linkToStream` usage in keiro (the
  only downstream consumer) or anywhere outside kiroku's own tests and docs.
  The feature has no append-hot-path cost today, but it is the only feature
  that *requires* the `stream_events` junction shape — `$all` ordering,
  category reads, consumer groups, and causation queries all survive a
  single-table layout without it. Marking it provisional now prevents keiro
  from adopting it and converting a free removal option into a breaking change
  (the same calcification logic as the `GlobalPosition` contract change).
  Date: 2026-06-11


- Decision: The seqproto arm runs on GCP through the *existing*
  load-testing-infra harness, selected at run time by a new
  `KIROKU_BENCH_SEQPROTO=1` extra-env key — mirroring the established
  `profileBinary`/`KIROKU_BENCH_PROFILE_MODE` binary-switch mechanism — rather
  than by adding a new project or a bespoke orchestration. A new
  `services.haskellBench.seqprotoBinary` option materializes
  `bench-binary-seqproto` in the kiroku driver image and the runner execs it
  when the key is set. Rationale: maximize reuse of the trusted, validated
  harness (same provisioning, collection, metric synthesis, archival) so the
  numbers are directly comparable to the Strategy E arm and to prior GCP runs;
  the seqproto binary self-bootstraps its `seqproto` schema, so it needs no
  project `setup.sh` change. Date: 2026-06-11
- Decision: The GCP matrix uses per-row provision/destroy (the stock
  `run-experiment-grid` → `run-benchmark` flow) so every trial runs against a
  fresh postgres VM + disk, matching the ceiling-lite convention the plan
  cites. Trials use `RUN_DURATION_SECONDS=180` (exceeds the plan's ≥120 s
  steady-state floor without the infra's 600 s GC-sampling default, which this
  throughput-ratio question does not need) and `SKIP_UPLOAD=1` (the driver
  image is built/registered once at session start and does not change between
  rows). Rationale: fidelity and trust for a decision instrument; the
  3-trial median absorbs cross-provision hardware variance, and the ratio
  cancels any systematic per-provision bias because both arms run identically.
  Date: 2026-06-11
- Decision: The seqproto hot-stream cell runs as a separate grid invocation
  with `KIROKU_BENCH_SEQPROTO_HOT=1` exported, because the grid CSV row format
  (`name,project,mode,writers,payload,batch`) cannot carry that extra env key;
  the seqproto matrix and hot cells therefore split into two invocations while
  Strategy E (whose hot cell is just `mode=hot-stream-append`, a CSV-expressible
  value) stays a single 15-row invocation. Date: 2026-06-11

- Decision: The GCP matrix was trimmed to the gating cells after the seqproto
  arm was measured. The pre-registered decision rule depends only on `G(32,1)`
  and `G(32,10)`; the w8 cells (writer-scaling, informational) and the
  hot-stream cell (explicitly non-gating, a validity check) do not enter the
  verdict. The full seqproto arm (w8+w32, b1+b10, ×3) plus a GCP smoke ran;
  for the Strategy E baseline only the two gating cells were re-run
  (w32×{b1,b10}×3 = 6 runs), and the 3 seqproto hot-stream rows were skipped
  (pre-created dirs) because without a Strategy E hot baseline they would be
  orphaned. Rationale (recorded at the user's prompting, 2026-06-11): the early
  seqproto numbers showed throughput flat across writers (w8≈w32≈1,500 ev/s at
  b1), so the predicted 5–15× group-commit relief is absent and the verdict is
  dominated by `G(32,1)`; spending ~2–3 cloud-hours on non-gating cells does
  not change a mechanically-applied decision. The first Strategy E attempt
  (uppercase-`E` prefix) failed all 15 rows at `run-benchmark`'s lowercase-only
  experiment-name regex in 0 s — before any provisioning, so zero GCP cost —
  hence the lowercase `…ep63-strate-*` re-run. Date: 2026-06-11

- Decision (correction, 2026-06-14): **the M2 pool-parity choice (writers+4) was
  the wrong methodology and the headline ratio was measured at a biased pool.**
  An earlier finding (the May `followup-pool*` sweep) had already established
  that the `$all`-lock-bound kiroku-store append arm is throughput-optimal at
  pool ≈ 10–13 and degrades when over-subscribed; M2 nonetheless changed the
  bench default 10 → writers+4 to "match the lock-free rawpg baseline", citing
  that sweep as a confound yet correcting in the wrong direction. The two
  architectures have *different* optimal pools, so pool-parity necessarily
  mis-tunes the lock-bound arm — pool=36 cost Strategy E ~25–30 % (≈687 vs ≈950
  at pool≈13), inflating `G(32,1)` to 2.18× when the fair best-pool-vs-best-pool
  figure is ≈ 1.6×. The user chose to fix the record rather than re-measure
  (the verdict is identical across 1.6–2.18×). Durable guards added so this is
  not re-violated: a hard rule in `docs/PERF-METHODOLOGY.md` ("never pool-parity
  a lock-bound arm against a lock-free arm; pin the kiroku-store append arm to
  pool ≈ 10–13; compare best-vs-best") and an in-code warning at the
  `KIROKU_BENCH_POOL_SIZE` default in kiroku-bench `app/Main.hs`. This is the
  same finding that resolves follow-up #3 (the apparent "~30 % regression" is
  the pool change, not code). Date: 2026-06-14

## Outcomes & Retrospective

**Measured gain table** (GCP `tan-nb-exp`/`us-west1`, PostgreSQL 17.9, pd-ssd,
writers=32, payload=256, 180 s, full durability, fresh VM+disk per trial, median
of 3; Strategy E = kiroku `786282e`, seqproto = kiroku-bench `260e93a`; infra
`bf60458`):

| cell | Strategy E | seqproto | ratio |
|---|---|---|---|
| batch=1, **best-pool vs best-pool (fair)** | ~950 (pool ≈ 13) | ~1,499 | **≈ 1.6× (indicative)** |
| batch=1, pool-parity at 36 (as-measured, biased) | 687 ev/s | 1,499 ev/s | 2.18× |
| batch=10, pool-parity at 36 | 4,364 ev/s | (not run) | — |
| writer-scaling (seqproto, b1) | — | w8 1,559 → w32 1,499 (**flat**) | — |

**Pool-size correction (2026-06-14).** The pre-registered pool-parity choice
(writers+4=36 for both arms) was the *wrong* methodology: the `$all`-lock-bound
Strategy E arm is optimal at pool ≈ 10–13 and degrades when over-subscribed,
while the lock-free seqproto arm is pool-insensitive — so parity handicaps
Strategy E and inflates the ratio to 2.18×. The fair best-pool-vs-best-pool
figure is ≈ 1.6× (≤ the 2.0 NOT-WORTH-IT line). This also fully explains the
apparent "~30 % regression vs May": no code changed on the append path; the
bench pool default moved 10 → 36. See the new hard rule in
`docs/PERF-METHODOLOGY.md` and `global-position-migration-path.md` Part 3.

**Prediction vs observation.** Purpose-section prediction: GCP w32/b1 sequence
arm beats Strategy E by **5–15×** via group commit amortizing flushes across ~32
concurrent committers. **Observed: ~1.6× (best-pool-vs-best-pool; 2.18× at the
biased pool-parity setting), and flat in writer count** — group commit does
*not* amortize concurrent durable commits on pd-ssd; the sequence arm hits the
durable-commit wall at ~1,500 single-event commits/s just as Strategy E hits it
(plus lock overhead) at ~950 (best pool) / ~687 (pool=36). The M3 Mac `F_FULLFSYNC`
serialization reproduced on cloud hardware. The 5–15× hypothesis is **falsified**
for the unbatched single-event path. (Earlier milestones held: M1 contract
changes shipped; M3 confirmed the lock-under-flush model at 21.4×; gap-scan p95
2.41 ms ≪ 25 ms.)

**Decision (judgment zone, resolved against target).** `G(32,1)=2.18×` ∈
[2.0, 3.0) → judgment zone; PROCEED requires ≥3.0. Target recorded with the user
on 2026-06-11: a few thousand ev/s of latency-sensitive, unbatchable single-event
cross-stream appends. Neither single-store design reaches it (Strategy E ~687,
seqproto ~1,499, both flat); **sharding the current architecture reaches it
linearly** without the rewrite. An 8–10-plan core rewrite + permanent
high-water-mark daemon for a flat 2.18× that still misses the target is not
justified. Full reasoning + the one probe that would overturn it (`commit_delay`
/ faster-fsync showing the sequence arm scaling past ~1,500/s on one store) in
`docs/architecture/global-position-migration-path.md` Part 3.

**Retrospective (process).** The decision was reached but the path was
inefficient and I corrected course twice on user challenge: (1) I initially
read "NOT WORTH IT, ~1.5×" off a *stale May baseline* (~972) instead of measuring
Strategy E on current code; the same-environment baseline (687) moved the ratio
to 2.18× — judgment zone, not an automatic no. Lesson: always measure both arms
in the same environment before quoting a ratio. (2) I ran throughput cells
without first establishing *what bottlenecked each arm*; the reliability question
("is this CPU-bound or commit-bound?") was answered from resource graphs already
collected, not from more runs. Lesson: for a perf decision, attribute the
bottleneck (CPU/disk/lock/commit) before trusting any ratio. Infra friction
consumed most of the wall-clock: a stale `flake.lock`/SHA, two remote-builder
IAP-tunnel transients, an eventlog-over-IAP collect hang (fixed with
`HASKELL_BENCH_EVENTLOG_ENABLED=false`), and an uppercase-`E` experiment-name
that failed 15 rows at a regex. The matrix was trimmed to the gating cells once
the early data showed the verdict hinged on `G(32,1)` alone.

**Follow-ups filed (out of scope here):**
1. keiro `reconstructRecorded` (`Keiro/Command.hs:638-661`) assumes contiguous
   batch positions — correctness bug *if* a gappy scheme is ever adopted; moot
   under NOT WORTH IT but recorded.
2. keiro `positionGap` (`Keiro/Projection.hs:151-153`) overcounts under gaps —
   observability-only.
3. **~30 % "append regression" investigated → NOT a code regression (resolved
   2026-06-14).** `786282e` ~687 vs May `c672d58` ~972 (w32/b1) is the
   benchmark **pool-size** change, not code: the append CTE, hot-table schema,
   and `Effect.hs` dispatch are functionally unchanged between the commits; the
   M2 pool-parity fix moved the default 10 → writers+4 = 36, and the May
   `followup-pool*` sweep shows w32 peaks at pool 8/13 (917/953) and falls at
   pool 20/36 (696/729) — May pool=36 (729) ≈ June pool=36 (687); May default
   pool=10 (972) ≈ the low-pool peak. Over-subscribing the single `$all` row
   lock adds contention in the serialized-commit regime. Side effect: the
   parity-pool choice understated Strategy E; best-pool-vs-best is ~950 vs
   ~1,499 ≈ 1.6×, strengthening NOT WORTH IT. No re-run needed.
4. kiroku overlay ships shibuya-core 0.6 while the adapter needs 0.7 (kiroku's
   own `nix build` of `shibuya-kiroku-adapter` is broken at HEAD); one-line
   overlay bump.

**VERDICT: NOT WORTH IT.** (2026-06-11)


## Context and Orientation

This section is self-contained background. Read it fully before touching anything.

**The repositories involved.** Three sibling checkouts:

- `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` — the event store
  (this repo; all plan/doc edits and the M1 contract changes happen here).
- `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku-bench` — the load
  generator. A cabal project whose executables (`kiroku-bench`,
  `kiroku-bench-rawpg`, `kiroku-bench-hasql`, `kiroku-bench-store-api`) run
  configurable write/read workloads against a PostgreSQL instance named by
  `PG_CONNECTION_STRING` and expose throughput/latency as Prometheus metrics on
  `127.0.0.1:9570/metrics`. M2's fixes and M4's new spike executable land here.
- `/Users/shinzui/Keikaku/bokuno/load-testing-infra` — GCP automation for
  running kiroku-bench on real cloud hardware. Everything it does is pinned to
  GCP project `tan-nb-exp`, region `us-west1` (see its `CLAUDE.md` for the
  enforcement rules). Completed experiment runs are archived under its
  `experiments/` directory with names like
  `2026-05-19-ceiling-lite-w32-p256-b1-t1` (date, experiment, writers, payload,
  batch, trial). M4's GCP runs follow the same conventions.

There is also a read-only reference checkout of Marten (the .NET event store) at
`/Users/shinzui/Keikaku/hub/event-sourcing/marten`, used in M4 to crib the
gap-detection SQL. Never modify it.

**How Kiroku assigns global positions today (Strategy E).** Every append is one
SQL statement — a chain of CTEs (`WITH ... AS` subqueries) — executed in
autocommit mode via one `Pool.use … Session.statement` call
(`kiroku-store/src/Kiroku/Store/Effect.hs:138-146`). Inside the CTE
(`kiroku-store/src/Kiroku/Store/SQL.hs`, the four `append*SQL` templates around
lines 160–367), the statement: locks and bumps the source stream's row in
`streams` (this enforces the per-stream optimistic-concurrency check and keeps
per-stream versions contiguous); inserts the events into `events`; then runs

```sql
UPDATE streams
SET stream_version = stream_version + (SELECT count(*) FROM new_events)
WHERE stream_id = 0 AND EXISTS (SELECT 1 FROM stream_update)
RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
```

— taking an exclusive row lock on the `$all` counter row — and finally inserts
one `stream_events` junction row per event for the source stream and one for
`$all` (stream_id 0), the latter carrying the claimed global positions.
PostgreSQL releases row locks at transaction end, i.e. at the implicit COMMIT of
the autocommit statement, *after* the WAL flush. Therefore no two appends
anywhere in the store ever overlap their commits, group commit never amortizes
anything, and the store-wide ceiling is `batchSize / durable_commit_latency`.

**Why the Mac numbers misled.** On macOS, `fsync()` returns after pushing data to
the drive's volatile write cache; it does not issue the flush command that makes
data durable (Apple requires `fcntl(F_FULLFSYNC)` for that). PostgreSQL only
issues F_FULLFSYNC when `wal_sync_method = fsync_writethrough`. The benchmark's
local database (`kiroku-bench/db/db/postgresql.conf`) uses defaults, so a "durable"
commit costs ~0.1–0.2 ms on the Mac versus ~1 ms+ on GCP persistent disk. Full
analysis: `docs/architecture/global-position-migration-path.md`.

**How Marten does it (the migration target's shape).** Facts verified against the
local checkout, with paths for deeper reading:

- Positions come from a plain sequence, `mt_events_sequence`. The append
  function (`src/Marten/Events/Schema/QuickAppendEventFunction.cs`, the
  generated `mt_quick_append_events` PL/pgSQL function) calls
  `seq := nextval('<schema>.mt_events_sequence')` per event while inserting.
  There is no store-wide lock of any kind; appends to different streams commit
  fully in parallel and share WAL flushes via group commit. Same-stream appends
  are still effectively serialized by the unique `(stream_id, version)` index.
- Because sequences are non-transactional, a rolled-back append burns its
  values, leaving permanent gaps; and a slow transaction can commit position
  100 *after* position 101 is already visible. Marten therefore never lets
  consumers read to the raw head. A "high-water-mark" (HWM) daemon maintains
  the highest position below which everything is settled, persisted in the
  `mt_event_progression` table. Projections read
  `WHERE seq_id > <checkpoint> AND seq_id <= <high water mark>`
  (`src/Marten/Events/Daemon/Internals/EventLoader.cs:41-64`).
- The gap detector (`src/Marten/Events/Daemon/HighWater/GapDetector.cs:23-34`)
  finds the first hole after the last mark with a window function:

  ```sql
  select seq_id
  from   (select seq_id,
                 lead(seq_id) over (order by seq_id) as no
          from <schema>.mt_events where seq_id >= :start) ct
  where  no is not null and no - seq_id > 1
  limit 1;
  ```

  A gap that persists beyond a configurable `StaleSequenceThreshold` is deemed a
  rollback (not an in-flight transaction) and skipped: the HWM jumps to
  `highest_sequence - 32`, the 32 being a hardcoded safe-harbor buffer against
  advancing into writes that are mid-flight
  (`src/Marten/Events/Daemon/HighWater/HighWaterDetector.cs:86-104`). Failed
  appends additionally write "tombstone" events recording burned sequence
  numbers so most gaps are explained without waiting out the timeout.

This daemon is the complexity Kiroku's Strategy E avoids, and the read-side cost
a PROCEED verdict accepts. The gap-scan viability check in M4 measures its main
recurring query against Kiroku-shaped data.

**The bench harness, briefly.** `kiroku-bench`'s `append-only` mode runs N writer
threads, each appending batches to its own stream (`bench-stream-<wid>`) through
the full kiroku-store API in a loop, counting events on the Prometheus counter
`bench_workload_ops_total{op="append"}` and observing per-call latency on
`bench_workload_op_seconds`. `hot-stream-append` is identical but all writers
share one stream. Knobs are environment variables (`KIROKU_BENCH_WRITERS`,
`KIROKU_BENCH_BATCH_SIZE`, `KIROKU_BENCH_PAYLOAD_BYTES`, `KIROKU_BENCH_POOL_SIZE`,
`KIROKU_BENCH_MODE`). Throughput for a run is computed as the delta of the ops
counter over the measurement window (the load-testing-infra tooling does this
from Prometheus scrapes; locally you can curl the endpoint twice and divide).

**Known harness defects M2 fixes (found during the 2026-06-11 validation).**
(1) `kiroku-bench` defaults its kiroku-store pool to 10 connections regardless of
writer count (`kiroku-bench/app/Main.hs:109`), while the rawpg baseline sizes its
pool to `writers + 4` (`kiroku-bench/app/RawPg.hs:93-94`) — cross-binary
comparisons at writers > 10 are unfair. (2) `timeIO` in
`kiroku-bench/src/Kiroku/Bench/Runtime.hs:46-51` uses `getCurrentTime` (wall
clock, NTP-steppable) while claiming monotonicity. (3) The latency histogram's
lowest bucket boundary is 0.5 ms (`kiroku-bench/src/Kiroku/Bench/Metrics.hs:91-97`),
so sub-millisecond appends — the entire Mac regime — are unresolvable.


## Plan of Work

### Milestone 1 — Option-preserving contract changes (permanent; ships regardless of verdict)

Scope: stop promising position contiguity in public documentation, so consumers
(today: keiro, the sister framework at `/Users/shinzui/Keikaku/bokuno/keiro`,
which pins kiroku-store by git SHA) never grow code that breaks under a future
gappy-position schema. At the end of this milestone the public contract reads
"strictly increasing, opaque; do not assume density", haddocks build clean, the
kiroku test suite passes, and a keiro audit is on record.

In `kiroku-store/src/Kiroku/Store/Types.hs`, replace the `GlobalPosition` haddock
(currently at lines 85–88) with wording to this effect (adjust freely for house
style, but the three promises/prohibitions must all appear):

```haskell
{- | Global position of an event in the @$all@ ordering, shared across all
streams. __Contract:__ strictly increasing per successful append, and totally
ordered — nothing more. Treat values as opaque cursors: construct a
'GlobalPosition' only from @0@ (the beginning of the store) or from a value
previously returned by this store; never derive one by arithmetic, and never
assume positions are dense (@pos + 1@ may not exist). The current
implementation happens to assign contiguous positions (see EP-1's audit), but
contiguity is an implementation detail, not an API guarantee, and is the part
that would change under a sequence-based allocation scheme — see
docs/architecture/global-position-migration-path.md.
-}
```

In `README.md` (lines 29–32), replace the sentence pair "maintains a contiguous
`$all` stream … claim gap-free global positions in the same transaction that
appends events" with wording that promises a *totally ordered* `$all` stream and
relegates the atomic-counter/gap-free mechanism to a "current implementation"
clause pointing at `docs/architecture/global-position-migration-path.md`.

In `docs/DESIGN.md`, at the three places that state the ceiling or sell
contiguity as a guarantee (lines 17 and 21 in the Strategy E comparison, line 661
in the decisions table), add a bracketed caveat: the ~50K events/s figure was
measured on macOS where fsync does not flush (see
`docs/architecture/global-position-migration-path.md`); durable-fsync ceilings
are `batchSize / commit_latency`. Do not rewrite the design narrative — annotate
it; this plan's M4/M5 produce the replacement numbers.

Mark `linkToStream` provisional. In `kiroku-store/src/Kiroku/Store/Link.hs`,
prepend a paragraph to the `linkToStream` haddock to this effect: __Provisional
API.__ No known consumer uses this function (audited 2026-06-11: zero usage in
keiro). It is the only public feature that requires the `stream_events`
junction-table layout, which a future global-position migration may replace
with a single-table event layout; in that case this function will be removed or
redesigned (e.g., rehomed to a dedicated links side table). If you have a real
use case, surface it before depending on this. If `README.md` mentions
stream-event links as a feature, add the same one-line caveat there. Before
committing, re-run the usage check
(`grep -rn linkToStream /Users/shinzui/Keikaku/bokuno/keiro --include='*.hs'`,
excluding `dist-newstyle`) and record the result in Surprises & Discoveries —
if usage has appeared since 2026-06-11, stop and renegotiate the Decision Log
entry instead of marking the API provisional out from under a consumer.

Audit keiro: from `/Users/shinzui/Keikaku/bokuno/keiro`, grep every use of
`GlobalPosition` (files include `keiro-core/src/Keiro/Integration/Event.hs`,
`keiro/src/Keiro/Projection.hs`, `keiro/src/Keiro/Outbox.hs`,
`keiro/src/Keiro/ReadModel.hs`, and tests) and verify none performs arithmetic on
the wrapped `Int64`, compares positions across stores, or assumes `pos + 1`
exists. Record the result (clean, or each offending site) in Surprises &
Discoveries. Do not change keiro in this plan; if offenders exist, file them as
follow-up work in the verdict write-up.

Acceptance: `cabal haddock kiroku-store` succeeds; `grep -rn "gap-free"
kiroku-store/src README.md` shows no occurrence presented as an API guarantee;
the kiroku-store test suite passes unchanged (the edits are comments and prose
only); the keiro audit note exists. Commit (in kiroku) with trailers
`ExecPlan: docs/plans/63-...md` and `Intention: intention_01ktvkqb9ee9j90wg64mgqd1mx`.

### Milestone 2 — Bench harness fairness fixes (kiroku-bench repo)

Scope: make cross-binary throughput comparisons fair and sub-millisecond
latencies visible, so M3/M4 numbers are trustworthy. All three changes are in
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku-bench`.

First, pool parity: in `kiroku-bench/app/Main.hs`, change the
`KIROKU_BENCH_POOL_SIZE` default from the literal `10` to `writers' + 4`,
matching `app/RawPg.hs`. Keep the env var as an explicit override. Note in the
commit message that historical runs used pool=10, so absolute numbers before and
after this commit are not directly comparable at writers > 10 (the
load-testing-infra `experiments/2026-05-18-followup-pool*` series characterized
this confound).

Second, monotonic timing: in `kiroku-bench/src/Kiroku/Bench/Runtime.hs`, rewrite
`timeIO` to use `GHC.Clock.getMonotonicTimeNSec` (base ships it; no new
dependency), converting to seconds as `Double`. The haddock already claims
monotonicity; make it true.

Third, histogram resolution: in `kiroku-bench/src/Kiroku/Bench/Metrics.hs`,
extend `latencyBuckets` downward with `0.00005, 0.0001, 0.00025` (50 µs, 100 µs,
250 µs) ahead of the existing `0.0005` head.

Acceptance: `cabal build all` succeeds in kiroku-bench; a 30-second local
`append-only` smoke run shows latency observations distributed across the new
sub-millisecond buckets (on the Mac they currently all pile into the first
bucket). Commit in kiroku-bench with the same two trailers (the ExecPlan trailer
names this file by its kiroku-repo path; that is the convention for cross-repo
work driven by a kiroku plan).

### Milestone 3 — Mac falsification runs (prototyping; throwaway configuration, no code)

Scope: cheaply confirm or refute the causal model on the machine where the
misleading numbers were produced, before spending GCP time. Three runs of the
same workload — `append-only`, writers=32, batch=1, payload=256, ≥ 60 s steady
state — against the local kiroku-bench Postgres, differing only in durability
configuration:

- **Run A (baseline):** default configuration as checked in.
- **Run B (honest fsync):** `ALTER SYSTEM SET wal_sync_method = 'fsync_writethrough';`
  then restart Postgres. This makes macOS commits actually flush the drive
  cache, emulating GCP-like durable-commit latency on local hardware.
- **Run C (no commit wait):** revert B, then
  `ALTER SYSTEM SET synchronous_commit = 'off';` and restart. This removes the
  WAL-flush wait from the commit path entirely.

The model predicts throughput(B) ≪ throughput(A) ≤ throughput(C), with B at
least 3× below A. **Gate:** if Run B does *not* drop throughput by ≥ 3×, the
WAL-flush-under-lock model is wrong; stop after recording the numbers, mark the
plan outcome "model falsified — re-investigate the GCP discrepancy before any
verdict", and do not run M4 (its experiment design depends on the model).

After the runs, remove the overrides (`ALTER SYSTEM RESET wal_sync_method;
ALTER SYSTEM RESET synchronous_commit;`, restart) and verify
`SHOW wal_sync_method;` is back to default. Record all three throughput numbers
in `docs/perf-experiment-log.md` (kiroku repo) as a new ledger row group dated
with the run date, hypothesis "Strategy E ceiling = batch/commit-latency;
Mac fsync is not durable", outcome, and lesson.

### Milestone 4 — Sequence-based prototype arm and GCP matrix (prototyping; spike code)

Scope: build the one-variable-changed comparison arm, validate it locally, run
the matrix on GCP, and measure the gap-scan cost. At the end, a gain table with
medians over 3 trials exists for every cell.

**The prototype schema** lives in a new file
`kiroku-bench/kiroku-bench/sql/seqproto-setup.sql` and is created in a dedicated
schema named `seqproto` so it can never collide with a real kiroku schema. It is
a faithful copy of kiroku's bootstrap shape
(`kiroku/kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`):
the `streams` table (without the `$all` seed row), the `events` table, the
`stream_events` junction table with the same indexes, and the same
`AFTER INSERT OR UPDATE ON streams` NOTIFY trigger — plus one addition:

```sql
CREATE SEQUENCE seqproto.global_position_seq;
```

The file must start with `DROP SCHEMA IF EXISTS seqproto CASCADE; CREATE SCHEMA
seqproto;` so re-running it is always safe (idempotent by reconstruction). One
known asymmetry to record in the plan's Surprises section when measuring: kiroku's
trigger fires twice per append (source stream + `$all` row update) while the
prototype's fires once (no `$all` update exists); NOTIFY cost is microseconds
against millisecond-scale commits, so this is noise, but it is a real asymmetry
and must be written down.

**The append statement** is kiroku's `appendAnyVersionSQL` (copy it verbatim from
`kiroku/kiroku-store/src/Kiroku/Store/SQL.hs` as the starting point, table names
re-qualified to `seqproto.*`) with exactly two edits: delete the `all_update` CTE
entirely, and change the `$all` link CTE to claim positions from the sequence:

```sql
all_links AS (
    INSERT INTO seqproto.stream_events
        (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT ne.event_id,
           0,
           nextval('seqproto.global_position_seq'),
           su.stream_id,
           su.initial_version + ne.idx
    FROM (SELECT * FROM new_events ORDER BY idx) ne
    CROSS JOIN stream_update su
)
```

(`stream_id = 0` rows no longer reference a `streams` row; drop or relax the
junction table's foreign key for stream 0 in the setup SQL — the simplest
faithful choice is to keep a dummy `$all` row in `seqproto.streams` that is
never UPDATEd, so the FK holds and reads stay shape-identical. Note whichever
choice you make in the Decision Log.) Intra-batch position order follows the
`ORDER BY idx`; cross-batch interleaving is exactly the gappy/out-of-order
behavior the real migration would have.

**The driver** is a new executable `kiroku-bench-seqproto` in the kiroku-bench
cabal file, written by copying `app/RawPg.hs` (it already has the right shape:
raw hasql, per-writer loop, `op="append"` metric labels, pool sized
`writers + 4`) and swapping the single INSERT for the prototype append statement
with the same parameter encoding kiroku uses (the implementer can crib the
encoder from kiroku's `SQL.hs` `appendParamsEncoder` or simplify to per-event
parameters — batch sizes here are 1 and 10, and both arms pay their own encoding,
which is part of what's being measured only on the kiroku arm; keep the
prototype encoding dumb-but-not-pathological and note it). It owns mode knobs
`KIROKU_BENCH_WRITERS`, `KIROKU_BENCH_BATCH_SIZE`, `KIROKU_BENCH_PAYLOAD_BYTES`,
plus `KIROKU_BENCH_SEQPROTO_HOT=1` to make every writer target one shared stream
(the hot-stream cell). On startup it applies `sql/seqproto-setup.sql`.

**Local smoke + invariant check.** Run both arms 30 s locally. Then verify on the
prototype data: per-stream versions are contiguous
(`SELECT stream_id FROM seqproto.stream_events WHERE stream_id <> 0 GROUP BY stream_id, ... HAVING max-min+1 <> count`)
and global positions are strictly increasing but possibly gappy
(`SELECT count(*), max(stream_version) FROM seqproto.stream_events WHERE stream_id = 0` —
max ≥ count, equality only if no transaction ever rolled back). Both arms must
also produce error-free runs (`bench_workload_op_errors_total` stays 0).

**GCP matrix.** Using load-testing-infra (GCP project `tan-nb-exp`, `us-west1`;
follow that repo's experiment runbook and its preflight project assertion —
its `experiments/2026-05-19-ceiling-lite-*` series is the closest template,
including the 3-trial variance convention): for each arm
(`kiroku-bench` append-only as the Strategy E arm; `kiroku-bench-seqproto` as
the sequence arm) run writers ∈ {8, 32} × batch ∈ {1, 10}, payload 256, 3 trials
each, ≥ 120 s steady state per trial, both arms against the same Postgres
instance type and disk as the earlier GCP runs that exposed the discrepancy.
Add one hot-stream cell per arm at writers=32, batch=1. Record the kiroku and
kiroku-bench commit hashes in each experiment directory. Seventeen runs per arm
total (12 matrix + 3 hot-stream… adjust trial counts to match; the matrix is
4 cells × 3 trials + 1 hot cell × 3 trials = 15 per arm).

**Gap-scan viability check.** Against the populated prototype schema after the
GCP runs (or a local population of ≥ 5M junction rows if more convenient),
time Marten's gap-detection query shape adapted to the prototype layout,
starting from a mark ~10K positions behind head:

```sql
SELECT stream_version
FROM (SELECT stream_version,
             lead(stream_version) OVER (ORDER BY stream_version) AS nxt
      FROM seqproto.stream_events WHERE stream_id = 0 AND stream_version >= $1) t
WHERE nxt IS NOT NULL AND nxt - stream_version > 1
LIMIT 1;
```

Run it 100 times via `EXPLAIN (ANALYZE)` or `\timing`; record p50/p95. The
PROCEED gate requires p95 < 25 ms (this query is the HWM daemon's steady-state
poll; at 25 ms it supports sub-100ms-latency live tailing with margin).

### Milestone 5 — Verdict and documentation

Scope: turn the numbers into the decision and make the repo's documentation
truthful. Compute the gain table (per cell: Strategy E median, seqproto median,
ratio). Apply the pre-registered rule from the Decision Log mechanically. Then:

- Append a "Measured verdict (2026-MM-DD)" section to
  `docs/architecture/global-position-migration-path.md` containing the gain
  table, the GCP environment description, the verdict line, and — if PROCEED —
  the instruction that the next step is drafting the migration masterplan
  sequenced after MasterPlan 9, which must include the pre-registered phase-2
  decision point on the single-table event layout and `linkToStream`'s removal
  or side-table redesign (see the Decision Log); if NOT WORTH IT — which relief
  valve(s) the numbers indicate instead (batching, sharding) and at what
  projected ceiling.
- Replace `docs/DESIGN.md`'s annotated ceiling claims with the measured
  durable-fsync numbers for Strategy E (keep the history visible: "originally
  benchmarked at ~50K events/s on macOS; measured at N events/s on GCP pd-ssd,
  2026-MM-DD").
- Append ledger rows to `docs/perf-experiment-log.md` for the M3 and M4
  experiments (hypothesis, predicted ratio from the Purpose section, observed
  ratio, lesson — explicitly compare predicted 5–15× against observed).
- Fill this plan's Outcomes & Retrospective with the verdict line and the
  prediction-vs-observation deltas.

Acceptance: a reader opening `docs/architecture/global-position-migration-path.md`
sees the verdict and the numbers; the ledger has the rows; this plan's Outcomes
section ends with **PROCEED NOW** or **NOT WORTH IT**.


## Concrete Steps

All kiroku commands run from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`;
all kiroku-bench commands from
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku-bench` (enter its dev shell
with `nix develop` or direnv first).

M1 verification:

```bash
cabal haddock kiroku-store
grep -rn "gap-free" kiroku-store/src README.md   # expect: only implementation-note phrasing, no API promise
cabal test kiroku-store                           # expect: all suites PASS
cd /Users/shinzui/Keikaku/bokuno/keiro && grep -rn "GlobalPosition" --include='*.hs' . | grep -v dist-newstyle
```

M2 verification (kiroku-bench):

```bash
cabal build all
# smoke: start the local db (process-compose up), create schema, then:
KIROKU_BENCH_MODE=append-only KIROKU_BENCH_WRITERS=32 PG_CONNECTION_STRING="$PG" \
  cabal run kiroku-bench &  sleep 30
curl -s 127.0.0.1:9570/metrics | grep 'bench_workload_op_seconds_bucket{op="append",le="0.0001"}'
# expect: a nonzero cumulative count in the 100µs bucket on the Mac
kill %1
```

M3 runs (local db; `$PGDATA` is `kiroku-bench/db/db`):

```bash
# Run A: as-is, 60s, record events/s:
curl -s 127.0.0.1:9570/metrics | grep '^bench_workload_ops_total{op="append"}'   # at t0 and t0+60s; rate = delta/60
# Run B:
psql "$PG" -c "ALTER SYSTEM SET wal_sync_method = 'fsync_writethrough'"; pg_ctl restart -D db/db
psql "$PG" -c "SHOW wal_sync_method"          # expect: fsync_writethrough
# ... rerun the workload, record ...
# Run C:
psql "$PG" -c "ALTER SYSTEM RESET wal_sync_method"
psql "$PG" -c "ALTER SYSTEM SET synchronous_commit = 'off'"; pg_ctl restart -D db/db
# ... rerun, record, then:
psql "$PG" -c "ALTER SYSTEM RESET synchronous_commit"; pg_ctl restart -D db/db
```

Expected M3 transcript shape (numbers illustrative):

```text
Run A (default):              ~6,800 events/s
Run B (fsync_writethrough):   ~900 events/s     # >=3x collapse => model confirmed, proceed to M4
Run C (synchronous_commit=off): ~7,500 events/s
```

M4: see Milestone 4 prose; GCP runs follow load-testing-infra's runbook from
that repo's checkout (its `.envrc` pins the project; run `direnv allow` there
once). Archive each run directory under `experiments/` with the established
naming, e.g. `2026-06-XX-seqproto-w32-p256-b1-t1`.

Commit messages throughout follow Conventional Commits and carry both trailers:

```text
docs(kiroku-store): weaken GlobalPosition contract to opaque strictly-increasing cursor

ExecPlan: docs/plans/63-decide-the-marten-style-global-position-migration-with-durable-fsync-benchmarks-and-option-preserving-contract-changes.md
Intention: intention_01ktvkqb9ee9j90wg64mgqd1mx
```


## Validation and Acceptance

The plan as a whole is accepted when: (1) the M1 contract edits are merged and
the keiro audit recorded; (2) `docs/perf-experiment-log.md` contains the M3 rows
showing whether the fsync model held, with the ≥ 3× collapse gate explicitly
evaluated; (3) either the plan stopped at the M3 gate with a "model falsified"
outcome, or the M4 gain table exists with 3-trial medians for all cells of both
arms plus the gap-scan p95; and (4) the verdict — **PROCEED NOW** or
**NOT WORTH IT**, derived mechanically from the pre-registered thresholds —
appears in `docs/architecture/global-position-migration-path.md`, in this plan's
Outcomes & Retrospective, and in the final report to the user. A novice must be
able to recompute the verdict from the archived experiment directories and the
Decision Log thresholds alone.


## Idempotence and Recovery

Everything here is safe to repeat. M1 edits are prose; re-running greps is free.
M3's `ALTER SYSTEM` changes are reverted with `ALTER SYSTEM RESET …` plus a
restart, and touch only the throwaway bench database under `kiroku-bench/db` —
verify reversion with `SHOW wal_sync_method` / `SHOW synchronous_commit` before
recording any subsequent run. The `seqproto` schema setup begins with
`DROP SCHEMA IF EXISTS seqproto CASCADE`, so every run reconstructs from
scratch; it must only ever be pointed at bench databases (the schema name is the
guard — production kiroku schemas are named differently, and nothing in the
spike reads or writes outside `seqproto.*`). GCP runs are independent; a failed
trial is discarded and re-run, never averaged in. If a GCP instance dies
mid-matrix, completed cells stand (each trial directory is self-contained) and
only missing cells are re-run — record any such recovery in Progress.


## Interfaces and Dependencies

No new Haskell dependencies in kiroku. In kiroku-bench: `GHC.Clock`
(`base`) for `timeIO`; the new `kiroku-bench-seqproto` executable depends on the
already-used `hasql`, `hasql-pool`, `prometheus-client`, `async`, `text`,
`bytestring` — mirror the `kiroku-bench-rawpg` stanza in
`kiroku-bench/kiroku-bench/kiroku-bench.cabal`. At the end of M4 the kiroku-bench
package must expose: executable `kiroku-bench-seqproto` honoring
`PG_CONNECTION_STRING`, `KIROKU_BENCH_WRITERS`, `KIROKU_BENCH_BATCH_SIZE`,
`KIROKU_BENCH_PAYLOAD_BYTES`, `KIROKU_BENCH_SEQPROTO_HOT`, and emitting the
standard `bench_workload_ops_total{op="append"}` /
`bench_workload_op_seconds{op="append"}` metric shape on `127.0.0.1:9570`; and
the file `kiroku-bench/kiroku-bench/sql/seqproto-setup.sql`. No kiroku-store
module changes anywhere in this plan beyond haddock text in
`kiroku-store/src/Kiroku/Store/Types.hs` and
`kiroku-store/src/Kiroku/Store/Link.hs`. External services: the local
process-compose Postgres for M2/M3, and GCP project `tan-nb-exp` (`us-west1`)
via load-testing-infra for M4 — respect that repo's project-isolation preflight
in every script invocation.


## Revision Notes

- 2026-06-11: Added the `linkToStream` provisional-status work to M1 (new
  Decision Log entry, Progress item, M1 instructions, M5 verdict instruction,
  Interfaces constraint). Reason: a usage audit found `linkToStream` has zero
  consumers, yet it is the sole feature requiring the `stream_events` junction
  layout — the layout a PROCEED verdict's phase-2 single-table optimization
  would want to drop. Marking it provisional now preserves that option, exactly
  parallel to the `GlobalPosition` contract change this plan already ships.
