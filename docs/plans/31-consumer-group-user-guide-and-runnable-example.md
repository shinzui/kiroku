---
id: 31
slug: consumer-group-user-guide-and-runnable-example
title: "Consumer-Group User Guide and Runnable Example"
kind: exec-plan
created_at: 2026-05-20T03:19:44Z
intention: "intention_01ks1npgpye4xvcczxvzjsq232"
master_plan: "docs/masterplans/4-consumer-group-support-for-partitioned-subscriptions.md"
---

# Consumer-Group User Guide and Runnable Example

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan is complete, a developer learning about consumer groups can read
`docs/user/consumer-groups.md` for a focused, accurate reference — what the feature
does, how to start members, the operational invariants they must uphold, how to resize
the group safely, and the ordering guarantees and hash caveats they need to know in
production. They can also run `cabal run kiroku-store:kiroku-consumer-group-example`
from the repository root to watch a size-4 consumer group partition 120 events across
four threads, with per-member counts, a disjoint check, and a completeness check
printed to the terminal — proving the feature works without touching an external
database.

Before this plan there is no user-facing documentation for consumer groups and no
runnable demonstration. After it, the feature is demonstrably usable and the docs are
traceable to the API that EP-2 (`docs/plans/29-consumer-group-subscription-runtime-and-per-member-workers.md`)
specifies.


## Progress

- [ ] M1: Write `docs/user/consumer-groups.md` (mental model, snippet, invariant, resize, ordering/delivery, hash caveat, effect/Shibuya pointers).
- [ ] M1: Add a "Consumer groups" pointer to `docs/user/subscriptions.md` under a new "See Also" addition.
- [ ] M1: Add `consumer-groups.md` to the Subscriptions section in `docs/user/README.md`.
- [ ] M2: Create `kiroku-store/example/Main.hs` — the runnable EphemeralPg example.
- [ ] M2: Add the `executable kiroku-consumer-group-example` stanza to `kiroku-store/kiroku-store.cabal`.
- [ ] M2: Run `cabal run kiroku-store:kiroku-consumer-group-example` and capture real output; paste transcript into this plan.
- [ ] M2: Verify the guide's excerpt and the example's code are consistent (same snippet, same constants).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Place the user guide at `docs/user/consumer-groups.md`.
  Rationale: All user-facing guides live in `docs/user/`. The filename matches the
  feature name and mirrors the pattern of `subscriptions.md`, `shibuya-adapter.md`,
  `observability.md`. A file in `docs/plans/` would confuse it with the
  implementation design documents.
  Date: 2026-05-20

- Decision: Write the runnable example as a cabal `executable` stanza (not an
  additional test-suite or benchmark), under `kiroku-store/example/Main.hs`.
  Rationale: The goal is something a developer can run on-demand to see the feature
  in action — `cabal run kiroku-store:kiroku-consumer-group-example` is exactly that.
  A test-suite would be in `kiroku-store/test/`, where the EP-2 end-to-end test
  already lives, and the consumer-group example is a demo, not a regression gate. A
  benchmark stanza would mislead readers into thinking it measures performance. The
  existing benchmarks under `kiroku-store/bench/` are a clear precedent for a
  non-library stanza in this cabal file; an `executable` stanza with its own
  `hs-source-dirs: example` follows the same pattern.
  Date: 2026-05-20

- Decision: The example uses `EphemeralPg` so it requires no external database.
  Rationale: `EphemeralPg` is already a `build-depends` entry in the test-suite and
  both benchmark stanzas in `kiroku-store/kiroku-store.cabal`. A self-contained
  example that starts its own PostgreSQL removes the setup barrier entirely — a
  developer checks out the repo and runs one command. Requiring a live `kiroku`
  database would gate the example on `just up` / `just create-database` /
  `just init-schema`, which is three more steps and assumes a local process-compose
  environment.
  Date: 2026-05-20

- Decision: The example doubles as the guide's worked snippet — the guide excerpts
  `kiroku-store/example/Main.hs` directly rather than inventing a separate code block.
  Rationale: Keeping one source of truth prevents the guide from drifting out of sync
  with the code. The guide can show a trimmed excerpt of the relevant section, and the
  example is the runnable proof that the excerpt compiles and produces the claimed output.
  Date: 2026-05-20

