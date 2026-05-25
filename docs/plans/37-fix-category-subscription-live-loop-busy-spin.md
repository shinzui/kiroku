---
id: 37
slug: fix-category-subscription-live-loop-busy-spin
title: "Fix Category subscription live-loop busy-spin (liveLoopDbDriven)"
kind: exec-plan
created_at: 2026-05-25T22:35:00Z
---


# Fix Category subscription live-loop busy-spin (liveLoopDbDriven)

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A live `Category` subscription (and any consumer-group member) busy-spins —
re-issuing its category fetch query as fast as the CPU allows, doing zero useful
work — whenever its category's tail lags the store's global `$all` tail. In
production this was found the hard way: the downstream `rei` deployment, which
runs ~29 `Category` subscription workers (one per bounded context) over a single
shared kiroku store, pegged **581 % CPU** (≈6 saturated cores) on its
`rei worker kiroku` process and flooded PostgreSQL with a constant stream of
identical category `SELECT`s (10 backends each at ~28 %). Root-caused 2026-05-25
to `liveLoopDbDriven` in
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`.

The defect is a single mis-chosen gate condition. The DB-driven live loop blocks
until the publisher's **global** position advances past the subscriber's
**per-category** cursor:

```haskell
-- kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:279 (buggy)
go cursor = do
    writeIORef posRef cursor
    atomically $ do
        pubPos <- readTVar pubPosVar      -- GLOBAL $all position (all categories)
        check (pubPos > cursor)           -- cursor = THIS category's data position
    events <- fetchBatch pool config cursor emit stSettings  -- WHERE category=$2 AND global_position > cursor
    if V.null events
        then go cursor                    -- spin: cursor unchanged, pubPos still > cursor
        else ...
```

`pubPosVar` is the single global `EventPublisher.lastPublished` cursor, advanced
on **every** append to any stream. `cursor` only advances when *this category*
produces an event. So the moment any *other* category is appended to,
`pubPos > cursor` becomes (and stays) true; the category-filtered `fetchBatch`
returns empty; the loop recurses `go cursor` with an unchanged `cursor`, the STM
`check` passes again immediately, and the worker spins — one category `SELECT`
per loop iteration, unbounded, with no `threadDelay` or backpressure. Every
`Category` subscriber whose category is "behind" the global tail spins; in a
multi-category deployment that is, in steady state, most of them.

The sibling `AllStreams` live loop (`liveLoop`) is immune: it blocks on
`readTBQueue liveQueue`, which only wakes when the publisher broadcasts an event
to that specific subscriber. The bug is unique to the DB-poll path
(`liveLoopDbDriven`), which serves non-group `Category` subscriptions and **all**
consumer-group members (see the dispatch at `Worker.hs:110-113`).

**Chosen architecture (revised 2026-05-25): drive `Category` wakeups from the
per-category NOTIFY signal that the system already produces but currently throws
away.** The append trigger emits the originating stream's identity on every
append:

```sql
-- 2026-05-16-...-kiroku-bootstrap.sql:148 (notify_events trigger)
PERFORM pg_notify(TG_TABLE_SCHEMA || '.events',
                  NEW.stream_name || ',' || NEW.stream_id || ',' || NEW.stream_version);
