---
id: 55
slug: expose-canonical-category-accessor-and-safe-stream-name-constructor-in-kiroku-store
title: "Expose canonical category accessor and safe stream-name constructor in kiroku-store"
kind: exec-plan
created_at: 2026-06-10T13:58:28Z
intention: "intention_01ktrvackbe7jrenk79j8jgb5e"
---

# Expose canonical category accessor and safe stream-name constructor in kiroku-store

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku defines a stream's **category** as "the substring before the first `-`", and it
*enforces* that rule in the database schema with a generated column:

```text
streams.category GENERATED ALWAYS AS split_part(stream_name,'-',1)
```

(documented at `kiroku-store/src/Kiroku/Store/Notification.hs:231-233`). Category-targeted reads
(`Kiroku.Store.Read.readCategory`) and category subscriptions
(`Kiroku.Store.Subscription.Types`, `Category !CategoryName`) all depend on this rule. Yet the
store exposes **no public Haskell function** to either (a) recover a stream's category from its
name, or (b) construct a stream name guaranteed to land in a given category. The rule is written
down only in the DDL and re-implemented privately once, as a `ByteString` helper, in the
notification hot path:

```haskell
-- Kiroku.Store.Notification.hs:234-238
categoryFromPayload :: ByteString -> Text
categoryFromPayload payload =
    let fields = BC.split ',' payload
        streamName = BC.intercalate "," (take (max 0 (length fields - 2)) fields)
     in decodeUtf8Lenient (BC.takeWhile (/= '-') streamName)
```