- Decision: Document the EP-3 effect API and Shibuya adapter forms as "see EP-3
  deliverables / `docs/user/shibuya-adapter.md`" pointers, rather than inventing
  their API now.
  Rationale: EP-3 (`docs/plans/30-consumer-group-effect-api-and-shibuya-adapter-integration.md`)
  is a soft dependency whose skeleton is not yet filled. Writing binding API text now
  risks diverging from whatever EP-3 specifies. The guide is accurate if it
  documents what EP-2 delivers (the plain `subscribe` API) and clearly marks the
  effectful/Shibuya entry points as "see EP-3".
  Date: 2026-05-20


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section gives a complete newcomer — someone who has only this file and the
repository tree — everything needed to complete the two deliverables.

### What this plan builds

**Deliverable A** is a user guide at `docs/user/consumer-groups.md`. It joins the
existing user docs in `docs/user/` (currently an untracked directory whose files are
listed as `??` in `git status`). The existing guides follow a prose-first style;
compare `docs/user/subscriptions.md` for voice and structure before writing.

**Deliverable B** is a runnable example at `kiroku-store/example/Main.hs`, wired into
the cabal file as an `executable` component. Running it produces a terminal transcript
that proves the partitioning guarantee works end-to-end.

### Hard and soft dependencies

This plan **hard-depends on EP-2**
(`docs/plans/29-consumer-group-subscription-runtime-and-per-member-workers.md`). EP-2
introduces the `ConsumerGroup` type, the `consumerGroup` config field, the validity
check that throws `InvalidConsumerGroup`, and the optional `consumerGroupGuard` field.
None of the code in the example will compile until EP-2 has landed those items in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` and the worker routing in
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`.

This plan **soft-depends on EP-3**
(`docs/plans/30-consumer-group-effect-api-and-shibuya-adapter-integration.md`). EP-3
surfaces consumer groups through the effectful `Subscription` effect and the Shibuya
adapter. The guide documents both entry points; if EP-3 is complete when this plan
executes, document the exact effectful and Shibuya APIs. If EP-3 is not yet complete
(its skeleton is still unfilled at the time of writing), document the plain `subscribe`
/ `withSubscription` API from EP-2 and add a "see EP-3" note for the effectful and
Shibuya forms.

### The public API this plan documents (from IP-4, owned by EP-2)

The following types and fields must exist in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` before the example compiles.
They are reproduced verbatim from MasterPlan IP-4 so this plan is self-contained:

```haskell
-- | Static consumer-group membership for a subscription.
data ConsumerGroup = ConsumerGroup
    { member :: !Int32  -- ^ 0-based member index; must satisfy 0 <= member < size
    , size   :: !Int32  -- ^ total members in the group; must be >= 1
    }
    deriving stock (Eq, Show)
```

Two new fields on `SubscriptionConfigM m` (in addition to the existing `name`,
`target`, `handler`, `batchSize`, `queueCapacity`, `overflowPolicy`):

```haskell
, consumerGroup :: !(Maybe ConsumerGroup)
  -- ^ 'Nothing' = ordinary single-consumer subscription (the default).
  --   'Just cg' = this worker is member 'cg.member' of a group of 'cg.size'.
, consumerGroupGuard :: !Bool
  -- ^ When 'True', perform a startup advisory-lock conflict check so a
  --   duplicate member fails fast. Default: 'False'.
```

`defaultSubscriptionConfig` sets both to their defaults (`Nothing` and `False`), so
existing callers compile without change.

Two exceptions (also in `Kiroku.Store.Subscription.Types`):

```haskell
data InvalidConsumerGroup = InvalidConsumerGroup
    { invalidMember :: !Int32, invalidSize :: !Int32 }
    deriving stock (Show); deriving anyclass (Exception)

data ConsumerGroupGuardConflict = ConsumerGroupGuardConflict
    { conflictName :: !SubscriptionName, conflictMember :: !Int32 }
    deriving stock (Show); deriving anyclass (Exception)