```

…but the Notifier discards it (`Notification.hs:155`):

```haskell
waitForNotifications (\_ _ -> atomically (writeTChan chan ())) currentConn
```

`\_ _ ->` drops the channel and payload and writes a bare `()` tick, collapsing
all per-stream information to a single global wakeup plus the publisher's global
`lastPublished` position. That is *why* `liveLoopDbDriven` can only gate on the
global position — the per-category information was destroyed two layers upstream.
The category column itself is `GENERATED ALWAYS AS (split_part(stream_name,'-',1))
STORED`, so the category is recoverable from the payload's `stream_name` with the
identical rule (no migration, no trigger change).

The fix therefore stops discarding the payload and uses it to wake each
`Category` subscriber **only when its own category changes**:

- **`(Nothing, Category cat)`** → a new `liveLoopCategoryNotify` that blocks on a
  per-category generation counter and re-queries only when *that* category is
  notified (or a safety timeout fires). An idle category does **zero** DB work
  even while other categories receive sustained traffic — not "one round-trip per
  global tick", but none.
- **`(Just _, _)` (consumer-group members)** → keep `liveLoopDbDriven`, but with
  its wake condition corrected to gate on the **last observed global position**
  instead of the per-category cursor (the original "Option A" fix). A member's
  interest is `hashtextextended(stream_id) % size = member`, which cannot be
  derived from the payload without replicating Postgres's hash and which the
  publisher cannot precompute (it does not know group sizes); the global-position
  gate is the correct, spin-free architecture for that path.
- **`(Nothing, AllStreams)`** → `liveLoop`, unchanged (already optimal: blocks on
  the broadcast queue).

The publisher and the AllStreams broadcast path are untouched — the Notifier
still writes the same `()` tick. Delivery is still at-least-once and the
checkpoint/cursor semantics are unchanged; only the *wake condition* of the live
Category and group loops changes. Missed notifications (a listener reconnect drops
NOTIFYs during the gap) are reconciled by a per-worker safety timeout that mirrors
the publisher's existing 30-second safety poll, so the at-least-once + bounded-
latency guarantee is preserved.

Acceptance command:

```bash
cabal test kiroku-store
```

must report `0 failures`, including new specs that (a) drive an idle subscribed
`Category` while a *different* category receives sustained appends and assert the
idle subscriber does **zero** category reads in that window (it grows without
bound before this fix), (b) assert a real append to the subscribed category is
still delivered promptly (guarding against a worker that never wakes), and (c)
cover the consumer-group idle-partition path under its corrected gate.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Investigation — root cause + impact + load-test-gap analysis: **DONE 2026-05-25.**

- [x] Root-caused the production 581 % CPU on `rei worker kiroku` to the
      `liveLoopDbDriven` empty-fetch spin (gate compares global `pubPos` to
      per-category `cursor`). Evidence captured in Purpose and Context. (2026-05-25)
- [x] Confirmed `AllStreams` `liveLoop` is immune (blocks on `readTBQueue`), so
      the defect is isolated to the DB-poll path. (2026-05-25)
- [x] Confirmed the path also serves consumer-group members (same dispatch), so
      the fix is not Category-only. (2026-05-25)
- [x] Established why the kiroku-bench / load-testing-infra suite never caught it
      (see Surprises & Discoveries). (2026-05-25)
- [x] Validation pass — reviewed the proposed Milestone-1 diff against the live
      `Worker.hs` / `EventPublisher.hs` and Milestones 2–3 against the test
      harness. Verdict: the fix is correct and introduces **no functional or
      performance regression** (it strictly reduces fetches versus the buggy
      loop in every scenario; reasoning in Decision Log + Surprises). Corrected
      two plan-accuracy gaps: `pg_stat_statements` is not available in the test
      Postgres, and the new spec module must be registered in
      `kiroku-store.cabal`. (2026-05-25)

Milestone 1 — per-category wake signal in the Notifier: **DONE 2026-05-25.**

- [x] Added the additive `KirokuEventSubscriptionFetched` constructor to
      `Kiroku.Store.Observability` (used by both live loops as the test's
      deterministic fetch counter). (2026-05-25)
- [x] Added `categoryGenerations :: TVar (Map Text Word64)` to `Notifier`, created
      inside `startNotifier` and exposed on the record (`Connection.hs` untouched).
      (2026-05-25)
- [x] Changed the `waitForNotifications` callback to keep writing the `()` tick
      **and** parse the payload's `stream_name` → category (`handleNotification` /
      `categoryFromPayload`) and bump that category's generation. (2026-05-25)
- [x] Added `bytestring` to the `kiroku-store` library `build-depends` (it was not
      previously a direct dependency — see Surprises). (2026-05-25)
- [x] `cabal build all` clean — the additive `KirokuEvent` constructor broke no
      exhaustive matches (no `-Werror` fallout). (2026-05-25)

Milestone 2 — new Category loop + corrected group loop + wiring: **DONE 2026-05-25.**

- [x] `Worker.hs`: added `liveLoopCategoryNotify` (drain-first, then block on the
      category generation OR a safety timeout); corrected `liveLoopDbDriven`'s gate
      to the last observed global position (now consumer-group-only); both emit
      `KirokuEventSubscriptionFetched` per live fetch; dispatch
      `(Nothing, Category{})` → new loop, `(Just _, _)` → corrected group loop;
      added `catGenVar :: TVar (Map Text Word64)` to `runWorker` (after
      `pubPosVar`); added `categorySafetyPollMicros = 30_000_000`
      (`NumericUnderscores` is on via GHC2024). (2026-05-25)
- [x] `Subscription.hs`: passes `Notifier.categoryGenerations (store ^. #notifier)`
      to `runWorker` (new qualified `Kiroku.Store.Notification` import). (2026-05-25)
- [x] `cabal build all` clean — all 14 components linked; no `-Werror` fallout from
      the new `runWorker` arity or the new live loop. (2026-05-25)

Milestone 3 — regression tests: **DONE 2026-05-25.**

- [x] Added `kiroku-store/test/Test/CategoryIdleNoSpin.hs` with two specs. Spec A:
      an idle `Category "alpha"` subscriber does **zero** fetches (delta `== 0`,
      snapshotted after the initial post-catch-up drain) while a 20-stream `beta`
      burst advances the global tail, delivers nothing during the idle window, and
      is delivered exactly one event after a real `alpha-1` append (liveness).
      (2026-05-25)
- [x] Spec B: an idle size-3 consumer-group member on category `grp` (which gets
      no events) stays bounded (`< 50` fetches) while a 20-stream `flood` burst in
      a *different* category advances the global position — covers the corrected
      `liveLoopDbDriven`. (2026-05-25)
- [x] Registered `Test.CategoryIdleNoSpin` in `kiroku-store.cabal` `other-modules`
      and wired `CategoryIdleNoSpin.spec` into `Main.hs`. (2026-05-25)
- [x] `cabal test kiroku-store` green: **160 examples, 0 failures** (was 158;
      +2 new). `cabal test shibuya-kiroku-adapter` green: **8 examples, 0
      failures** (no collateral change to the consumer-group / `Category` live
      paths). (2026-05-25)
- [x] Proved the specs pin the regression: temporarily restored the cursor-gated
      `liveLoopDbDriven` body and routed `(Nothing, Category{})` back through it —
      both specs failed to pass (the worker busy-spun and livelocked the run,
      pegging ~50 % CPU per process and never completing; killed via SIGTERM).
      Restored the fix via `git checkout`; suite green again. (2026-05-25)

Milestone 4 — changelog + downstream re-enable: **NOT STARTED.**

- [ ] CHANGELOG entry under `## Unreleased` in `kiroku-store/CHANGELOG.md`.
- [ ] Downstream `rei`: rebuild `rei-cli` against the fixed pin, redeploy the
      `com.shinzui.rei-worker-kiroku` agent, and re-enable it + the
      `com.shinzui.rei-watchdog` agent (both were `launchctl disable`/`bootout`
      as the 2026-05-25 mitigation). Confirm worker CPU is near-idle even under
      cross-context flow. (Tracked downstream, not in this repo.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Why extensive load testing did not catch this (kiroku-bench driver +
  load-testing-infra GCP orchestration).** Three independent gaps, each
  sufficient on its own:

  1. *The buggy code path was never executed.* Across all recorded experiment
     runs, every subscription-exercising mode (`subscription-latency`,
     `subscription-catchup`, `shibuya-adapter`) ran with
     `KIROKU_BENCH_SUBSCRIPTION_TARGET=all` (7/7 subscription runs = `all`,
     0 = `category`). That is the `AllStreams` `liveLoop` path, which is immune.
     `liveLoopDbDriven` had zero benchmark coverage; the `AllStreams`-vs-`Category`
     comparison was the deferred Phase-2 fan-out milestone (load-testing-infra
     masterplan 4, EP-3 / M4) and never ran.

  2. *Even `category` mode could not reproduce it — the bench is single-category.*
     `kiroku-bench`'s subscription producer writes only `bench-stream-<wid>`
     streams (`Kiroku.Bench.Modes.SubscriptionLatency.runProducer` →
     `streamNameFor`), all in category `bench-stream`, and a `category` subscriber
     watches `bench-stream` (default `KIROKU_BENCH_SUBSCRIPTION_CATEGORY`). The
     subscribed category is therefore the *only* category producing events, so
     the global tail and the category tail advance together and `fetchBatch` is
     never empty-while-`pubPos`-advanced. The spin requires ≥2 categories with
     cross-traffic (production has 29; the bench has 1).

  3. *No idle-CPU signal, wrong topology.* The entire metric set (IP-17/IP-20:
     `append_to_handler_seconds`, `catchup_seconds`, `queue_depth`,
     `overflows_total`, ops/sec) measures latency/throughput under *continuous
     active load*. The spin does no useful work — it doesn't move any of those
     numbers — and the bench never models an idle subscribed category alongside a
     busy one. Production topology (N heterogeneous `Category` subscribers on
     distinct categories sharing one store) was never modeled.

  Lesson: this is a *deployment-topology* defect, not a *library-under-load*
  defect. The benchmark characterized kiroku as a single-workload library; the
  trigger is emergent from running many `Category` subscribers over a shared
  store with cross-category flow and idle periods. A repro needs: subscriber on
  category A, producer writing **only** to category B, observing A's worker.

- **`AllStreams` immunity is structural, not incidental.** `liveLoop`
  (`Worker.hs:233`) blocks in STM on `readTBQueue liveQueue`; the publisher only
  enqueues to a subscriber's queue when it broadcasts an event, so there is no
  "wake with nothing to do" path. `liveLoopDbDriven` replaced that per-subscriber
  blocking dequeue with a global-position gate but kept comparing against the
  per-category cursor — that mismatch is the whole bug.

- **Red herring during triage:** the downstream `rei` process also logged
  `WrongExpectedVersion {expectedVersion = 37, streamVersion = 38}` from its
  *legacy* `MessageDb` path (`Rei.Modules.Intention.Infrastructure.Repository`),
  unrelated to kiroku and to this CPU issue. Likewise the bench's
  `expected-version-conflict` mode is a write-path contention shape, not this
  subscription spin. Neither is in scope here.

- **Validation finding — the fix is a strict fetch-count reduction, not a
  trade-off.** Reviewing the Milestone-1 diff against the live code: `fetchBatch`
  takes no `pubPos` bound (it reads `WHERE … stream_version > cursor` limited by
  `batchSize`), and `drainTo` recurses on `newPos` until the fetch is empty. So
  after each drain there are zero visible category events past the cursor, and
  because the `$all` position is strictly monotonic (`EventPublisher.hs:206-219`),
  any later category event lands at a position strictly greater than the observed
  `pubPos` — guaranteeing the gate re-opens. The new loop therefore issues *fewer
  or equal* fetches than the buggy loop in every scenario (idle: one per
  publisher tick instead of unbounded; active: identical draining plus the same
  single terminating empty fetch). There is no scenario in which it fetches more,
  so there is no performance regression to weigh — only the documented
  one-round-trip-per-tick idle cost, which the LISTEN/NOTIFY follow-up would
  further reduce.

- **Validation finding — `pg_stat_statements` is not wired into the suite.** A
  repo-wide search returns zero references (`*.hs`/`*.cabal`/`*.sql`/`*.nix`),
  `Test.Helpers` exposes no such helper, and `Kiroku.Test.Postgres` brings up the
  ephemeral server with `Pg.defaultConfig` and applies only the bootstrap
  migration. Collecting `pg_stat_statements` requires `shared_preload_libraries`
  at server start, so the originally-written "preferred" counter is not runnable.
  The regression-test milestone uses an additive observability fetch event as the
  deterministic discriminator instead (see Decision Log).

- **Validation finding — new spec modules need cabal registration.** The
  `kiroku-store-test` stanza in `kiroku-store/kiroku-store.cabal` lists every
  `Test.*` module under `other-modules`; a module imported into `Main.hs` but
  omitted there fails the build. The regression-test milestone calls this out
  explicitly.

- **Architecture discovery (2026-05-25) — the per-category wake signal already
  exists end-to-end but is discarded at the Notifier.** The `notify_events`
  trigger sends `stream_name,stream_id,stream_version` on every append
  (`2026-05-16-...-kiroku-bootstrap.sql:148`), and `streams.category` is
  `GENERATED ALWAYS AS (split_part(stream_name,'-',1)) STORED` (schema line 51),
  so the category is recoverable from the payload with no migration. But the
  Notifier's listener callback is `\_ _ -> atomically (writeTChan chan ())`
  (`Notification.hs:155`): it throws away both the channel and the payload and
  writes a bare `()` tick. Every downstream consumer therefore sees only a global
  wakeup plus the publisher's global `lastPublished` position — which is the sole
  reason `liveLoopDbDriven` had to gate on the global position in the first place.
  This reframed the fix: rather than work around the coarse global signal (Option
  A), *stop discarding the fine-grained one*. The `RecordedEvent`-has-no-stream-
  name design (see [[project_recordedevent_streamname_decision]]) is why the
  publisher's broadcast queue cannot serve `Category` directly; the NOTIFY payload
  is a *separate* channel that does carry the stream name, so it is the right
  place to recover per-category routing. Consumer groups still cannot use it
  (their partition is a Postgres hash the worker cannot cheaply replicate), so
  they keep the global-position gate.


## Decision Log

Record every decision made while working on the plan.

- Decision (Milestone 3, 2026-05-25): **Spec B floods a *different category*
  rather than other partitions of the member's own category.** The plan suggested
  using `readCategoryForwardConsumerGroupStmt` to pick streams that hash to other
  members; in practice the partition predicate hashes `stream_id` (a server-side
  TypeID assigned at creation), which the test cannot predict from a stream name,
  so isolating "streams that hash to non-member-0" is fiddly. The corrected
  `liveLoopDbDriven` gate keys on `pubPos`-vs-`waitFrom`, not on category — so a
  member of a group on category `grp` (which receives **no** events) while a
  different category `flood` is hammered exercises the identical gate logic, and
  the member receives a deterministic **zero** events (no hash dependency). This
  is strictly simpler and at least as strong a test of the spin. Recorded so the
  divergence from the plan's suggested mechanism is explicit.
  Date: 2026-05-25

- Decision/finding (Milestone 3, 2026-05-25): **the two live loops drain at
  different points, which the specs must account for.** `liveLoopCategoryNotify`
  drains *before* gating, so after catch-up an idle category emits exactly one
  empty `KirokuEventSubscriptionFetched` then blocks — Spec A snapshots its
  baseline *after* waiting for that first fetch (`fetchVar >= 1`) and asserts the
  post-burst delta is `0`. The corrected `liveLoopDbDriven` gates *before*
  draining, so on an empty store an idle member emits **zero** fetches until the
  global position first advances — Spec B needs no baseline and asserts the raw
  count stays `< 50`. Documented because it is the non-obvious reason the two
  specs are shaped differently.
  Date: 2026-05-25

- Finding (validation, 2026-05-25): **the busy-spin reproduces as a livelock, not
  a clean assertion failure.** With the cursor-gated body restored and `Category`
  routed back to it, the spinning worker pegged a core and starved the connection
  pool / scheduler so the spec body never reached its assertion (two test
  processes ran 9:58 and 4:30 of CPU time without completing; terminated by
  SIGTERM, exit 144). This is a *stronger* demonstration of the production
  symptom (581 % CPU, identical SELECTs) than a numeric count would have been: the
  spec does not pass against the bug, which is exactly what the validation step
  requires. The fixed code runs the same two specs in ~1.3 s.
  Date: 2026-05-25

- Implementation note (Milestone 1, 2026-05-25): `bytestring` was not a direct
  `build-depends` of the `kiroku-store` library (only transitive), so the payload
  parsing (`Data.ByteString` / `Data.ByteString.Char8`) failed to compile until it
  was added (`>=0.11 && <0.13`). `containers`, `text`, and `base` were already
  direct deps, so `Data.Map.Strict`, `Data.Text.Encoding`, and `Data.Word` needed
  no cabal change. The additive `KirokuEventSubscriptionFetched` constructor
  compiled `all` clean with no `-Wincomplete-patterns`/`-Werror` breakage in any
  consumer, confirming the module's additive-evolution contract holds in practice.
  Date: 2026-05-25

- Decision (2026-05-25, supersedes the original scope): **adopt the per-category
  NOTIFY-driven wake (Option H) as the primary architecture**, not the
  global-position gate (Option A). A/H were compared after discovering that the
  Notifier discards the per-category payload (see Surprises). Rationale: the
  production topology is 29 *non-group* `Category` subscribers on a shared store;
  Option A leaves them polling once per global publisher tick (bounded but
  nonzero under cross-category load), whereas Option H makes an idle category do
  zero DB work by waking only on its own category's NOTIFY. Production was already
  mitigated (worker disabled), so there was no emergency forcing the minimal
  patch. The realized design is *lighter* than the one imagined when this was
  first deferred: it reuses the single existing LISTEN channel (no per-category
  channels) and a per-category generation counter (no publisher-side per-category
  position tracking). The global-position gate (Option A) is retained, but scoped
  to the consumer-group path only.
  Date: 2026-05-25

- Decision: **consumer-group members keep the global-position gate; only
  `(Nothing, Category)` uses the NOTIFY-driven loop.** Rationale: a member's
  interest is `(((hashtextextended(stream_id::text,0) % size)+size)%size) =
  member` (`SQL.hs:813`); the worker cannot cheaply replicate Postgres's
  `hashtextextended` from the payload, and the Notifier/publisher do not know each
  group's size, so a per-category generation cannot encode per-member interest.
  The corrected global gate (block until the publisher advances past the last
  observed global position, then drain the partition to empty) is spin-free and
  correct for that path. This means Option A's fix is still implemented — as the
  group-path loop, not the Category-path loop.
  Date: 2026-05-25

- Decision: **`liveLoopCategoryNotify` drains first, then gates; the gate also
  unblocks on a safety timeout.** Rationale: snapshotting the category generation
  *before* an unconditional drain closes the catch-up→live handoff race (an event
  appended in that window is drained immediately; a notification that arrives
  during the drain leaves `gen > snapshot`, so the next iteration drains again).
  The safety timeout (`registerDelay`, same 30 s cadence as the publisher's safety
  poll, `EventPublisher.hs:94`) reconciles notifications lost while the listener
  connection is down/reconnecting (`Notification.hs` reconnect path), preserving
  the existing at-least-once + bounded-latency guarantee. An idle category thus
  costs at most one empty fetch per safety interval, not per global tick.
  Date: 2026-05-25

- Decision: **derive the category from the payload in Haskell; no migration.**
  Rationale: `streams.category` is `GENERATED ALWAYS AS
  (split_part(stream_name,'-',1)) STORED`, a fixed rule; the worker/notifier
  applies the identical `takeWhile (/= '-')` to the payload's `stream_name`. This
  avoids touching the migration SQL / trigger entirely (keeping the
  no-schema-change property of the original plan). Amending the trigger to send
  `NEW.category` directly is a viable alternative but requires a migration and is
  not worth it for a one-line derivation. Keep the generation map keyed by `Text`.
  Date: 2026-05-25

- Decision: the corrected **group-path** gate waits for `pubPos` to exceed the
  *previously observed* `pubPos`, not the per-category cursor.
  Rationale: `pubPosVar` advances on every append to any category; the category
  cursor advances only on this category's events. Waiting for `pubPos` to exceed
  the cursor therefore unblocks on foreign-category traffic and, since the cursor
  never moves on an empty category fetch, never re-blocks — the spin. Waiting for
  `pubPos` to exceed the *previously observed* `pubPos` blocks until genuinely new
  global work exists, which is the correct wake condition for the consumer-group
  loop. (This is the mechanism of the retained Option-A fix.)
  Date: 2026-05-25

- Decision: Do **not** advance the checkpoint / data cursor to `pubPos` on an empty
  fetch; keep a separate `waitFrom` watermark for the STM gate.
  Rationale: The checkpoint must stay at the last real category event for correct
  `WHERE ... global_position > cursor` fetching and crash-replay semantics
  (delivery is at-least-once, checkpoint per batch). Advancing the data cursor to
  a global position with no category event there would change those semantics.
  Splitting "where to fetch from" (cursor) from "what global position to wait
  past" (waitFrom) fixes the spin without touching checkpointing.
  Date: 2026-05-25

- Decision: Preserve batch-by-batch draining between gates (`drainTo`): after the
  gate opens, fetch and process repeatedly until the category returns empty, then
  re-gate once against the observed `pubPos`.
  Rationale: A category backlog can exceed one `batchSize`. Re-gating after a
  single batch would stall a backlog behind the next global tick; draining to
  empty preserves the pre-fix throughput behavior for an active category and only
  changes the idle case.
  Date: 2026-05-25

- Decision (**superseded** by the Option-H architecture decision): originally,
  scope the change to `liveLoopDbDriven` only and leave everything else untouched.
  This minimal-blast-radius framing held for Option A. Under Option H the change
  necessarily spans `Notification.hs` (preserve + route the payload),
  `Connection.hs` (create/thread the registry), `Subscription.hs` (pass it to
  `runWorker`), and `Worker.hs` (new Category loop + corrected group loop). The
  fetch SQL and checkpoint schema remain untouched, and `liveLoop` (AllStreams)
  and the publisher path remain untouched, so the blast radius is still bounded —
  just wider than a single function body. Recorded so the trade-off is explicit.
  Date: 2026-05-25

- Decision (originally deferred, now **ADOPTED** — this is the chosen fix): wake
  `Category` subscriptions from the per-category NOTIFY signal so an idle category
  does *zero* DB work. Originally deferred on the assumption it required
  "per-category notify channels and publisher-side per-category position
  tracking"; the discovery that the existing single channel already carries the
  stream name (and that a generation counter suffices — positions are not needed)
  collapsed that cost. Superseded the "restore one-round-trip-per-tick" framing:
  we now eliminate the idle round-trips for the Category path entirely. See the
  architecture decision at the top of this log.
  Date: 2026-05-25

- Decision (validation): the Milestone-1 diff is accepted as correct and
  regression-free without modification.
  Rationale: traced against the live `Worker.hs`/`EventPublisher.hs`. The wake
  condition is sound (edge-trigger on the monotonic global position), the drain
  preserves the exact non-empty branch (so checkpoint + at-least-once delivery
  are unchanged), and the loop issues fewer-or-equal fetches than the buggy
  version in every scenario (see Surprises). The initial `waitFrom =
  GlobalPosition 0` also closes the catch-up→live handoff race with one harmless
  reconciling drain. Only the in-code comment was tightened to spell out the
  no-lost-wakeup argument. (Scope note after the Option-H switch: this validated
  loop is now the **consumer-group** path's loop, not the Category path's. The
  analysis stands unchanged for that path.)
  Date: 2026-05-25

- Decision: use an **additive observability fetch event** as Milestone 4's
  deterministic discriminator, emitted in **both** DB-driven live loops
  (`liveLoopCategoryNotify` and `liveLoopDbDriven`, not in shared `fetchBatch`),
  and do not use `pg_stat_statements`.
  Rationale: `pg_stat_statements` is not available in the test Postgres and
  enabling it is a server-level (`shared_preload_libraries`) change, out of
  scope. A deterministic count of the idle worker's category fetches is the only
  signal that cleanly flips between buggy (unbounded) and fixed (zero) — the
  handler-delivery counter does not (an idle category delivers nothing either
  way), and a per-event decode hook cannot see the *empty* fetches that the spin
  consists of. Emitting the count from the two live loops (wrapping their
  `fetchBatch` calls) with a new `KirokuEvent` constructor
  (`KirokuEventSubscriptionFetched !SubscriptionName !Int !SubscriptionGroupContext`)
  keeps the catch-up path untouched, bounds the new event to live mode, and fits
  the `Observability` module's documented additive-constructor evolution. Under
  Option H the Category test can assert the idle count is exactly `0` (or `<=` the
  number of safety-timer ticks in the window), a stronger and cleaner assertion
  than Option A's "bounded". A flaky wall-clock/CPU fallback is retained for the
  case where the owner prefers zero production change.
  Date: 2026-05-25


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Pending — fix not yet applied. To be filled in at completion with: the final
diffs for `Notification.hs`, `Connection.hs`, `Subscription.hs`, and `Worker.hs`
(new `liveLoopCategoryNotify` + corrected `liveLoopDbDriven`); `cabal test
kiroku-store` result; the regression specs' before/after fetch counts (idle
Category count should be `0` after the fix); and confirmation that the downstream
`rei` worker idles near 0 % CPU after redeploy + re-enable, including under
cross-context flow (the case Option A would only have bounded, not eliminated).
The investigation outcome (root cause + load-test-gap analysis + the
discarded-payload architecture discovery) is recorded above and is the "keep the
history" deliverable this plan was created for.


## Context and Orientation

The subscription worker lives in
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`. `runWorker` runs two
phases (`Worker.hs:81-113`):

1. **Catch-up** (`catchUp`, `Worker.hs:194-218`): reads the saved checkpoint, then
   fetches batches directly from the DB until the cursor reaches the publisher's
   current `lastPublished`. It exits cleanly on an empty fetch or on
   `cursor >= pubPos`, so it is *not* affected by this bug.
2. **Live**, dispatched by `(consumerGroup, target)`:
   - `(Nothing, AllStreams)` → `liveLoop` (`Worker.hs:224-257`): blocks on the
     broadcast `TBQueue`. **Immune.**
   - `(Nothing, Category{})` → `liveLoopDbDriven`. **Buggy.**
   - `(Just _, _)` (any consumer-group member) → `liveLoopDbDriven`. **Buggy.**

`liveLoopDbDriven` (`Worker.hs:268-292`) parameters: `pubPosVar :: TVar
GlobalPosition` is the publisher's global cursor (`EventPublisher.lastPublished`,
`Subscription/EventPublisher.hs:63`, advanced on every append). `posRef :: IORef
GlobalPosition` mirrors the worker's current position for lifecycle events.
`startPos` is the position handed over from catch-up.

`fetchBatch` (`Worker.hs:299-328`) selects the statement by `(consumerGroup,
target)`. For a non-group category it runs `SQL.readCategoryForwardStmt`, whose
SQL filters `WHERE s.category = $2 AND se.stream_version > $1` (the `$all`
junction's `stream_version` is the global position) — i.e. only this category's
events after the cursor. So an empty result means "no events in *my* category
since `cursor`", which says nothing about whether *other* categories advanced
`pubPos`.

`processEvents` (`Worker.hs:333-359`) runs the handler per event, advances
`posRef`, and `saveCheckpoint`s at the batch tail (or at the event where the
handler returned `Stop`). Delivery is at-least-once; the checkpoint is per batch.

`GlobalPosition` is an `Ord` newtype already used by the loop
(`check (pubPos > cursor)`) and constructed as `GlobalPosition 0` in
`loadCheckpoint` (`Worker.hs:188`).

The wake-signal chain (relevant to the chosen Option-H fix):

- The DB trigger `notify_events` fires once per append on the `streams` table and
  `pg_notify`s `'<schema>.events'` with payload
  `stream_name || ',' || stream_id || ',' || stream_version`
  (`2026-05-16-...-kiroku-bootstrap.sql:146-159`). `streams.category` is
  `GENERATED ALWAYS AS (split_part(stream_name,'-',1)) STORED` (schema line 51).
- `Kiroku.Store.Notification.startNotifier` (`Notification.hs:99`) holds a
  dedicated `LISTEN <schema>.events` connection and, in
  `listenerLoop` (`Notification.hs:150-165`), calls
  `waitForNotifications (\_ _ -> atomically (writeTChan chan ()))` — **discarding
  the payload** and writing a bare `()` tick to a broadcast `TChan` (`tickChan`).
  On connection loss it reconnects with capped backoff; notifications during the
  gap are lost (the publisher compensates with a 30 s safety poll).
- `EventPublisher.startPublisher` (`EventPublisher.hs:110`) dups `tickChan`, and on
  each tick reads `$all` and advances `lastPublished` (the global `pubPosVar`),
  fanning out to AllStreams subscriber queues. `safetyPollMicros = 30_000_000`
  (`EventPublisher.hs:94`) is the reconnect-gap safety net.
- The store is assembled in `Connection.hs` `acquire` (`Connection.hs:216-234`):
  `startNotifier` then `startPublisher`, both stored on `KirokuStore`
  (`pool, schema, notifier, publisher, eventHandler, storeSettings`). `subscribe`
  (`Subscription.hs:92-122`) reads `pubPosVar = lastPublished publisher` and passes
  it to `runWorker`.

Option H adds a per-category generation registry (`TVar (Map Text Word64)`) that
the Notifier callback bumps (parsing the payload's `stream_name` → category), and
a new Category live loop that blocks on its category's generation. Nothing above
changes for the publisher or AllStreams path; the Notifier keeps writing the same
`()` tick.

Downstream deployment context (why this mattered enough to file a plan): `rei`
runs each of its 29 bounded contexts as a `Category` subscription on one shared
store via `rei worker kiroku`, supervised by a launchd KeepAlive agent. Constant
cross-context event flow means almost every category is usually behind the global
tail → almost every worker spins → ~6 cores pinned. The 2026-05-25 mitigation
disabled that agent (and its watchdog); they are re-enabled in the final
milestone after the fixed pin ships.


## Plan of Work

Adopt the per-category NOTIFY wake (Option H): stop discarding the Notifier
payload, wake each `Category` subscriber on its own category, and keep the
consumer-group path on a corrected global-position gate. Four milestones, each
ending at a clean `cabal build all`.

### Milestone 1 — Notifier per-category wake signal (+ observability constructor)

Scope: `Kiroku.Store.Observability` and `Kiroku.Store.Notification`. Acceptance:
`cabal build all` clean (nothing consumes the new registry yet — that is M2).

**(a)** In `kiroku-store/src/Kiroku/Store/Observability.hs`, add one additive
constructor to `KirokuEvent` (the module documents additive evolution; consumers
with a `_ ->` fallback are unaffected):

```haskell
    | {- | A live DB-driven subscription loop issued one category/partition
      fetch returning the given row count. Emitted only in live mode (not on
      the catch-up path). Lets operators see per-subscription live-fetch rate
      and lets tests assert an idle category does no work.
      -}
      KirokuEventSubscriptionFetched !SubscriptionName !Int !SubscriptionGroupContext
```

**(b)** In `kiroku-store/src/Kiroku/Store/Notification.hs`, add a per-category
generation registry to `Notifier`, create it inside `startNotifier`, and bump it
from the listener callback while still writing the existing `()` tick. New imports:
`Data.Map.Strict (Map)`, `Data.Map.Strict qualified as Map`, `Data.Word (Word64)`,
`Data.Text (Text)`, `Data.Text.Encoding (decodeUtf8Lenient)`,
`Data.ByteString (ByteString)`, `Data.ByteString.Char8 qualified as BC`, and
`modifyTVar'` from `Control.Concurrent.STM`.

```haskell
data Notifier = Notifier
    { tickChan :: !(TChan ())
    , listenerThread :: !(Async ())
    , listenerConnRef :: !(TVar Connection)
    , categoryGenerations :: !(TVar (Map Text Word64))
    -- ^ Per-category wake counter. The listener callback increments a category's
    -- entry on every NOTIFY for a stream in that category. A `Category`
    -- subscription worker blocks until its category's counter advances, so an
    -- idle category does zero DB work while other categories receive traffic.
    }
```

In `startNotifier`, create the registry alongside the channel and thread it in:

```haskell
    chan <- newBroadcastTChanIO
    catGenVar <- newTVarIO Map.empty
    ...
    thread <- Async.async (listenerLoop chan catGenVar connRef channel connString mHandler)
    pure Notifier { tickChan = chan, listenerThread = thread
                  , listenerConnRef = connRef, categoryGenerations = catGenVar }
```

`listenerLoop` gains the `catGenVar` parameter and its `waitForNotifications`
callback changes from `\_ _ -> atomically (writeTChan chan ())` to a handler that
also bumps the category generation:

```haskell
    go =
        ( do
            currentConn <- readTVarIO connRef
            waitForNotifications (handleNotification chan catGenVar) currentConn
            reconnect 1 (toException ListenerWaitReturned)
        ) `catch` ...   -- unchanged

-- Wake the publisher (bare tick, preserving the existing AllStreams path) AND
-- bump the originating stream's category generation so a Category worker waiting
-- on that category unblocks. Payload is `stream_name,stream_id,stream_version`
-- (notify_events trigger); category = chars of stream_name before the first '-'
-- (matching `streams.category GENERATED ALWAYS AS split_part(stream_name,'-',1)`).
handleNotification :: TChan () -> TVar (Map Text Word64) -> ByteString -> ByteString -> IO ()
handleNotification chan catGenVar _channel payload =
    atomically $ do
        writeTChan chan ()
        modifyTVar' catGenVar (Map.insertWith (+) (categoryFromPayload payload) 1)

-- Recover the category robustly even if a stream name contains commas: drop the
-- trailing stream_id and stream_version fields (integers, comma-free), rejoin to
-- get stream_name, then take chars before the first '-'.
categoryFromPayload :: ByteString -> Text
categoryFromPayload payload =
    let fields = BC.split ',' payload
        streamName = BC.intercalate "," (take (max 0 (length fields - 2)) fields)
     in decodeUtf8Lenient (BC.takeWhile (/= '-') streamName)
```

Note: `Notifier (..)` is already exported, so `categoryGenerations` is reachable
from `subscribe` as `Notifier.categoryGenerations`. `Connection.hs` is untouched.

### Milestone 2 — New Category loop, corrected group loop, and wiring

Scope: `Kiroku.Store.Subscription.Worker` and `Kiroku.Store.Subscription`.
Acceptance: `cabal build all` clean.

**(a) `Worker.hs` imports/header.** Add `import Control.Concurrent.STM
(registerDelay, orElse)` (extend the existing import), `import Data.Map.Strict
(Map)`, `import Data.Map.Strict qualified as Map`, `import Data.Word (Word64)`,
and import the new `KirokuEventSubscriptionFetched`. Define a local safety
constant mirroring the publisher's (`EventPublisher.hs:94`):

```haskell
-- Mirror EventPublisher.safetyPollMicros: an idle category re-checks at most this
-- often, reconciling NOTIFYs lost across a listener reconnect.
categorySafetyPollMicros :: Int
categorySafetyPollMicros = 30_000_000
```

**(b) `runWorker` signature + dispatch.** Add `catGenVar :: TVar (Map Text
Word64)` after `pubPosVar` in `runWorker`'s type and argument list, and re-route
the Category case:

```haskell
                    case (consumerGroup config, target config) of
                        (Nothing, AllStreams) ->
                            liveLoop pool liveQueue statusVar config emit posRef finalPos
                        (Nothing, Category (CategoryName cat)) ->
                            liveLoopCategoryNotify pool config catGenVar cat emit posRef finalPos stSettings
                        (Just _, _) ->
                            liveLoopDbDriven pool config pubPosVar emit posRef finalPos stSettings
```

**(c) New `liveLoopCategoryNotify`.** Drain-first, then block on this category's
generation or the safety timeout:

```haskell
-- Phase 2: live (Category, NOTIFY-driven). Blocks on this category's generation
-- counter, which the Notifier bumps on every NOTIFY for a stream in the category,
-- so an idle category does ZERO DB work while other categories receive traffic.
-- The generation is snapshotted BEFORE an unconditional drain so a notification
-- arriving during the drain is never missed (it leaves gen > gen0 and the loop
-- drains again). A safety timeout (matching the publisher's 30s safety poll)
-- reconciles notifications lost while the listener connection is reconnecting,
-- preserving at-least-once delivery with bounded latency.
liveLoopCategoryNotify ::
    Pool ->
    SubscriptionConfig ->
    TVar (Map Text Word64) ->
    Text -> -- this subscription's category
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    GlobalPosition ->
    StoreSettings ->
    IO ()
liveLoopCategoryNotify pool config catGenVar cat emit posRef startPos stSettings = go startPos
  where
    readGen = Map.findWithDefault 0 cat <$> readTVar catGenVar
    go cursor = do
        writeIORef posRef cursor
        gen0 <- atomically readGen
        drainResult <- drainTo cursor
        case drainResult of
            Nothing -> pure () -- handler said Stop
            Just c -> do
                timer <- registerDelay categorySafetyPollMicros
                atomically $
                    (readGen >>= \g -> check (g > gen0))
                        `orElse` (readTVar timer >>= check)
                go c
      where
        drainTo c = do
            events <- fetchBatch pool config c emit stSettings
            emit (KirokuEventSubscriptionFetched (name config) (V.length events) (groupCtxOf config))
            if V.null events
                then pure (Just c)
                else do
                    result <- processEvents pool config events emit posRef
                    case result of
                        Nothing -> pure Nothing
                        Just newPos -> drainTo newPos
```

**(d) Corrected `liveLoopDbDriven` (now the consumer-group path only).** Replace
the buggy body (`Worker.hs:277-292`) with the global-position gate + drain, and
emit the fetch event:

```haskell
liveLoopDbDriven pool config pubPosVar emit posRef startPos stSettings =
    go startPos (GlobalPosition 0)
  where
    go cursor waitFrom = do
        writeIORef posRef cursor
        -- Block until the publisher advances past the last GLOBAL position we
        -- observed (NOT past `cursor`). A member's partition cursor only moves on
        -- events in its slice, but `pubPosVar` moves on every append; gating on
        -- the cursor busy-loops whenever another partition is ahead. Gating on the
        -- last observed `pubPos` waits for genuinely new global work. (Members
        -- cannot use the per-category signal: their interest is a Postgres hash of
        -- stream_id the worker cannot cheaply replicate.)
        pubPos <- atomically $ do
            p <- readTVar pubPosVar
            check (p > waitFrom)
            pure p
        -- Drain the partition to empty, then re-gate against the observed pubPos.
        -- Draining to empty (not stopping at pubPos) guarantees no lost wakeup.
        let drainTo c = do
                events <- fetchBatch pool config c emit stSettings
                emit (KirokuEventSubscriptionFetched (name config) (V.length events) (groupCtxOf config))
                if V.null events
                    then pure (Just c)
                    else do
                        result <- processEvents pool config events emit posRef
                        case result of
                            Nothing -> pure Nothing -- handler said Stop
                            Just newPos -> drainTo newPos
        drainResult <- drainTo cursor
        case drainResult of
            Nothing -> pure ()
            Just c -> go c pubPos
```

**(e) `Subscription.hs`.** Add `import Kiroku.Store.Notification qualified as
Notifier` and pass the registry to `runWorker`:

```haskell
    let pubPosVar = Pub.lastPublished (store ^. #publisher)
        catGenVar = Notifier.categoryGenerations (store ^. #notifier)
    thread <-
        Async.async
            ( runWorker (store ^. #pool) queue statusVar pubPosVar catGenVar config (store ^. #eventHandler) (store ^. #storeSettings)
                `finally` unsubscribe
            )
```

Notes for the implementer:

- The publisher and the AllStreams `liveLoop` are untouched; the Notifier still
  writes the same `()` tick, so the publisher's behavior is byte-identical.
- `drainTo` in both loops reproduces the pre-fix non-empty branch (same
  `fetchBatch` → `processEvents` → `Stop`/`Continue`), so checkpoint and
  at-least-once semantics are unchanged.
- If `NumericUnderscores` is not enabled in the cabal common stanza, write
  `30000000` for the safety constant.

### Milestone 3 — Regression tests

Scope: a spec proving an idle `Category` subscriber does zero work while another
category is active (plus liveness), and a spec proving the corrected group loop
does not spin on an idle partition. Acceptance: `cabal test kiroku-store` green.

Add `kiroku-store/test/Test/CategoryIdleNoSpin.hs`, `spec :: Spec` (model on
`Test/ConsumerGroup.hs`: `withTestStore $ \store -> …` inline,
`defaultSubscriptionConfig`, and `withTestStoreSettings (\s -> s & #eventHandler
.~ Just h)` to install the observation handler). Wire the module into **both**
`kiroku-store/test/Main.hs` (import + add `CategoryIdleNoSpin.spec` to the tree)
**and** the `other-modules` list of the `kiroku-store-test` stanza in
`kiroku-store/kiroku-store.cabal` (omitting it fails the build).

The fetch counter is `KirokuEventSubscriptionFetched`: the handler `h` increments
a `TVar Int` on each one whose `SubscriptionName` matches the subscriber under
test. Snapshot the counter *after* `waitForSubscriptionLive` (so catch-up fetches
do not count). `pg_stat_statements` is **not** available in this suite and is not
used (see Decision Log).

Spec A — Category idle does zero work:

1. Subscribe `Category (CategoryName "alpha")`; the handler increments a
   delivered-event `TVar Int` and returns `Continue`.
2. Append a burst to a *different* category only (`beta-1`, `beta-2`, …) and
   `waitForPublisher` past those positions, so the global tail advances well past
   `alpha`'s cursor.
3. Assert the `alpha` delivered counter is `0` (no mis-delivery) **and** the
   `alpha` `KirokuEventSubscriptionFetched` count since live is `0` (Option H: an
   idle category does no fetches at all in a sub-30 s window; before the fix this
   grows without bound). If the window is allowed to exceed the safety interval,
   assert `<= 1` instead.
4. Liveness: append one event to `alpha-1`, wait briefly, assert the delivered
   counter reaches `1` — proves the per-category gate still wakes on real work and
   did not over-correct into a worker that blocks forever.

Spec B — consumer-group idle partition does not spin (covers the corrected
`liveLoopDbDriven`): subscribe one member of a size-`n` group, append a sustained
burst to streams that hash to *other* members, and assert this member's
`KirokuEventSubscriptionFetched` count stays bounded (e.g. `< 50`) over the
window — unbounded before the fix. Use `readCategoryForwardConsumerGroupStmt`
(as `Test/ConsumerGroup.hs` does) to choose streams whose partition is/ isn't
this member's.

To prove the specs exercise the fix: temporarily restore the old buggy body (gate
on `cursor`; `go cursor` on empty) and confirm the fetch counts explode, then
restore the fix.

### Milestone 4 — Changelog and downstream re-enable

- Add a `## Unreleased` entry to `kiroku-store/CHANGELOG.md`:

  ```markdown
  ### Fixed — Category/consumer-group live subscriptions busy-spinning (plan 37)

  * Live `Category` subscriptions and consumer-group members no longer busy-spin
    when idle while other categories/partitions advance the global `$all`
    position. `Category` subscriptions now wake from a per-category NOTIFY signal
    (the Notifier previously discarded the notification payload), so an idle
    category does zero DB work; consumer-group members now gate on the last
    observed global position instead of the per-category cursor. Delivery and
    checkpoint semantics are unchanged.

  ### Added

  * `KirokuEventSubscriptionFetched` observability event (per live DB-driven
    fetch), exposing per-subscription live-fetch activity.
  ```

- Downstream (`rei`, not this repo): bump the kiroku pin to the fixed SHA, rebuild
  `rei-cli`, redeploy the `com.shinzui.rei-worker-kiroku` launchd agent, and
  re-enable it plus `com.shinzui.rei-watchdog`
  (`launchctl enable gui/<uid>/<label>` then `launchctl bootstrap gui/<uid>
  ~/Library/LaunchAgents/<label>.plist`). Confirm the worker idles near 0 % CPU
  both with no events flowing **and** under sustained cross-context flow (the case
  Option A would only have bounded), and that `pg_stat_activity` no longer shows a
  continuous stream of identical category `SELECT`s.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

Build after each of Milestones 1 and 2 (the signature change to `runWorker` is
internal to `kiroku-store`; no public API changes):

```bash
cabal build all
```

Expected: a clean build.

Run the store suite (Milestone 3 adds the new specs):

```bash
cabal test kiroku-store
```

Expected tail:

```text
Finished in N.NNNN seconds
NN examples, 0 failures
```

To prove the new specs actually exercise the fix: with the specs in place,
temporarily restore the old buggy `liveLoopDbDriven` body (gate on `cursor`,
`go cursor` on empty) and route `(Nothing, Category{})` back to it; confirm both
specs fail — the idle subscribers' `KirokuEventSubscriptionFetched` counts
explode — then restore the fix.

Run the adjacent suite to confirm no collateral change to subscription behavior
(it drives `liveLoopDbDriven` via consumer groups and `Category` subscriptions):

```bash
cabal test shibuya-kiroku-adapter
```

Expected: `0 failures`.


## Validation and Acceptance

The change is internal (subscription wake conditions + a Notifier signal), so
acceptance is behavior verifiable through the test suite.

Primary acceptance: `cabal test kiroku-store` reports `0 failures` including
`Test.CategoryIdleNoSpin`, whose assertions are:

- An `alpha` `Category` subscriber receives **no** deliveries while only `beta`
  categories are appended (no mis-delivery).
- The `alpha` subscriber's `KirokuEventSubscriptionFetched` count is **zero**
  during that idle window (Option H: an idle category does no fetches at all; it
  is unbounded before the fix). `<= 1` if the window exceeds the safety interval.
- After a real `alpha` append, the `alpha` handler is invoked exactly once
  (liveness: the per-category gate still wakes on category work).
- (Spec B) An idle consumer-group member's fetch count stays bounded while other
  partitions advance the global position (covers the corrected `liveLoopDbDriven`).

Effectiveness beyond compilation: reverting to the cursor-gated body (and routing
Category back through it) makes the zero/bounded-count assertions fail, proving
the specs pin the regression. The liveness assertion fails if the gate waits on
the wrong signal such that the worker never re-queries — guarding both directions.

Regression safety: all existing `kiroku-store` and `shibuya-kiroku-adapter` specs
(including the consumer-group specs that drive `liveLoopDbDriven` and the
`Category` subscription/`subscriptionStream` specs) must still pass, demonstrating
that draining and checkpointing for active categories / partitions are unchanged,
and that the publisher / AllStreams path is unaffected. In particular the existing
"receives live events appended after subscription starts" and consumer-group
delivery specs exercise live delivery through the new and corrected loops.


## Idempotence and Recovery

All edits are ordinary source changes under version control. **No schema change,
no migration, no trigger change, no destructive database operation** — the
category is derived in Haskell from the existing payload, and the store schema and
all read SQL are untouched. If a build or test step fails midway the working tree
is never in a damaging state.

To start over cleanly:

```bash
git checkout -- \
  kiroku-store/src/Kiroku/Store/Observability.hs \
  kiroku-store/src/Kiroku/Store/Notification.hs \
  kiroku-store/src/Kiroku/Store/Subscription.hs \
  kiroku-store/src/Kiroku/Store/Subscription/Worker.hs \
  kiroku-store/test kiroku-store/kiroku-store.cabal kiroku-store/CHANGELOG.md
```

then re-apply the steps. `cabal build all` and `cabal test kiroku-store` are safe
to re-run any number of times; the ephemeral PostgreSQL is created fresh per run.


## Interfaces and Dependencies

No new libraries or services. The fix uses only facilities already on the
dependency list:

- `Control.Concurrent.STM` — `atomically`, `readTVar`, `check` (already imported),
  plus `registerDelay`, `orElse`, `modifyTVar'`, `newTVarIO` for the safety timer
  and the generation registry (all from the existing `stm` dep).
- `Data.Map.Strict` (`containers`, already a dep — used by `EventPublisher` via
  `IntMap`) for the `Map Text Word64` registry.
- `Data.Word` (`Word64`), `Data.Text.Encoding` (`decodeUtf8Lenient`, text ≥ 2.0,
  already the pinned version), `Data.ByteString.Char8` for payload parsing.
- `fetchBatch` / `processEvents` — unchanged; the loops only restructure how they
  are called.

Signature/API changes (all internal to `kiroku-store`; the public `Store` effect
and subscription API are unchanged):

- `Kiroku.Store.Observability.KirokuEvent` gains the additive
  `KirokuEventSubscriptionFetched` constructor (safe per the module's documented
  additive-evolution contract; consumers with a `_ ->` fallback are unaffected).
- `Kiroku.Store.Notification.Notifier` gains a `categoryGenerations` field;
  `startNotifier` is unchanged in signature (it creates the registry internally),
  and `listenerLoop` (internal) gains a parameter. `Connection.hs` is untouched.
- `Kiroku.Store.Subscription.Worker.runWorker` gains a `catGenVar :: TVar (Map
  Text Word64)` parameter; its only caller is `subscribe`
  (`Subscription.hs`), updated in the same milestone. `liveLoop` (AllStreams),
  `catchUp`, the publisher, and the AllStreams path are otherwise untouched.

The Milestone-3 tests depend on the existing scaffolding (`hspec`,
`Test.Helpers.withTestStore` / `withTestStoreSettings` / `waitForPublisher` /
`waitForSubscriptionLive`, the ephemeral PostgreSQL) plus the new
`KirokuEventSubscriptionFetched` event as the deterministic fetch counter. New
spec module(s) must be added to the `kiroku-store-test` stanza's `other-modules`
in `kiroku-store/kiroku-store.cabal` and imported into `Main.hs`.
`pg_stat_statements` is **not** available in the suite and is not used (see
Decision Log).


## Revision Notes

- 2026-05-25 — Plan created to record the root-cause history of the
  `liveLoopDbDriven` busy-spin (found via a downstream `rei` 581 % CPU incident)
  and to specify the fix + regression test. No rei `intention` is linked in the
  frontmatter: rei's kiroku worker was disabled as part of the incident
  mitigation, so no intention was minted; link one when the work is scheduled
  through rei. The owner is applying Milestones 1–3 from the kiroku repo.

- 2026-05-25 — Validation pass (update mode). Traced the Milestone-1 diff against
  the live `Worker.hs` / `EventPublisher.hs` and confirmed it is correct with no
  functional or performance regression (strict fetch-count reduction; reasoning
  added to Decision Log + Surprises, and the in-code comment tightened to state
  the no-lost-wakeup argument). Corrected two Milestone-2/3 accuracy gaps:
  (1) `pg_stat_statements` is not available in the test Postgres, so the
  deterministic fetch-counter was switched to an additive
  `KirokuEventSubscriptionFetched` observability event emitted in
  `liveLoopDbDriven`'s `drainTo` (with a flaky wall-clock fallback retained);
  (2) the new spec module must be registered in `kiroku-store.cabal`'s
  `other-modules`, not just imported into `Main.hs`. Updated Progress, Surprises,
  Decision Log, Milestone 2, and Interfaces & Dependencies accordingly.

- 2026-05-25 — **Architecture change: adopt Option H (per-category NOTIFY wake)
  as the primary fix; retain Option A only for the consumer-group path.** Driven
  by the discovery that the `notify_events` trigger already emits the stream name
  (and `streams.category` is a generated `split_part`), but the Notifier discards
  the payload (`\_ _ -> writeTChan chan ()`), which is the sole reason the live
  Category loop could only gate on the coarse global position. The user chose to
  build the correct architecture now rather than ship the interim gate-fix. The
  design wakes `Category` subscribers from a per-category generation counter that
  the Notifier bumps from the payload (no migration — category derived in
  Haskell), so an idle category does zero DB work even under cross-category load;
  consumer-group members keep the corrected global-position gate (their partition
  is a Postgres hash the worker cannot cheaply replicate). A per-worker safety
  timeout mirrors the publisher's 30 s safety poll to reconcile notifications lost
  across a listener reconnect. This restructured the plan from a one-function
  change into four milestones spanning `Observability.hs`, `Notification.hs`,
  `Worker.hs`, and `Subscription.hs` (publisher, AllStreams path, SQL, and schema
  all untouched). Rewrote Purpose, Progress, Surprises, Decision Log, Context,
  Plan of Work, Concrete Steps, Validation, Idempotence, and Interfaces; the
  retained Option-A analysis now documents the group-path loop.