The comment there explicitly notes this must match the generated column. So the rule already
lives in **two** places (SQL + this helper) that are kept in sync by hand, and any downstream
consumer that wants the category of a `StreamName` has no choice but to add a **third** copy.
keiro is about to do exactly that (its ExecPlan #66 needs a round-trip law over this rule).

**This plan closes that gap in the place that owns the rule.** After this change,
`Kiroku.Store.Types` exports:

- `categoryName :: StreamName -> CategoryName` — the canonical, pure mirror of
  `split_part(stream_name,'-',1)`, the single source of truth for "what category is this stream
  in".
- `streamNameInCategory :: CategoryName -> Text -> StreamName` — its dual: build a stream name
  for a category and an id segment (`<category>-<id>`), so callers no longer hand-concatenate.

A property test in `kiroku-store` pins the round-trip law (`categoryName (streamNameInCategory
cat seg) == cat` for any dash-free `cat`) and pins agreement with the existing
`categoryFromPayload` hot-path helper, so the SQL column, the notification helper, and the public
accessor can no longer silently drift.

**Observable outcome:** `import Kiroku.Store.Types (categoryName, streamNameInCategory)` resolves;
`categoryName (StreamName "orders-1") == CategoryName "orders"`; and a new test group in
`kiroku-store-test` proves the round-trip and the agreement-with-notification-helper laws. This
is the foundation keiro #66 layers its typed/validating `Category a` API on top of, so the
"category = before first dash" rule has exactly one definition in code.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 — Public accessor + constructor.** (2026-06-10) Added `categoryName :: StreamName ->
  CategoryName` and `streamNameInCategory :: CategoryName -> Text -> StreamName` to
  `Kiroku.Store.Types` (`kiroku-store/src/Kiroku/Store/Types.hs`), both exported. `cabal build
  kiroku-store` clean; repl confirms `categoryName (StreamName "orders-a-b-c") = CategoryName
  "orders"`.
- [x] **M2 — Pin the laws with tests.** (2026-06-10) Added `kiroku-store/test/Test/Category.hs`
  (registered in cabal `other-modules`, wired into `test/Main.hs`): 6 examples incl. round-trip
  and dash-free properties at 100 cases each. `cabal test --match "category rule"` green in
  8 ms (pure, no DB).
- [x] **M3 — De-duplicate the rule.** (2026-06-10) `categoryFromPayload`
  (`kiroku-store/src/Kiroku/Store/Notification.hs`) now derives its category via `categoryName`,
  so the "before first `-`" rule has one Haskell definition. Agreement is now *structural*
  (the notifier calls `categoryName` directly), so no separate exported-internal agreement test
  was needed. Full `cabal test kiroku-store-test` (incl. DB-backed category/consumer-group
  fan-in tests) passes.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The category rule is duplicated by design and synced by comment, not by code.** The DDL
  generated column and `categoryFromPayload` (`Notification.hs:234-238`) implement the same
  `before-first-dash` rule independently; the latter carries a comment instructing future
  editors to keep them aligned. This plan exists precisely because there is no shared
  definition to depend on.

(Add further discoveries here as implementation proceeds.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Home the accessor and constructor in `Kiroku.Store.Types`, alongside `StreamName`
  and `CategoryName`.
  Rationale: both functions are pure and depend only on those two newtypes; `Types` is already
  their definition site and is imported anywhere either type is used. No new module or
  dependency edge.
  Date: 2026-06-10

- Decision: `streamNameInCategory` stays **permissive** — it concatenates `<category>-<id>`
  without rejecting a `CategoryName` that contains `-` or an empty id.
  Rationale: kiroku is deliberately liberal about names (it accepts hyphenless, `$`-prefixed,
  and comma-containing names; only `$all` is reserved for mutations). The *opinionated*,
  rejecting validation belongs one layer up in keiro's `Category` type (ExecPlan #66). kiroku
  provides the mechanical dual of its own parsing and states the law only for the well-formed
  (dash-free category) case.
  Date: 2026-06-10

- Decision: Name the accessor `categoryName` (not `categoryOf`) and the constructor
  `streamNameInCategory`.
  Rationale: `categoryName` reads naturally as "the category name of this stream" and mirrors
  the existing `streamName`-style naming; `streamNameInCategory cat id` reads as a sentence at
  the call site. Confirm no export clash in `Kiroku.Store.Types` (there is none today).
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- **2026-06-10 — Complete.** All three milestones landed. `Kiroku.Store.Types` now exports the
  canonical `categoryName` accessor and its `streamNameInCategory` dual, the round-trip law is
  pinned by `Test.Category`, and the rule that was previously duplicated (DDL generated column +
  private notification helper) now has a single Haskell home that the notifier reuses. The
  full `kiroku-store-test` suite passes, so the M3 refactor of the notification hot path is
  behavior-preserving. This is the foundation keiro ExecPlan #66 delegates to. No schema change,
  no data migration. `kiroku-store` remains at version `0.2.0.0` — keiro #66 must depend on a
  build that includes these symbols (bump the lower bound to `>=0.2.0.0`).
- Decision (recorded here): the M2 "agreement with `categoryFromPayload`" case was satisfied
  *structurally* in M3 (the notifier now calls `categoryName`) rather than by exporting the
  private helper for a redundant test — preserves encapsulation.


## Context and Orientation

This work is in the **`kiroku`** repository at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (PostgreSQL event store, Haskell, GHC
9.12, Nix + Cabal). The package is `kiroku-store`. This plan is the *core* half of a two-repo
effort; the consumer half is keiro ExecPlan #66 ("Add safe stream-construction helpers (Category
API) to Keiro.Stream") at
`/Users/shinzui/Keikaku/bokuno/keiro/docs/plans/66-add-safe-stream-construction-helpers-category-api-to-keiro-stream.md`,
which depends on the API this plan publishes. Both share intention
`intention_01ktrvackbe7jrenk79j8jgb5e`.

Terms, defined plainly:

- **`StreamName`** — `newtype StreamName = StreamName Text`
  (`kiroku-store/src/Kiroku/Store/Types.hs:40`). The textual name of one stream. Names are
  liberal: hyphenless names, `$`-prefixed names, and names containing commas are all accepted;
  only the exact name `$all` is reserved for mutating APIs.
- **`CategoryName`** — `newtype CategoryName = CategoryName Text`
  (`kiroku-store/src/Kiroku/Store/Types.hs:267`). The category prefix of a stream name: "the
  part before the first `-`" (`Types.hs:262-268`). Used by `Kiroku.Store.Read.readCategory`
  (`Read.hs:128-138`) and by the `Category !CategoryName` subscription target
  (`Subscription/Types.hs:143-144`).
- **The category rule** — `category = split_part(stream_name,'-',1)`, enforced by a generated
  column on the `streams` table, and re-derived in Haskell as `takeWhile (/= '-')` in
  `Kiroku.Store.Notification.categoryFromPayload` (`Notification.hs:231-238`). A category never
  contains `-`, so `takeWhile (/= '-')` is exact.

Current state relevant to this plan:

- `Kiroku.Store.Types` exports `StreamName (..)`, `CategoryName (..)`, and others
  (`Types.hs:1-16`), but **no** function relating the two. The module's only imports are
  `Data.Aeson`, `Data.Int`, `Data.Text`, `Data.Time`, `GHC.Generics`, `Data.UUID` — adding pure
  `Text`-level functions needs no new dependency.
- The `kiroku-store-test` suite is declared in `kiroku-store/kiroku-store.cabal:83-88`
  (`test-suite kiroku-store-test`, `main-is: Main.hs`, `hs-source-dirs: test`, with an
  `other-modules:` list). Existing pure/property tests live under `kiroku-store/test/Test/`
  (e.g. `Test/Properties.hs`, `Test/Causation.hs`, `Test/StreamNameLookup.hs`); these run
  without a database. The new category tests are pure and belong there.


## Plan of Work

All paths relative to `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Commands run from
that root inside the project dev shell (the same environment used for plans 1–54).

### Milestone 1 — Public accessor + constructor

Scope: two pure functions added to `Kiroku.Store.Types`, exported. No behavior change to any
existing function.

Edit `kiroku-store/src/Kiroku/Store/Types.hs`:

1. Ensure `Data.Text qualified as Text` is imported (the module already imports `Data.Text
   (Text)`; add the qualified import if not present).

2. Add to the export list (near `StreamName (..)` / `CategoryName (..)`):
   ```haskell
       categoryName,
       streamNameInCategory,
   ```

3. Add the definitions (place just after the `CategoryName` newtype, ~`Types.hs:268`):
   ```haskell
   {- | The category of a stream name: the substring before the first @-@.
   This is the canonical Haskell mirror of the @streams.category GENERATED
   ALWAYS AS split_part(stream_name,'-',1)@ column and of the read/subscription
   category rule. A category never contains @-@, so this is exact.

   >>> categoryName (StreamName "orders-1")
   CategoryName "orders"
   >>> categoryName (StreamName "singleton")   -- no dash: whole name is the category
   CategoryName "singleton"
   -}
   categoryName :: StreamName -> CategoryName
   categoryName (StreamName t) = CategoryName (Text.takeWhile (/= '-') t)

   {- | Build the stream name for a category and an id segment, i.e.
   @<category>-<id>@. The dual of 'categoryName': for any dash-free @cat@,
   @categoryName (streamNameInCategory cat seg) == cat@. Permissive — it does
   not reject a hyphenated category or an empty segment (the store accepts such
   names); opinionated validation is the caller's concern.

   >>> streamNameInCategory (CategoryName "orders") "1"
   StreamName "orders-1"
   -}
   streamNameInCategory :: CategoryName -> Text -> StreamName
   streamNameInCategory (CategoryName cat) seg = StreamName (cat <> "-" <> seg)
   ```

Acceptance: `cabal build kiroku-store` compiles `-Wall` clean.

### Milestone 2 — Pin the laws with tests

Scope: a pure test group that fixes the accessor's behavior and its agreement with the existing
notification helper, so the three copies of the rule (DDL, `categoryFromPayload`, public
accessor) cannot drift.

- Add `kiroku-store/test/Test/Category.hs` exporting a `tests` tree (match the style of an
  existing pure spec such as `Test/Properties.hs` — inspect it for the framework, likely tasty +
  tasty-hunit/-quickcheck, and the `tests :: TestTree` shape). Register the module in
  `kiroku-store.cabal`'s `kiroku-store-test` `other-modules:` list and wire its tree into
  `test/Main.hs`.
- Cases:
  - Unit: `categoryName (StreamName "orders-1") == CategoryName "orders"`.
  - Unit: `categoryName (StreamName "singleton") == CategoryName "singleton"` (no dash).
  - Unit: `streamNameInCategory (CategoryName "orders") "1" == StreamName "orders-1"`.
  - **Round-trip property:** for any generated category text `c` with no `-` and any id segment
    `s` (which *may* contain `-`), `categoryName (streamNameInCategory (CategoryName c) s) ==
    CategoryName c`.
  - **Agreement property:** for any stream name `n`, the public `categoryName (StreamName n)`
    yields the same category text as the notification hot-path rule on that name. (If
    `categoryFromPayload` is not exported, assert against an inline `Text.takeWhile (/= '-')`
    reference and add a comment that M3 unifies them; or export a tiny shared helper — see M3.)

Acceptance: `cabal test kiroku-store-test` passes; the new `Test.Category` group is visible.

### Milestone 3 — De-duplicate the rule (optional, low-risk)

Scope: collapse the rule to one Haskell definition. Refactor
`Kiroku.Store.Notification.categoryFromPayload` so the final category step delegates to the
shared definition rather than its own `BC.takeWhile (/= '-')`. The comma-field stripping stays
(it operates on the raw `ByteString` payload); only the final "category of the recovered stream
name" step routes through `categoryName` (decode the recovered name to `Text`, apply
`categoryName`, unwrap). If the extra decode is unacceptable on the hot path, instead extract the
shared rule as `categoryText :: Text -> Text` used by both `categoryName` and a thin bytestring
wrapper, and have the M2 agreement test assert they coincide. Either way, leave exactly one
authoritative definition of "before first dash" in Haskell.

Acceptance: `cabal test kiroku-store-test` still passes (including the subscription/notification
tests that exercise `categoryFromPayload`, e.g. `Test/CategoryIdleNoSpin.hs`,
`Test/ConsumerGroup.hs`).


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` in the project dev shell.

1. Baseline:
   ```bash
   cabal build kiroku-store
   ```
   Expected: builds at HEAD.

2. **M1** — edit `Types.hs`, then:
   ```bash
   cabal build kiroku-store
   cabal repl kiroku-store
   ```
   ```text
   ghci> categoryName (StreamName "orders-1")
   CategoryName "orders"
   ghci> streamNameInCategory (CategoryName "orders") "1"
   StreamName "orders-1"
   ghci> categoryName (streamNameInCategory (CategoryName "orders") "a-b-c")
   CategoryName "orders"
   ```

3. **M2** — add `Test/Category.hs`, register it, then:
   ```bash
   cabal test kiroku-store-test
   ```
   Expected: all tests pass, new `Test.Category` group listed.

4. **M3 (optional)** — refactor `categoryFromPayload`, then:
   ```bash
   cabal test kiroku-store-test
   ```
   Expected: green, including notification/subscription tests.

5. Commit per milestone with both trailers (see Validation).


## Validation and Acceptance

- **M1 beyond compilation:** the `cabal repl` transcript shows the accessor mirroring the
  generated-column rule (including the no-dash and embedded-dash-in-id cases) and the
  constructor producing `"orders-1"`.
- **M2:** `cabal test kiroku-store-test` green; the round-trip and agreement properties hold
  over generated inputs, pinning the rule against drift.
- **M3:** the same suite stays green after unifying the definition, proving the notification path
  is unchanged behaviorally.

Every commit under this plan carries both trailers:

```text
feat(kiroku-store): expose categoryName accessor and streamNameInCategory constructor

ExecPlan: docs/plans/55-expose-canonical-category-accessor-and-safe-stream-name-constructor-in-kiroku-store.md
Intention: intention_01ktrvackbe7jrenk79j8jgb5e
```


## Idempotence and Recovery

All milestones are additive source/test changes (M3 is a pure refactor with no behavior change).
Re-running `cabal build`/`cabal test` is safe and repeatable; any milestone reverts with a single
`git revert`. No schema migration and no data change — the generated column already exists; this
plan only surfaces its rule in Haskell. There is no runtime risk to existing streams.


## Interfaces and Dependencies

No new package dependency (`Data.Text` is already a dependency of `kiroku-store`).

Public surface that must exist at the end of **M1**, in `kiroku-store/src/Kiroku/Store/Types.hs`
(module `Kiroku.Store.Types`):

```haskell
categoryName         :: StreamName -> CategoryName
streamNameInCategory :: CategoryName -> Text -> StreamName
```

Laws the implementation must uphold (pinned by M2):

- `categoryName (StreamName t) == CategoryName (Text.takeWhile (/= '-') t)` for all `t` — i.e.
  it equals the `split_part(stream_name,'-',1)` generated column and the `categoryFromPayload`
  hot-path rule.
- `categoryName (streamNameInCategory cat seg) == cat` whenever the `CategoryName`'s text
  contains no `-` (the well-formed case), for any `seg` (including `seg` containing `-`).

Downstream consumer: keiro ExecPlan #66 imports `categoryName`/`streamNameInCategory` and builds
its phantom-typed, validating `Category a` / `entityStream` API on top, delegating the actual
name mechanics and the category rule to this module. This plan must land (and `kiroku-store` be
available to keiro at the bumped version) before #66's Milestone 1 can delegate.