```

### Partition assignment rule (from IP-1, owned by EP-1)

A stream is assigned to a member by hashing its database surrogate id:

```text
member_of(stream_id) = (((hashtextextended(stream_id::text, 0) % size) + size) % size)
```

The double-mod `((h % N) + N) % N` normalizes PostgreSQL's possibly-negative
`hashtextextended` result into `[0, N)`. This is PostgreSQL's native extended hash, the
same family used by declarative `HASH` partitioning. It is evaluated in SQL at query
time; the Haskell code only passes `(member, size)` as parameters. The guide must
mention this formula as the source of the hash caveat.

### How subscriptions work (restated for self-containment)

A subscription is an in-process worker thread started with `subscribe` or
`withSubscription` from `kiroku-store/src/Kiroku/Store/Subscription.hs`. It reads
the checkpoint saved under a stable `SubscriptionName` (in the `subscriptions`
PostgreSQL table), catches up to the publisher's cursor by querying the database in
`batchSize` pages, then switches to live delivery driven by PostgreSQL `NOTIFY`.

Delivery is **at-least-once**: the checkpoint advances per batch, not per event, so
the events at the checkpoint boundary replay if the worker is cancelled or crashes
before the checkpoint save completes. Handlers must be **idempotent**.

When `consumerGroup = Just (ConsumerGroup { member = m, size = n })`, the worker
routes its `fetchBatch` calls through the partitioned SQL statements
(`readCategoryForwardConsumerGroupStmt` for category subscriptions,
`readAllForwardConsumerGroupStmt` for `$all`), and saves its checkpoint under
`(subscriptionName, m)` in the `subscriptions` table. Each member therefore has its
own independent checkpoint; checkpoints from different members of the same group do
not interfere.

### Where the guide lives, and style

All user guides are in `docs/user/`. The files are currently untracked (see
`git status`). The style follows `docs/user/subscriptions.md`: a brief lead paragraph,
then sub-headings with prose and fenced code blocks. Tables are used for config
fields. Language tags on every fence (`haskell`, `bash`, `text`, `sql`). Cross-links
use relative Markdown links (`[Subscriptions](subscriptions.md)`).

### How the cabal stanza is declared

The existing `kiroku-store/kiroku-store.cabal` has four components: a library, a
test-suite (`kiroku-store-test`), and two benchmarks (`kiroku-store-bench`,
`kiroku-shibuya-overhead`, `kiroku-store-bench-explain`). Each benchmark is an
`exitcode-stdio-1.0` component with its own `hs-source-dirs`, `main-is`, and
`build-depends` that include `ephemeral-pg`. The new `executable` follows the same
pattern. The component name is `kiroku-consumer-group-example`; its source dir is
`example/` (a new directory under `kiroku-store/`); its entry point is `Main.hs`.

### EphemeralPg usage pattern

`EphemeralPg` (`EphemeralPg qualified as Pg`) provides `Pg.withCached :: (Pg.Database -> IO a) -> IO (Either Pg.Error a)`. `Pg.connectionString :: Pg.Database -> Text` returns a libpq connection string. The existing helper in `kiroku-store/test/Test/Helpers.hs` shows the pattern:

```haskell
result <- Pg.withCached $ \db -> do
    let settings = defaultConnectionSettings (Pg.connectionString db)
    withStore settings action
case result of
    Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
    Right () -> pure ()
```

The example uses this same pattern in `main`. `withStore` applies the schema and
opens the connection pool automatically.


## Plan of Work

The work is two milestones. Each ends with a verification step that can be completed
independently.

### Milestone M1 — `docs/user/consumer-groups.md` and cross-links

The goal of M1 is a complete, accurate, prose-first user guide plus two small edits
to existing docs that tie it into the navigation. At the end of M1, `git diff
HEAD -- docs/user/` shows the new guide file plus additions to `subscriptions.md`
and `README.md`. No code changes; no new build artifacts.

Create `docs/user/consumer-groups.md`. The guide must cover every topic listed in
the scope section of this plan's preamble. The structure to follow:

An opening paragraph explains what a consumer group is and why a developer would
want one — scale a single subscription horizontally while preserving per-stream
ordering — then states what they can observe after following the guide. This mirrors
the lead-paragraph style of `docs/user/subscriptions.md`.

A **Mental Model** section defines the four terms a reader needs before any code:
*consumer group*, *member*, *member index* (zero-based), and *group size*. It
explains the partition key (the originating stream's database surrogate id, not the
stream name) and the assignment rule — "a stream belongs to exactly one member,
determined by hashing the stream's id modulo the group size" — without repeating the
full SQL formula in the prose (link to the hash caveat section for the details).

A **Starting a Member** section shows a complete, compiling code snippet using
`defaultSubscriptionConfig` and `withSubscription`. The snippet should configure
member 0 of a size-4 group on a `Category` target, and include a brief note on
running all four members: same process (four `subscribe` calls, one per thread) or
four separate processes (one member per process, identical `size`). Show how to pass
a different `member` value per deployment.

```haskell
import Kiroku.Store
import Kiroku.Store.Subscription
import Kiroku.Store.Subscription.Types (ConsumerGroup (..))

-- Run this for m = 0, 1, 2, 3 — one process per member.
runMember :: KirokuStore -> Int32 -> IO ()
runMember store m = do
  let cfg =
        (defaultSubscriptionConfig
          (SubscriptionName "order-projection")
          (Category (CategoryName "order"))
          handler)
          { consumerGroup = Just ConsumerGroup { member = m, size = 4 } }
  withSubscription store cfg $ \h -> do
    result <- wait h
    print result

handler :: RecordedEvent -> IO SubscriptionResult
handler _event = do
  -- ... your projection update ...
  pure Continue
```

An **Operational Invariant** section explains the key safety rule: exactly one live
process must run each member index; all members must use the same `size`. Explain in
plain terms what happens when the invariant is violated: a member index with two live
processes double-processes every event assigned to that slot (both save a checkpoint
under the same `(name, member)` pair, so whichever saves last "wins" and the other
one replays from there on restart). A missing member index means a subset of streams
is never delivered. Then introduce `consumerGroupGuard = True` as the opt-in
advisory-lock guardrail: it performs a startup conflict check and throws
`ConsumerGroupGuardConflict` if another holder is detected at that instant. Note the
documented limitation: this is a startup-time probe, not a lifetime-held lock, so it
catches concurrent double-starts but not staggered ones (see EP-2's Decision Log for
the full rationale). Recommend using the guard in production as a safety net.

A **Resizing the Group** section explains the resize procedure. Changing `size`
re-buckets every stream — a stream assigned to member 1 of a size-4 group may be
assigned to a completely different member in a size-8 group. Therefore, resizing is a
**coordinated operation**: stop all members, let the in-flight work drain to its
checkpoints (wait for each member's `wait` to resolve or `cancel` each one and accept
that the boundary events will replay), then restart all members with the new size.
Mixing old and new `size` values produces gaps (some streams are delivered twice,
others not at all, because the partitioning formula gives different results for the
same stream id at different sizes). The guide should be direct: treat a resize like a
database migration — stop the world, change the value everywhere atomically, restart.

An **Ordering and Delivery Guarantees** section covers: (1) per-stream ordering
within a member — all events for a given stream go to the same member, and that member
processes them in global-position order; (2) at-least-once delivery — same semantics
as an ordinary subscription, with the checkpoint advancing per batch; (3) idempotent
handlers are required for the same reason they are for ordinary subscriptions; (4)
per-member checkpoints — each member's progress is saved under
`(subscription_name, member_index)` in the `subscriptions` table's
`consumer_group_member` column, so member 2 can restart without being confused by
member 0's or member 3's checkpoint.

A **Hash Caveat** section explains that the partition assignment uses
`hashtextextended`, PostgreSQL's native extended hash, which is stable within a single
installation and major version but is **not guaranteed stable across major-version
upgrades or across different-endian platforms**. Because all members re-derive the
assignment at query time on the same cluster, this caveat is normally a non-issue —
the hash is consistent across all members during normal operation. However, after a
PostgreSQL major-version upgrade, the hash values may shift, meaning some streams
would be re-bucketed. The safe procedure is the same as a resize: drain and restart
the whole group together, not mix members running against different PostgreSQL versions.
Also note: the same subscription name can be used safely on two separate clusters
because the hash is cluster-local.

A **Effectful API and Shibuya Adapter** section notes that consumer groups are also
accessible through the effectful `Subscription` effect and the Shibuya adapter. If
EP-3 (`docs/plans/30-consumer-group-effect-api-and-shibuya-adapter-integration.md`)
is complete, link its deliverables and show the relevant API. If EP-3 is not yet
complete, write: "The effectful `Subscription` effect and the Shibuya adapter surface
the same `ConsumerGroup` descriptor through their own entry points; see EP-3
(`docs/plans/30-consumer-group-effect-api-and-shibuya-adapter-integration.md`) and
`docs/user/shibuya-adapter.md` for details once EP-3 lands."

A **See Also** section with relative links to `subscriptions.md`, `shibuya-adapter.md`,
`observability.md`.

Edit `docs/user/subscriptions.md`. At the end of the existing "See Also" section
(which currently has three entries: Shibuya Adapter, Observability, Reading Events),
add a fourth entry:

```markdown
- [Consumer Groups](consumer-groups.md) — horizontal scaling with hash-partitioned members, per-member checkpoints, and the resize procedure.
```

Edit `docs/user/README.md`. In the "Subscriptions" section (which currently lists
`subscriptions.md` and `shibuya-adapter.md`), add:

```markdown
- [Consumer Groups](consumer-groups.md) — scale a single subscription horizontally
  with hash-partitioned members while preserving per-stream ordering.
```

M1 acceptance: the three doc files are consistent and prose-review passes — every
claim in the guide is traceable to the MasterPlan or EP-2 (no invented API). Run
`git diff --stat HEAD -- docs/user/` and confirm the three files changed. No build
steps are needed for pure documentation.

### Milestone M2 — Runnable EphemeralPg example + cabal stanza

The goal of M2 is an executable that a developer can run with one command and observe
the partitioning guarantee. At the end of M2, `cabal run kiroku-store:kiroku-consumer-group-example`
exits 0 and prints a transcript showing four members' event counts, a disjoint check,
and a completeness check.

**Create `kiroku-store/example/`** (a new directory under `kiroku-store/`) and write
`kiroku-store/example/Main.hs`. The example must:

1. Start an ephemeral PostgreSQL using `EphemeralPg.withCached`.
2. Open a `KirokuStore` with `withStore (defaultConnectionSettings connStr) $ \store -> ...`.
3. Append 3 events to each of 40 streams in category `example-cat` (for example, stream names `"example-cat-0"` through `"example-cat-39"`). Total: 120 events.
4. Wait for the publisher to ingest all 120 events using `waitForPublisher` (imported from `Kiroku.Store.Subscription.EventPublisher` — see the pattern in `kiroku-store/test/Test/Helpers.hs`; replicate the STM barrier inline if the test helper is not exported outside the test suite).
5. Start four member workers (member 0 through 3, all size 4, target `Category (CategoryName "example-cat")`). Each worker runs in its own `async` thread and collects the `globalPosition` of every received event into a per-member `IORef [GlobalPosition]`.
6. Stop each member once it has collected all its events. Since we do not know each member's count in advance, use a `Cancel`-based approach: poll until the total across all four members reaches 120, then cancel each handle. Alternatively, each handler can count down from a shared `TVar Int` and return `Stop` when the total reaches 120, but per-member counts make the output more meaningful.
7. After all members are done, compute and print:
   - Each member's event count.
   - Whether the counts sum to 120 (`complete: OK` or `complete: FAIL`).
   - Whether the union of all four members' positions is exactly `[1..120]` with no duplicates (`disjoint: OK` or `disjoint: FAIL`).
   - A representative sample: for member 0, the first 5 global positions it received (in the order it processed them — ascending, because the worker processes in global-position order).

The full source of `kiroku-store/example/Main.hs`:

```haskell
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically, check, readTVar)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Text qualified as T
import EphemeralPg qualified as Pg
import Kiroku.Store
import Kiroku.Store.Subscription
import Kiroku.Store.Subscription.EventPublisher (lastPublished, publisherPosition)
import Kiroku.Store.Subscription.Types (ConsumerGroup (..))

-- | Block until the publisher has ingested at least 'target' events.
waitForPublisher :: KirokuStore -> GlobalPosition -> IO ()
waitForPublisher store (GlobalPosition target) =
    atomically do
        GlobalPosition p <- publisherPosition (store ^. #publisher)
        check (p >= target)

-- | Poll 'act' every 20 ms until it returns True, or 'budget' microseconds elapse.
waitUntil :: Int -> IO Bool -> IO ()
waitUntil budget act
    | budget <= 0 = pure ()
    | otherwise = do
        ok <- act
        if ok
            then pure ()
            else do
                threadDelay 20_000
                waitUntil (budget - 20_000) act

main :: IO ()
main = do
    result <- Pg.withCached \db -> do
        let connStr = Pg.connectionString db
        withStore (defaultConnectionSettings connStr) \store -> do
            -- ── 1. Append 120 events to 40 streams ──────────────────────────
            let streamNames = ["example-cat-" <> T.pack (show i) | i <- [0 .. 39 :: Int]]
            for_ streamNames \sn -> do
                let evs =
                        [ EventData
                            { eventId = Nothing
                            , eventType = EventType "ExampleEvent"
                            , payload = Aeson.object []
                            , metadata = Nothing
                            , causationId = Nothing
                            , correlationId = Nothing
                            }
                        | _ <- [1 .. 3 :: Int]
                        ]
                Right _ <- runStoreIO store $ appendToStream (StreamName sn) AnyVersion evs
                pure ()

            -- ── 2. Wait for the publisher ────────────────────────────────────
            waitForPublisher store (GlobalPosition 120)
            putStrLn "Appended 120 events across 40 streams. Starting 4-member consumer group..."

            -- ── 3. Start one collector per member ───────────────────────────
            let groupSize = 4 :: Int32
            refs <- mapM (\_ -> newIORef ([] :: [GlobalPosition])) [0 .. groupSize - 1]

            handles <- mapM
                (\m -> do
                    let ref = refs !! fromIntegral m
                        h evt = do
                            modifyIORef' ref (evt ^. #globalPosition :)
                            pure Continue
                        cfg =
                            (defaultSubscriptionConfig
                                (SubscriptionName "example-group")
                                (Category (CategoryName "example-cat"))
                                h)
                                { consumerGroup = Just ConsumerGroup{member = m, size = groupSize}
                                })
                    subscribe store cfg)
                [0 .. groupSize - 1]

            -- ── 4. Wait until all 120 events are collected ──────────────────
            waitUntil 30_000_000 do
                counts <- mapM (fmap length . readIORef) refs
                pure (sum counts >= 120)

            for_ handles cancel

            -- ── 5. Compute and print the summary ────────────────────────────
            collected <- mapM readIORef refs
            let memberCounts = map length collected
                totalCollected = sum memberCounts
                allPositions = sort (concat collected)
                expectedPositions = map GlobalPosition [1 .. 120]
                isComplete = totalCollected == 120
                isDisjoint = allPositions == expectedPositions

            putStrLn ""
            putStrLn "=== Consumer Group Partition Summary ==="
            for_ (zip [0 ..] memberCounts) \(m, cnt) ->
                putStrLn ("  member " <> show (m :: Int) <> ": " <> show cnt <> " events")
            putStrLn ("  total : " <> show totalCollected)
            putStrLn ""
            putStrLn ("complete: " <> if isComplete then "OK" else "FAIL (expected 120)")
            putStrLn ("disjoint: " <> if isDisjoint then "OK" else "FAIL (duplicate or missing positions)")
            putStrLn ""
            let sample = take 5 (reverse (collected !! 0))
            putStrLn ("member 0 first 5 positions: " <> show sample)

    case result of
        Left err -> error ("EphemeralPg failed: " <> show err)
        Right () -> pure ()
```

Note: the exact counts per member will vary across runs (they depend on which streams
hash to which member with the PostgreSQL `hashtextextended` function). The disjoint
and complete checks are deterministic; the per-member counts are not, but they should
be roughly balanced across four members over 40 streams.

**Add the cabal stanza.** Edit `kiroku-store/kiroku-store.cabal`. After the last
`benchmark` stanza (`kiroku-store-bench-explain`, which ends around line 182), add:

```text
executable kiroku-consumer-group-example
  import:         common
  type:           exitcode-stdio-1.0
  main-is:        Main.hs
  hs-source-dirs: example
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N
  build-depends:
    , aeson
    , async         >=2.2
    , base          >=4.18 && <5
    , ephemeral-pg  >=0.2
    , generic-lens  >=2.2
    , kiroku-store
    , lens          >=5.2
    , stm
    , text          >=2.0
```

Run `cabal build kiroku-store:kiroku-consumer-group-example` to verify it compiles,
then `cabal run kiroku-store:kiroku-consumer-group-example` to capture the real
output. Paste the transcript into this plan under the Concrete Steps section.

M2 acceptance: the command exits 0 and the printed output contains `complete: OK`,
`disjoint: OK`, and four member lines whose counts sum to 120.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless stated otherwise.

### M1: Create the guide and cross-link

```bash
# Confirm the docs/user directory exists (it is untracked, so it already exists on disk).
ls docs/user/
```

Create `docs/user/consumer-groups.md` as described in the Plan of Work. Then edit
`docs/user/subscriptions.md` and `docs/user/README.md` to add the cross-links.

Verify the files exist:

```bash
git status docs/user/
```

Expected:

```text
?? docs/user/consumer-groups.md
 M docs/user/README.md
 M docs/user/subscriptions.md
```

(The existing files are untracked; `consumer-groups.md` appears as a new untracked
file and the other two as modified.)

### M2: Create the example directory and source file

```bash
mkdir -p kiroku-store/example
```

Create `kiroku-store/example/Main.hs` with the content in the Plan of Work.

Edit `kiroku-store/kiroku-store.cabal` to add the `executable` stanza.

Build:

```bash
cabal build kiroku-store:kiroku-consumer-group-example
```

Expected (abbreviated):

```text
Build profile: -w ghc-9.x.x -O1
Configuring kiroku-consumer-group-example-0.1.0.0...
Building executable 'kiroku-consumer-group-example' for kiroku-store-0.1.0.0..
[1 of 1] Compiling Main ...
Linking .../kiroku-consumer-group-example ...
```

Run and capture the output:

```bash
cabal run kiroku-store:kiroku-consumer-group-example
```

Expected output (exact per-member counts vary; the OK lines do not):

```text
Appended 120 events across 40 streams. Starting 4-member consumer group...

=== Consumer Group Partition Summary ===
  member 0: 28 events
  member 1: 31 events
  member 2: 33 events
  member 3: 28 events
  total : 120

complete: OK
disjoint: OK

member 0 first 5 positions: [GlobalPosition 2,GlobalPosition 5,GlobalPosition 11,GlobalPosition 14,GlobalPosition 17]
```

(Paste the actual transcript here after running. The counts above are illustrative.)

### Run the existing test suite to confirm no regressions

```bash
cabal test kiroku-store
```

or equivalently:

```bash
just test
```

The example is a separate `executable` component and does not affect the test suite.
This step confirms the cabal-file edit did not break the existing components.


## Validation and Acceptance

**Guide accuracy (M1).** For each claim in `docs/user/consumer-groups.md`, identify
the MasterPlan section or EP-2 text that supports it. The checklist:

- Mental model / partition rule → MasterPlan IP-1.
- `ConsumerGroup { member, size }` field names and types → MasterPlan IP-4 / EP-2 M1.
- `consumerGroup :: Maybe ConsumerGroup` on `SubscriptionConfigM` → MasterPlan IP-4.
- `defaultSubscriptionConfig` sets `consumerGroup = Nothing` → MasterPlan IP-4.
- `consumerGroupGuard` and `ConsumerGroupGuardConflict` → EP-2 M4 Decision Log.
- At-least-once delivery, per-batch checkpoint → existing `docs/user/subscriptions.md` (unchanged semantics).
- Per-member checkpoints keyed by `(name, member)` → MasterPlan IP-3.
- Resize procedure (stop, drain, restart) → MasterPlan Vision & Scope "Explicitly out of scope" section.
- `hashtextextended` caveat (stable within installation/major version) → MasterPlan IP-1 ("stable only within an installation/major version" caveat) and Decision Log ("stable only within an installation/version" entry).

No invented API. If the guide says a type or function exists, it must appear in IP-2,
IP-4, or EP-2's Interfaces section.

**Cross-links (M1).** Open `docs/user/subscriptions.md` and confirm "Consumer Groups"
appears at the end of the See Also list. Open `docs/user/README.md` and confirm
"Consumer Groups" appears in the Subscriptions section.

**Example runs (M2).** The acceptance is behavioral:

```bash
cabal run kiroku-store:kiroku-consumer-group-example 2>&1 | grep -E "^(complete|disjoint):"
```

Expected:

```text
complete: OK
disjoint: OK
```

If either prints `FAIL`, the partitioning is broken — the consumer-group runtime
(EP-2) may not be correctly wired. In that case, re-read EP-2's M2 steps for
`fetchBatch` routing and per-member checkpointing.

**Example compiles with cabal (M2):**

```bash
cabal build kiroku-store:kiroku-consumer-group-example
```

exits 0.

**Existing tests still pass (M2):**

```bash
cabal test kiroku-store
```

exits 0. The `executable` stanza does not add any test-suite entries; this confirms
the cabal-file edit is syntactically correct and does not break the library or
test-suite components.


## Idempotence and Recovery

All steps in M1 are file writes and are safe to repeat. Overwriting
`docs/user/consumer-groups.md` with corrected content and re-editing the cross-link
files has no side effects.

M2 file creation is also safe to repeat. `mkdir -p kiroku-store/example` is
idempotent. Rewriting `kiroku-store/example/Main.hs` and re-running `cabal build`
simply recompiles. If the cabal stanza edit produces a parse error (cabal is
whitespace-sensitive — use spaces, not tabs), fix the indentation and run `cabal
build` again.

The example program starts an ephemeral PostgreSQL cluster inside `Pg.withCached` and
tears it down on exit. The cluster is created in a temporary directory managed by
`EphemeralPg`; multiple runs do not accumulate state. If the example crashes partway
through, the temporary directory is cleaned up by the `withCached` bracket.

If `waitUntil` times out (30-second budget) before all 120 events are collected, the
members are cancelled and the summary will show `complete: FAIL` because fewer than
120 events were collected. This most likely means EP-2's worker routing is not yet in
place (the members are delivering zero events because the partition SQL statements do
not exist yet). Confirm EP-2 is complete and the four statements in `Kiroku.Store.SQL`
are exported before re-running the example.


## Interfaces and Dependencies

This plan produces no new Haskell modules and no new SQL. It consumes the following:

- `Kiroku.Store` — re-exports `withStore`, `defaultConnectionSettings`, `KirokuStore`,
  `appendToStream`, `StreamName`, `EventData`, `EventType`, `GlobalPosition`,
  `AnyVersion`, `runStoreIO`.
- `Kiroku.Store.Subscription` — re-exports `subscribe`, `withSubscription`,
  `SubscriptionName`, `Category`, `CategoryName`, `defaultSubscriptionConfig`,
  `RecordedEvent`, `SubscriptionResult (Continue, Stop)`, `SubscriptionHandle`,
  `cancel`, `wait`.
- `Kiroku.Store.Subscription.Types` — `ConsumerGroup (..)` (defined by EP-2 M1).
- `Kiroku.Store.Subscription.EventPublisher` — `publisherPosition`, `lastPublished`
  (used by the `waitForPublisher` helper inline in the example).
- `EphemeralPg` — `withCached`, `connectionString`, `Database`, `Error`.
- `async` — `Async.async`, `Async.cancel`.
- `stm` — `atomically`, `check`, `readTVar`.
- `aeson` — `Aeson.object`.
- `lens`, `generic-lens` — `(^.)`, `#globalPosition`, `#publisher`.

The guide itself uses no code other than the snippet excerpted from the example.

Signatures that must exist before M2 can compile (all provided by EP-2):

```haskell
-- In Kiroku.Store.Subscription.Types:
data ConsumerGroup = ConsumerGroup { member :: !Int32, size :: !Int32 }

-- On SubscriptionConfigM m (fields added by EP-2):
consumerGroup      :: !(Maybe ConsumerGroup)
consumerGroupGuard :: !Bool
```

No other new interfaces are required. The partition SQL (`readCategoryForwardConsumerGroupStmt`,
etc.) is internal to the worker and is not referenced by the example.


## Revision History

- 2026-05-20: Initial authoring of the full ExecPlan body from the empty skeleton.
  All skeleton sections filled. Decisions recorded for guide placement, example as
  `executable` vs test-suite, EphemeralPg usage, and EP-3 soft-dependency handling.
  Full example source, cabal stanza, guide structure, validation checklist, and
  concrete steps written. Reason: convert the placeholder into a self-contained,
  novice-followable plan that a coding agent can follow to deliver both deliverables
  without any prior context beyond this file and the source tree.
