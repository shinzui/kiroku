---
id: 89
slug: expose-a-public-dead-letter-read-api
title: "Expose a public dead-letter read API"
kind: exec-plan
created_at: 2026-09-10T03:18:48Z
intention: "intention_01m24mtzy1embbt15zkh9h3z8c"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-10T03:18:48Z
---

# Expose a public dead-letter read API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan implements the improvement request
[IR-9, Expose a public dead-letter read API](../improvement-requests/expose-a-public-dead-letter-read-api.md),
canonically `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-9`. The request was
filed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`),
which is building a browser UI over the keiro runtime stack and needs an operator's
"something is wrong" screen: which events a subscription parked, why, and when. It is a single
ExecPlan without a MasterPlan. Two sibling plans created in the same week add the other
endpoints that UI needs to `kiroku-metrics`:
[plan 87](87-serve-durable-subscription-checkpoints-over-http.md) (IR-10, durable checkpoints
over HTTP) and
[plan 88](88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md) (IR-8, the
REST browse API). This plan is written so that it can be implemented before, between, or after
those two; the section "Coordinating with plans 87 and 88" in Context and Orientation says
exactly what to reuse from whichever has landed.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store written in Haskell. When a subscription handler asks
to dead-letter an event (by returning `DeadLetter reason`, or by exhausting its retry budget),
the worker records the event in the `kiroku.dead_letters` table with a structured JSON reason
and atomically advances the subscription's checkpoint past it. That table is the most
important "what went wrong" fact a store holds, and today it is unreadable through any
supported API: the only read statement (`readDeadLettersStmt` in
`kiroku-store/src/Kiroku/Store/SQL.hs`) is exercised by tests alone, no `Store` effect
operation exposes it, and no HTTP route serves it. An operator's only option is raw SQL against
a Kiroku-private table, which is exactly what Kiroku's ownership discipline forbids.

After this plan, a Haskell consumer can call one public, mockable `Store` effect operation,
`subscriptionDeadLetters`, and receive a page of a subscription's dead letters, newest first,
with an opaque cursor for the next page and the failure reason as a JSON value. An operator
who has started the store-aware metrics server (the same `withMetricsServerWithStore` call the
user guide already documents) can run:

```bash
curl -s 'http://localhost:9091/subscriptions/inventory-projection/dead-letters?limit=50' | jq .
```

and receive:

```json
{
  "items": [
    {
      "dead_letter_id": 7,
      "subscription": "inventory-projection",
      "member": 0,
      "global_position": 4211,
      "event_id": "0198f2f3-8a9e-7c31-b1d4-2f6f0f4b9d21",
      "reason": { "kind": "poison", "detail": "unknown SKU" },
      "reason_summary": "poison: unknown SKU",
      "attempt_count": 1,
      "created_at": "2026-09-10T02:41:07.512339Z"
    }
  ],
  "next_cursor": "4211:7"
}
```

Paging with `from=4211:7` returns the next, older page; the last page omits `next_cursor`;
a subscription with no dead letters answers HTTP 200 with an empty `items` list; the `reason`
is served as JSON, not as a string. Everything is read-only: no deletion, no redrive, no
retry-policy change, and no change to how dead letters are written or cleaned up.


## Progress

- [ ] M0: set IR-9 to `accepted` with its Status section citing this plan, add the bundle log
      entry, and validate the improvement-request bundle (done at plan creation, see Revision
      Notes).
- [ ] M1: add the public types (`SubscriptionDeadLetter`, `SubscriptionDeadLetterCursor`,
      `SubscriptionDeadLetterLimit` with `mkSubscriptionDeadLetterLimit`,
      `SubscriptionDeadLetterQuery`, `SubscriptionDeadLetterPage`, and the helpers) to
      `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`; set IR-9 to `in_progress`.
- [ ] M1: add the internal module `kiroku-store/src/Kiroku/Store/Subscription/DeadLetter/SQL.hs`
      with the two keyset statements and the paging session; register it under `other-modules`.
- [ ] M1: add the `ListSubscriptionDeadLetters` constructor to the `Store` effect and its
      `runStorePool` branch in `kiroku-store/src/Kiroku/Store/Effect.hs`; add the
      `subscriptionDeadLetters` wrapper with Haddock to `kiroku-store/src/Kiroku/Store/Subscription.hs`.
- [ ] M1: add `kiroku-store/test/Test/SubscriptionDeadLetters.hs` (database),
      `kiroku-store/test/Test/SubscriptionDeadLettersMock.hs` (mock interpreter), the
      `insertDeadLetterWith` helper, and the three structural-gate cases in
      `kiroku-store/test/Test/PerformanceStructure.hs`; register everything; store suite green.
- [ ] M1: `kiroku-store` version and changelog (0.9.0.0, or the existing unreleased heading),
      and the `^>=0.9` bound in every dependant with patch-level entries; `cabal build all`
      warning-free.
- [ ] M2: create `kiroku-metrics/src/Kiroku/Metrics/DeadLetters.hs` (provider type, canonical
      store provider, wire types and hand-written JSON codec, cursor text codec, query-parameter
      parser, `deadLettersApp`); ensure the structured error-envelope helper exists in
      `Kiroku.Metrics.JSON`; export from the umbrella module; database-free tests in
      `kiroku-metrics/test/Test/DeadLettersSpec.hs`.
- [ ] M3: wire the route into `kiroku-metrics/src/Kiroku/Metrics/Server.hs` through the
      providers record (reused or introduced per the coordination rules); store-backed starters
      serve it automatically; end-to-end tests against a real store; every pre-existing spec
      unchanged and green.
- [ ] M4: document the route in `docs/user/metrics.md`, the library operation in
      `docs/user/subscriptions.md`, fix the stale index row in `docs/user/schema.md`, extend
      the self-verifying example, update CAP-12 and CAP-17 and the capabilities log, update the
      IR-9 body with implementation evidence, finalize the `kiroku-metrics` changelog entry;
      all repository validations green.
- [ ] M5: after explicit user confirmation, release the affected packages through the
      repository release skill (preferably as one cohort with plans 87 and 88), verify from a
      clean consumer, set IR-9 to `completed`, perform the ADR distillation pass, and write
      Outcomes & Retrospective.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The public row type, cursor, query, page, and limit types live in
  `Kiroku.Store.Subscription.Types`; the wrapper `subscriptionDeadLetters` lives in
  `Kiroku.Store.Subscription` next to `subscriptionCheckpointInventory`; the SQL lives in a new
  internal module `Kiroku.Store.Subscription.DeadLetter.SQL`. The existing internal
  `readDeadLettersStmt` and `DeadLetterRecord` in `Kiroku.Store.SQL` are left exactly as they
  are.
  Rationale: Dead letters are subscription state, and the checkpoint inventory (plan 69) set the
  pattern: public types beside `SubscriptionCheckpoint`, wrapper in the subscription module,
  statement in an `other-modules` SQL module that decodes straight into the public type.
  `Kiroku.Store.SQL` imports only `Kiroku.Store.Types`, so decoding into a type from
  `Kiroku.Store.Subscription.Types` there would create an import tangle; a dedicated module
  avoids it. Leaving the old statement untouched keeps the existing structural performance gate
  and the retry/dead-letter tests byte-identical, which is what IR-9 acceptance 5 asks for.
  Date: 2026-09-10

- Decision: The documented, deterministic order is newest first by
  `(global_position DESC, dead_letter_id DESC)`, and the cursor is the pair
  `(global_position, dead_letter_id)` of the last row on a page, exclusive.
  Rationale: This is already the store's canonical dead-letter order (migration
  `0005-index-hygiene-and-streams-fillfactor.sql` re-keyed the read index to exactly this
  order and calls it "the store's canonical, deterministic newest first"). Within one
  `(subscription, member)` a global position is unique, but across the members of one
  subscription the same position can appear more than once (for example after a group resize),
  so the surrogate `dead_letter_id` is the tie-break that makes keyset paging exact. A cursor
  that is a pure value never depends on the cursor row still existing, which matters because
  a hard delete of a source stream removes its dead-letter rows. Ordering by `dead_letter_id`
  alone was rejected: it would need a sort for every member-scoped read, discarding the index
  the schema already maintains for this exact order.
  Date: 2026-09-10

- Decision: The consumer-group member filter is optional (`Maybe Int32`). Two prepared
  statements serve the two shapes, one with `consumer_group_member = $2` and one without,
  rather than one statement with a `($2 IS NULL OR consumer_group_member = $2)` predicate.
  Rationale: A UI's first question is "what did this subscription park", across every member;
  a member filter is the drill-down. The member-scoped statement is index-ordered by
  `ix_dead_letters_subscription_position` with no sort, and the structural gate pins that. A
  single `IS NULL OR` statement would let PostgreSQL's generic prepared-statement plan lose the
  member equality from the index condition. The all-members statement uses the same index by its
  `subscription_name` prefix and then a bounded top-N sort, which is acceptable for a table
  whose size is the number of parked events; adding a new index would require a migration and a
  `kiroku-store-migrations` release that IR-9 does not ask for.
  Date: 2026-09-10

- Decision: "No cursor" is passed to SQL as the pair `(maxBound, maxBound)` rather than as a
  nullable parameter.
  Rationale: The row comparison `(global_position, dead_letter_id) < ($n, $m)` is then a single
  index-usable predicate in both statements, and the interpreter already maps the "from the
  newest" cursor `0` to `maxBound` for the backward readers in `Kiroku.Store.Read`, so the idiom
  is familiar in this codebase.
  Date: 2026-09-10

- Decision: The page size is a validated newtype, `SubscriptionDeadLetterLimit`, built by
  `mkSubscriptionDeadLetterLimit :: Int32 -> Either SubscriptionDeadLetterLimitOutOfRange
  SubscriptionDeadLetterLimit` for the range 1 through 1000, with the constructor not exported.
  Rationale: [ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md)
  requires values that can be invalid to be validated at construction with a typed `Either`,
  and `mkHistoryRetentionInventoryLimit` (same range) is the exact precedent. The HTTP layer
  maps a `Left` to HTTP 400 without touching the database, which the structural gate's
  zero-checkout test pins.
  Date: 2026-09-10

- Decision: The library over-fetches one row beyond the limit inside the interpreter's session
  and returns `nextCursor :: Maybe SubscriptionDeadLetterCursor` on the page type, so mock
  interpreters return a complete page and the HTTP layer never computes a cursor.
  Rationale: The cross-project conventions make the absence of `next_cursor` the end-of-data
  signal; over-fetching by one makes that exact without a second round trip. Putting the
  computation in the library means every consumer, not only the HTTP route, gets the same
  answer. Plan 88 made the same choice for its browse pages.
  Date: 2026-09-10

- Decision: The route is `GET /subscriptions/<name>/dead-letters` with query parameters
  `member` (optional), `from` (optional opaque cursor), and `limit` (default 100, maximum
  1000). Any other method on that path answers HTTP 405 with code `method_not_allowed`.
  Rationale: It is the route IR-9 proposes, it reads as "the dead letters of this
  subscription", and plan 87 already verified it does not collide with the reserved
  `/subscriptions/checkpoints` segment (three segments versus two). Refusing non-GET methods
  explicitly matters here more than on other routes: redrive and delete are the obvious things
  a client might POST or DELETE to this path, and IR-9's Boundaries section says those need
  separate safety semantics; a 405 states the read-only boundary on the wire instead of
  answering a mutation attempt with a page.
  Date: 2026-09-10

- Decision: The wire cursor is the text `"<global_position>:<dead_letter_id>"`, for example
  `"4211:7"`, accepted back verbatim as `from`; the parser accepts only two unsigned decimal
  integers that fit in 64 bits separated by one colon.
  Rationale: The conventions require `from` to be a single query parameter the UI echoes and
  never computes, so a composite cursor must be one scalar; a delimited pair is readable in
  logs, cheap to parse, and needs no base64. The item also carries `dead_letter_id`, the row's
  stable identity, because a future redrive or delete API (out of scope here) will have to name
  a dead letter; plan 88 exposes `stream_id` the same way.
  Date: 2026-09-10

- Decision: JSON keys are `items`, `next_cursor`, `dead_letter_id`, `subscription`, `member`,
  `global_position`, `event_id`, `reason`, `reason_summary`, `attempt_count`, and
  `created_at`; `reason` is emitted as the stored JSON value unchanged.
  Rationale: snake_case is required for new fields; `subscription`, `member`, and
  `global_position` are the join keys the live `/subscriptions` rows and plan 87's checkpoint
  rows already use; `created_at` is the schema column name documented in
  `docs/user/schema.md`. Serving `reason` as JSON is IR-9 requirement 3.
  Date: 2026-09-10

- Decision: The server stays store-agnostic. The route reads through a provider closure,
  `type DeadLetterProvider = SubscriptionDeadLetterQuery -> IO (Either StoreError SubscriptionDeadLetterPage)`,
  whose canonical implementation is `storeDeadLetters store = runStoreIO store . subscriptionDeadLetters`.
  The closure becomes one more optional field on the providers record that plans 87 and 88
  introduce; store-backed starters wire it automatically.
  Rationale: Plans 33 and 52 keep `KirokuStore` out of the server's signature and supply
  store-specific behaviour as closures; plans 87 and 88 both add a record of such closures so
  new routes are additive fields. A closure that takes the parsed query lets the HTTP layer be
  tested with a scripted provider and no database, and keeps `StoreError` typed so the route
  can answer 503 with the structured envelope.
  Date: 2026-09-10

- Decision: Unknown subscription names answer HTTP 200 with an empty page, never 404.
  Rationale: Kiroku has no registry of subscription names beyond checkpoint rows and dead
  letters; "no dead letters" is the truthful answer for a name that never parked anything, and
  IR-9 acceptance 2 requires 200 with an empty `items` list. Documented so a UI does not treat
  the empty page as an error.
  Date: 2026-09-10

- Decision: Version bumps: `kiroku-store` 0.8.0.0 to 0.9.0.0 (the exported `Store` effect gains
  a constructor, which breaks exhaustive custom interpreters, following the 0.7.0.0 and 0.8.0.0
  precedents), or a new bullet under an already-present unreleased 0.9.0.0 heading if plan 88
  landed first; `kiroku-cli`, `kiroku-otel`, and `shibuya-kiroku-adapter` patch bumps for the
  `^>=0.9` bound unless already done; `kiroku-metrics` gets a `### New Features` bullet under
  its `## Unreleased` heading, and its own next version (minor if nothing exported changed
  shape, major if plan 87's record replacement is in the same release) is decided at release
  time. Publishing requires explicit user confirmation through the repository release skill.
  Rationale: PVP and the repository's changelog precedent. Releases in this repository require
  the user's explicit release-time confirmation (plan 85 and plan 87 both record this), and the
  three UI-endpoint plans are best released as one cohort so the keiro-ui initiative pins one
  version set.
  Date: 2026-09-10

- Decision: IR-9's `status` moves from `proposed` to `accepted` when this plan is created (its
  Status section links the plan and the bundle log records it), to `in_progress` when
  Milestone 1 starts, and to `completed` with `completedAt` only after release evidence exists.
  Rationale: This is the lifecycle plan 87 established for IR-10 using Mori's closed vocabulary,
  and IR-9 predates its plan, so acceptance is a distinct recordable step.
  Date: 2026-09-10

- Decision: No new ADR is allocated up front.
  [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md),
  recorded for IR-13 while this plan was being written, already fixes the rules this plan's wire
  shape joins on release: published shapes are frozen and grow additively, new keys are
  snake_case, a new surface ships with a test that pins its key set, and a read the library
  lacks is added to `kiroku-store` first and wrapped by the sister package. The distillation
  pass in Milestone 5 decides whether the composite opaque cursor and the explicit read-only 405
  boundary are durable enough to extend ADR-9 (or the ADR plan 88 writes about `Store`-wrapping
  endpoints, if that exists and is the better home), or are task-local.
  Rationale: This plan is one application of ADR-9, not a new architectural decision; recording
  an application as its own record would dilute the corpus.
  Date: 2026-09-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### Terms used in this plan

A **subscription** is a named consumer of Kiroku's event log that receives events in global
position order and persists its progress as a **checkpoint** row keyed by
`(subscription_name, consumer_group_member)`. A **consumer-group member** is one of N workers
sharing one subscription name; an ungrouped subscription is member `0`. The **global position**
is the monotonically increasing sequence number of an event in the store-wide `$all` log. A
**dead letter** is a row in `kiroku.dead_letters` recording that a subscription member gave up
on one event: the handler returned `DeadLetter reason`, or returned `Retry` until the
subscription's `retryPolicy` budget was exhausted. The event itself stays immutable in
`kiroku.events`; the row references it by `event_id` and `global_position`, and the worker
writes the row and advances the member's checkpoint past the event in one atomic statement.

The **`Store` effect** is Kiroku's library API, expressed with the `effectful` library as a
closed GADT of operations in `kiroku-store/src/Kiroku/Store/Effect.hs`; an **interpreter**
gives the constructors meaning (`runStorePool` runs SQL against PostgreSQL; a **mock
interpreter** is any other `interpret_` over the same constructors, used by tests and by
consumers who need no database). **Keyset pagination** means each page's last row yields a
cursor, and the next request asks for rows strictly beyond it in the documented order; unlike
offsets it never skips or repeats rows while the set is unchanged. A **WAI `Application`** is
the standard Haskell value a web server such as Warp runs: a function from a request to a
response. A **provider closure** is an `IO` action the host supplies so the server can fetch
store-backed data without holding the `KirokuStore` itself. **PVP** is the Haskell Package
Versioning Policy: a change to an exported type or signature is a major bump; an addition is a
minor bump.

### The repository and its packages

This repository is a Cabal multi-package project (`cabal.project` at the root; GHC 9.12.4).
The two packages this plan changes are `kiroku-store/` (the core library; modules under
`kiroku-store/src/Kiroku/Store/`; `Kiroku.Store` in `kiroku-store/src/Kiroku/Store.hs` is the
umbrella module that re-exports the public API, including `Kiroku.Store.Subscription` and its
types) and `kiroku-metrics/` (the HTTP sister package; modules under
`kiroku-metrics/src/Kiroku/Metrics/`; `Kiroku.Metrics` re-exports every submodule). Three
other packages depend on `kiroku-store` with the bound `^>=0.8` and must follow its version
bump: `kiroku-cli/kiroku-cli.cabal`, `kiroku-otel/kiroku-otel.cabal`, and
`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`; `kiroku-metrics` also depends on
`kiroku-cli ^>=0.2`. Every package builds with `-Wall -Werror=incomplete-patterns`, so an
exhaustive `Store` interpreter anywhere in the repository that forgets a new constructor fails
to compile rather than crashing at runtime.

Tests use hspec and a real ephemeral PostgreSQL. `kiroku-test-support/src/Kiroku/Test/Postgres.hs`
exports `withSharedMigratedPostgres :: IO a -> IO a` (each suite's `main` wraps `hspec` in it)
and `withMigratedTestDatabase :: (Text -> IO a) -> IO a` (a fresh migrated database and its
connection string per test). `kiroku-store/test/Test/Helpers.hs` adds `withTestStore` and
`withTestStoreSettings` (brackets that open a `KirokuStore` on such a database),
`makeEvent :: Text -> Value -> EventData`, `waitForPublisher`, `waitWithTimeout`, and the
dead-letter seeding helper `insertDeadLetterForEvent :: KirokuStore -> Text -> RecordedEvent -> IO ()`,
which runs `SQL.insertDeadLetterAndCheckpointStmt` with member `0`, reason
`{"source":"test"}`, summary `"test dead letter"`, and attempt count `1`. Store tests are
registered in `kiroku-store/test/Main.hs` and in the `other-modules` list of the
`kiroku-store-test` stanza of `kiroku-store/kiroku-store.cabal`.

### The dead-letter table and how it is written today

The schema is owned by `kiroku-store-migrations/migrations/`. Migration
`0002-add-subscription-dead-letters.sql` creates:

```sql
CREATE TABLE IF NOT EXISTS kiroku.dead_letters (
    dead_letter_id        BIGSERIAL    PRIMARY KEY,
    subscription_name     TEXT         NOT NULL,
    consumer_group_member INT          NOT NULL DEFAULT 0,
    global_position       BIGINT       NOT NULL,
    event_id              UUID         NOT NULL REFERENCES kiroku.events(event_id),
    reason                JSONB        NOT NULL,
    reason_summary        TEXT         NOT NULL,
    attempt_count         INT          NOT NULL,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (subscription_name, consumer_group_member, global_position, event_id)
);
```

Migration `0004-dead-letters-event-id-index.sql` adds `ix_dead_letters_event_id (event_id)`
for the hard-delete cleanup path, and `0005-index-hygiene-and-streams-fillfactor.sql` replaces
the original recency index with

```sql
CREATE INDEX IF NOT EXISTS ix_dead_letters_subscription_position
    ON kiroku.dead_letters
       (subscription_name, consumer_group_member,
        global_position DESC, dead_letter_id DESC);
```

whose comment names `(global_position DESC, dead_letter_id DESC)` the store's canonical
newest-first order. `docs/user/schema.md` documents the table under `## dead_letters` but its
index table still lists the dropped `ix_dead_letters_subscription_created_at`; Milestone 4
fixes that line. Statements in `Kiroku.Store.SQL` use unqualified table names because every
pooled connection sets `search_path` to the Kiroku schema first
([ADR-3](../adr/0003-dedicated-kiroku-schema.md)).

The write path is `writeDeadLetter` in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`
(around line 755), which builds `SQL.DeadLetterParams` with `dlReason = deadLetterReasonJson
reason` and `dlReasonSummary = deadLetterSummary reason` and runs
`SQL.insertDeadLetterAndCheckpointStmt`. The reason vocabulary is `DeadLetterReason` in
`kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`: `DeadLetterPoison Text`,
`DeadLetterInvalid Text`, `DeadLetterMaxAttempts Int`, and `DeadLetterOther Text Value`, with
`deadLetterReasonJson` producing `{"kind":"poison","detail":…}`,
`{"kind":"invalid_payload","detail":…}`, `{"kind":"max_attempts_exceeded","attempts":n}`, or
`{"kind":"other","summary":…,"detail":…}` and `deadLetterSummary` producing the text column
(`"poison: …"`, `"invalid payload: …"`, `"max retry attempts exceeded (n)"`, or the summary).
The read API serves the stored JSON as-is and never re-derives it. The only other touch of the
table is the hard-delete transaction in `runStorePool`, which runs
`SQL.deleteDeadLettersForOrphanedEventsStmt` so a hard-deleted stream leaves no dangling rows.
Neither path changes in this plan.

The existing read statement, in the "Dead-letter Statements" section of
`kiroku-store/src/Kiroku/Store/SQL.hs`, is what IR-9 calls the internal statement:

```haskell
readDeadLettersStmt :: Statement (Text, Int32) (Vector DeadLetterRecord)
-- SELECT global_position, event_id, reason, reason_summary, attempt_count, created_at
-- FROM dead_letters WHERE subscription_name = $1 AND consumer_group_member = $2
-- ORDER BY global_position DESC, dead_letter_id DESC
```

It is unpaginated, member-scoped, and used by `kiroku-store/test/Test/SubscriptionRetryDeadLetter.hs`
and the structural gate. It stays; the new statements live beside the checkpoint-inventory SQL.

### The `Store` effect and the pattern to copy

`data Store :: Effect where …` in `kiroku-store/src/Kiroku/Store/Effect.hs` lists every
operation; the ones this plan sits next to are:

```haskell
    GetSubscriptionCheckpointInventory :: Store m SubscriptionCheckpointInventory
    InitializeSubscriptionCheckpoint ::
        SubscriptionName -> Int32 -> MissingCheckpointPolicy ->
        Store m (Either SubscriptionCheckpointMissing CheckpointInitialization)
```

Their interpreter branches read through `usePool (store ^. #pool) session`, which maps any pool
or SQL error to `ConnectionError`; the inventory branch is
`Session.statement () CheckpointInventorySQL.getSubscriptionCheckpointInventoryStmt` and the
initializer branch calls a session-level function
`CheckpointSQL.initializeSubscriptionCheckpointSession subscriptionName member policy`. Both
SQL modules are `other-modules` of the library (`Kiroku.Store.Subscription.Checkpoint.SQL`
and `Kiroku.Store.Subscription.CheckpointInventory.SQL`); the inventory module decodes rows
straight into the public `SubscriptionCheckpoint` type from `Kiroku.Store.Subscription.Types`.
`runStoreIO :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)`
is the convenience runner, and `runStoreResource` interprets against a `KirokuStoreResource`.

The public wrappers live in `kiroku-store/src/Kiroku/Store/Subscription.hs`, whose export list
has an "Observability" group (`initializeSubscriptionCheckpoint`,
`subscriptionCheckpointInventory`, `subscriptionStates`, `SubscriptionStateView (..)`) and
re-exports `module Kiroku.Store.Subscription.Types`. It imports the constructors it sends by
name: `import Kiroku.Store.Effect (Store (GetSubscriptionCheckpointInventory, InitializeSubscriptionCheckpoint))`.
The wrapper shape is:

```haskell
subscriptionCheckpointInventory ::
    (HasCallStack, Store :> es) =>
    Eff es SubscriptionCheckpointInventory
subscriptionCheckpointInventory = send GetSubscriptionCheckpointInventory
```

The public types in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` that this plan
mirrors are `SubscriptionCheckpoint` (`subscriptionName :: SubscriptionName`,
`consumerGroupMember :: Int32`, `checkpointPosition :: GlobalPosition`,
`checkpointUpdatedAt :: UTCTime`, deriving `Eq, Show, Generic`) and
`SubscriptionCheckpointInventory`. The module enables `DuplicateRecordFields`, and the codebase
reads fields with `generic-lens` labels (`value ^. #field`), so reusing field names such as
`subscriptionName`, `globalPosition`, `eventId`, and `createdAt` is normal. `SubscriptionName`
is a newtype over `Text`; `GlobalPosition` a newtype over `Int64`; `EventId` a newtype over
`UUID` (all in `kiroku-store/src/Kiroku/Store/Types.hs` except `SubscriptionName`).

The validated-limit precedent is in `kiroku-store/src/Kiroku/Store/HistoryRetention/Types.hs`:

```haskell
newtype HistoryRetentionInventoryLimit = HistoryRetentionInventoryLimit Int32
mkHistoryRetentionInventoryLimit :: Int32 -> Either HistoryRetentionInventoryError HistoryRetentionInventoryLimit
mkHistoryRetentionInventoryLimit value
    | value < 1 || value > 1000 = Left (HistoryRetentionInventoryLimitOutOfRange value)
    | otherwise = Right (HistoryRetentionInventoryLimit value)
historyRetentionInventoryLimitValue :: HistoryRetentionInventoryLimit -> Int32
```

The mock-interpreter test precedent is `kiroku-store/test/Test/SubscriptionCheckpointInventoryMock.hs`:
an `interpret_ $ \case GetSubscriptionCheckpointInventory -> …; _ -> error "unexpected Store operation"`
that counts calls in an `IORef` and returns a fixed value, run with `runEff`.

The structural performance gate is `kiroku-store/test/Test/PerformanceStructure.hs`
([ADR-5](../adr/0005-three-tier-performance-regression-gates.md)). Its `noOpAppendSpec`
proves construction-time validation touches no pooled connection (an observation handler counts
checkouts; `mkHistoryRetentionInventoryLimit 0` is asserted `Left` with zero checkouts). Its
`queryPlanSpec` loads a fixture (`withQueryPlanStore`) that inserts 10,000 events and a
dead-letter row for every tenth position under `subscription_name = 'performance-read'`,
member `0`, then runs `explainProductionStatement store stmt [(placeholder, literal)]`, which
substitutes literals into the production SQL and returns the `EXPLAIN (FORMAT JSON)` plan;
`expectIndex "name" plan` and `expectNoNodeType "Sort" plan` are the assertions. The existing
case for `SQL.readDeadLettersStmt` expects `ix_dead_letters_subscription_position` and no
`Sort`.

### The metrics server as it exists

`kiroku-metrics/src/Kiroku/Metrics/Server.hs` builds one WAI `Application`. `combinedApp`
hands WebSocket upgrades to a `WS.ServerApp` and everything else to `httpApp`, which
pattern-matches on `pathInfo req` (the URL path split on `/`, each segment percent-decoded, so
a subscription name containing `/` is written `%2F`). Routes today: `["metrics","prometheus"]`,
`["metrics"]`, `["metrics", name]`, `["subscriptions"]`, `["subscriptions", name]`,
`["health"]`, `["health","live"]`, `["health","ready"]`, `["ws"]`, and a catch-all answering
`404 {"error":"Not found"}`. That string-valued error shape is published and frozen. The
`/subscriptions` routes are served by `subscriptionsApp` from
`kiroku-metrics/src/Kiroku/Metrics/Subscriptions.hs` when a
`SubscriptionStatusProvider = IO [SubscriptionStatusRow]` closure is configured, and answer
`404 {"error":"subscription status not configured"}` otherwise. Starters:
`startMetricsServer cfg m deps` (rejecting WebSocket stub, no provider),
`startMetricsServerWith cfg m deps wsApp`, `startMetricsServerWith' cfg m deps mProvider wsApp`
(the one that binds Warp; port `0` means an OS-assigned port reported in `serverPort`),
`startMetricsServerWithStore cfg m store deps` (real WebSocket app from the store),
`stopMetricsServer`, and the bracketed `withMetricsServer`, `withMetricsServerWithStore`, and
`withMetricsServerSubscriptions`. `kiroku-metrics/src/Kiroku/Metrics/JSON.hs` exports
`jsonResponse :: Status -> LBS.ByteString -> Response` (sets `Content-Type: application/json`).
`kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` exports `recordedEventToJSON`, whose camelCase
keys are published; this plan does not reuse it, because a dead-letter item is not an event.

The test suite is in `kiroku-metrics/test/`: `Main.hs` registers `CollectorSpec`,
`IntegrationSpec`, `ServerSpec`, `WebSocketSpec`, and `SubscriptionsSpec` inside
`withSharedMigratedPostgres`. `Test/SubscriptionsSpec.hs` is the closest precedent: it boots a
store with `withStore (defaultConnectionSettings connStr)`, subscribes, starts a server with
`port = 0`, sleeps 200 ms, and issues raw `http-client` GETs; it also mounts an app standalone
with `Network.Wai.Handler.Warp.testWithApplication (pure app)` for a database-free route test.
Test dependencies already include `aeson`, `hasql`, `hasql-pool`, `http-client`, `http-types`,
`lens`, `generic-lens`, `kiroku-cli`, `kiroku-store`, `kiroku-test-support`, `warp`, `text`,
`containers`, `uuid`, `stm`, `async`, `bytestring`, `scientific`, and `websockets`; they do not
include `time` or `vector` unless plan 87 added them. The self-verifying example is
`kiroku-metrics/example/Main.hs` (cabal flag `example`, off by default; run with
`cabal run -fexample kiroku-metrics-example`); it prints numbered steps `[k/N]` and
`docs/user/metrics.md` quotes its transcript in "Try it".

### Coordinating with plans 87 and 88

Both sibling plans change `Server.hs` and both were skeleton-only when this plan was written.
They differ in one place that this plan must not decide twice: plan 87 introduces a record
`MetricsProviders { subscriptionStatus, checkpointInventory }`, replaces the
`Maybe SubscriptionStatusProvider` argument of `startMetricsServerWith'`, `combinedApp`, and
`httpApp` with it (a major bump), adds `noProviders` and `storeProviders :: KirokuStore ->
MetricsProviders`, and puts an `errorEnvelope :: Text -> Text -> Value` helper in
`Kiroku.Metrics.JSON`. Plan 88 introduces a record `ServerProviders { webSocketServer,
subscriptionStatus, browser }`, keeps every existing signature and adds
`startMetricsServerWithProviders`, `withMetricsServerWithProviders`, `combinedAppWithProviders`,
`httpAppWithProviders`, `defaultServerProviders`, and `storeServerProviders` (a minor bump),
and puts `browseErrorResponse :: Status -> Text -> Text -> Maybe Value -> Response` in
`Kiroku.Metrics.Browse`. Plan 88's Decision Log says whichever plan lands second reuses the
first's record and envelope. This plan follows the same rule, in this order of precedence:

1. If `Server.hs` already exports a providers record (either name), add one field
   `deadLetters :: !(Maybe DeadLetterProvider)` to it, default it to `Nothing` in the
   no-providers value, set it to `Just (storeDeadLetters store)` in the store-backed value
   (`storeProviders` or `storeServerProviders`) and in `startMetricsServerWithStore`, and add
   the route arm to whichever `httpApp` variant holds the router. Do not add a second record.
2. If neither has landed, introduce plan 88's design verbatim (it is the non-breaking one):
   `ServerProviders { webSocketServer :: WS.ServerApp, subscriptionStatus :: Maybe SubscriptionStatusProvider, deadLetters :: Maybe DeadLetterProvider }`,
   `defaultServerProviders`, `storeServerProviders`, and the four `…WithProviders` functions,
   with every existing starter and app function becoming a one-line delegation with its exact
   signature. Record in Surprises & Discoveries that this plan introduced the record, and note
   in plans 87 and 88 (a one-line revision note each) that they must add their fields to it
   instead of creating their own.
3. For the structured error envelope, use the helper the package already has (`errorEnvelope`
   from plan 87 or `browseErrorResponse` from plan 88). If it lacks a `details` argument, add a
   details-carrying variant beside it rather than changing its type. If neither exists, add to
   `Kiroku.Metrics.JSON` and export:

   ```haskell
   -- | Structured error body for endpoints added under the cross-project inspection
   -- conventions: @{"error":{"code":…,"message":…,"details":…}}@ with @details@ omitted
   -- when Nothing. Existing endpoints keep their published @{"error":"<string>"}@ bodies.
   errorEnvelope :: Text -> Text -> Maybe Value -> Value
   errorResponse :: Status -> Text -> Text -> Maybe Value -> Response
   ```

4. `kiroku-store` carries exactly one unreleased `0.9.0.0` changelog heading: add this plan's
   bullets under it if plan 88 created it, otherwise create it. The `^>=0.9` bound edits in the
   dependants are done once, by whichever plan gets there first.
5. The example's step numbering, the `docs/user/metrics.md` Contents list, and the router's
   route ordering are shared: append this plan's step and section after whatever exists, and
   place the `["subscriptions", _, "dead-letters"]` arm together with the other
   `/subscriptions` arms.

Run `git log --oneline -- kiroku-metrics/src/Kiroku/Metrics/Server.hs kiroku-store/CHANGELOG.md`
and read `Server.hs` before starting Milestone 3 to learn which case applies, and record the
answer in Surprises & Discoveries.

### Documentation and knowledge bundles touched

`docs/user/metrics.md` is the package user guide (Contents: "Wiring the collector", "Starting
the server", "HTTP endpoints", "Wire-format stability", "Prometheus metric reference",
"Interpreting the metrics", "The WebSocket protocol", "Subscription status over HTTP", "Try
it", "See Also"; a deployment call-out near the top names the surfaces that have no
authentication, and the "Wire-format stability" section cites ADR-9 as the contract every
documented shape falls under, which is where this plan's route is described as published once
it ships). `docs/user/subscriptions.md`
has a "Per-Event Retry And Dead-Letter" section that explains the dispositions and links to
`schema.md#dead_letters`; it gets the read API. `docs/user/schema.md` documents the table and
indexes. `docs/user/README.md` indexes the guides.

`docs/capabilities/` is a profile-governed OKF bundle validated by `just capabilities-validate`.
`docs/capabilities/resilient-delivery.md` is CAP-12 (retry, dead-letter, filtering; package
`kiroku-store`) and `docs/capabilities/operational-http-endpoints.md` is CAP-17 (the
`kiroku-metrics` surface). Earlier updates changed `description`, `interface`, `evidence`, and
body text and added a dated `**Update**` entry to `docs/capabilities/log.md` without altering
`generated.at`, `since`, or `capabilityId`.

`docs/improvement-requests/expose-a-public-dead-letter-read-api.md` is IR-9 in the
`improvement-requests` OKF bundle governed by `mori/improvement-requests-profile.dhall`. Status
changes must advance `timestamp`, add a dated entry to `docs/improvement-requests/log.md`, and
pass the strict validation command in Concrete Steps (the validator currently prints
"missing profile-recommended field: reviews" warnings for some requests; those are advisory and
pre-existing).

`agents/skills/release/SKILL.md` is the release procedure (independent per-package PVP
versions, tags named `<package>-v<version>`, publish order `kiroku-store`,
`kiroku-store-migrations`, `kiroku-otel`, `kiroku-cli`, `kiroku-metrics`,
`shibuya-kiroku-adapter`). The latest tags at planning time are `kiroku-store-v0.8.0.0` and
`kiroku-metrics-v0.1.0.8`.

### The wire conventions this plan follows

The keiro-ui initiative's shared conventions are in `mori://shinzui/keiro-ui`, file
`docs/architecture/inspection-api-conventions.md` (artifact-level URI pending; on this machine
`/Users/shinzui/Keikaku/bokuno/keiro-ui/docs/architecture/inspection-api-conventions.md`). The
rules restated here so the plan is self-contained: new surfaces are HTTP plus JSON served by an
embeddable WAI `Application` in a sister package; all new fields are `snake_case`; published
shapes are frozen and grow only additively; position-based reads use cursor pagination with an
exclusive `from` and a `limit` in, `items` and `next_cursor` out, `next_cursor` omitted on the
last page, cursors opaque to clients (echoed, never computed); new endpoints return errors as
`{"error":{"code":"<snake_case>","message":"<sentence>","details":{…}}}` with `details`
optional and codes per project; mutating actions such as dead-letter redrive must be separately
gated and follow the owning project's safety discipline (this plan adds none); the servers have
no authentication and assume a trusted network or an authenticating proxy, which the
documentation must restate.

### Relevant architecture decisions

Local ADRs read for this plan (the others were scanned by heading and are not relevant):

- [ADR-3](../adr/0003-dedicated-kiroku-schema.md): all Kiroku objects live in the `kiroku`
  schema and statements use unqualified names resolved through the connection `search_path`;
  the new SQL follows suit.
- [ADR-5](../adr/0005-three-tier-performance-regression-gates.md): deterministic structural
  checks are an authoritative performance gate; the new statements get plan-shape cases and the
  new smart constructor gets a zero-checkout case. The statements are off every hot path.
- [ADR-6](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md):
  consumers must not depend on private tables; a published surface is frozen and grows only
  additively. This plan is the Haskell-and-HTTP answer to reading `kiroku.dead_letters` without
  touching it, and its wire shape is treated as frozen once released.
- [ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md):
  values that can be invalid are validated at construction with a smart constructor returning a
  typed `Either`; the page-size limit follows it. ADR-8 also records that dead-lettering is
  always the consumer's decision, which is why this plan is read-only.
- [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md): dead letters are recorded
  per member, which is why the row carries `member` and the query can filter on it.
- [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md):
  a wire shape becomes a published contract once it ships in a Hackage release and is documented
  in `docs/user/metrics.md`; published fields are never removed, renamed, or re-typed; additions
  are new optional fields, routes, or frame types; new keys are snake_case; a new surface ships
  with a test that pins its key set; `kiroku-store` owns no wire format and gains no web
  dependency; a sister package wraps supported public APIs only and issues no SQL against
  Kiroku-owned tables, so a read the library lacks is added to `kiroku-store` first. This is
  why Milestone 1 adds the library operation before Milestone 2 adds the route, why the
  Milestone 2 codec test pins the exact key set, and why the route's shape is treated as frozen
  from its first release.

Cross-repository decisions, by the canonical handles the keiro-ui bundle publishes (verified
with `mori registry concepts`; `mori path` may lag fresh commits, and the canonical URIs are
retained regardless): `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1` (inspection endpoints
live in the project that owns the concept; store dead letters are Kiroku's),
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4` (inspection surfaces live in sister packages;
`kiroku-store` gains no web dependency), and `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7`
(read-only first, with owning-repository gates for anything mutating).

Related requests, all out of scope here: IR-10 (plan 87), IR-8 (plan 88), IR-11 (CORS, being
planned as `docs/plans/90-add-configurable-cors-support-to-kiroku-metrics.md`, which was a
skeleton at the time of writing; CORS is middleware around the whole application and changes
neither this route's path nor its body, but it may touch `MetricsServerConfig` and `Server.hs`,
so re-read both before Milestone 3), and IR-12 (WebSocket convergence). IR-13 is complete:
ADR-9 records the stability contract this plan's route joins on release. MasterPlan 12
(`docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md`)
changes how dead-letter checkpoint saves write the `subscriptions` table (plans 81 and 82) but
adds no column to `dead_letters`; the new statements name their columns explicitly, so an
additive column there would not affect them either.


## Plan of Work

### Milestone 1: the public library operation in `kiroku-store`

Scope: after this milestone a Haskell consumer can call `subscriptionDeadLetters` through the
public `Store` effect, the PostgreSQL interpreter serves it with keyset pagination in the
canonical order, a mock interpreter can implement it without a database, the structural gate
pins the query plans, and the store package and its dependants carry the version bump. Nothing
in `kiroku-metrics` changes yet.

First move IR-9 from `accepted` to `in_progress`: in
`docs/improvement-requests/expose-a-public-dead-letter-read-api.md` set `status: in_progress`,
advance `timestamp` to the current UTC time, and under `## Status` change the acceptance
paragraph (which already links this plan) to say implementation is under way. Add a dated
`**Implementation**` entry to `docs/improvement-requests/log.md` and run the strict bundle
validation from Concrete Steps.

**Types** (`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`). Add a `-- * Dead letters`
group to the export list and define, after `SubscriptionCheckpointInventory`:

```haskell
{- | One parked dead letter, as durably recorded in @kiroku.dead_letters@ by a
subscription member that gave up on an event. 'reason' is the structured JSON the
worker wrote ('Kiroku.Store.Subscription.Types.deadLetterReasonJson'), served
unchanged; 'reasonSummary' is its one-line operator text; 'attemptCount' is the
number of deliveries made before the event was parked; 'createdAt' is when the row
was recorded. 'deadLetterId' is the row's stable identity.
-}
data SubscriptionDeadLetter = SubscriptionDeadLetter
    { deadLetterId :: !Int64
    , subscriptionName :: !SubscriptionName
    , consumerGroupMember :: !Int32
    , globalPosition :: !GlobalPosition
    , eventId :: !EventId
    , reason :: !Value
    , reasonSummary :: !Text
    , attemptCount :: !Int32
    , createdAt :: !UTCTime
    }
    deriving stock (Eq, Show, Generic)

{- | An exclusive keyset cursor into the newest-first dead-letter order
@(globalPosition DESC, deadLetterId DESC)@. Obtain one from a page's 'nextCursor'
or from 'subscriptionDeadLetterCursor'; the next page starts strictly after it.
Cursors are values: they stay valid even if the row they were taken from is
later removed by a hard delete.
-}
data SubscriptionDeadLetterCursor = SubscriptionDeadLetterCursor
    { cursorGlobalPosition :: !GlobalPosition
    , cursorDeadLetterId :: !Int64
    }
    deriving stock (Eq, Ord, Show, Generic)

subscriptionDeadLetterCursor :: SubscriptionDeadLetter -> SubscriptionDeadLetterCursor
subscriptionDeadLetterCursor row =
    SubscriptionDeadLetterCursor (row ^. #globalPosition) (row ^. #deadLetterId)

-- | Validated page size (1 through 1,000). Constructor not exported.
newtype SubscriptionDeadLetterLimit = SubscriptionDeadLetterLimit Int32
    deriving stock (Eq, Ord, Show, Generic)

newtype SubscriptionDeadLetterLimitOutOfRange = SubscriptionDeadLetterLimitOutOfRange Int32
    deriving stock (Eq, Show, Generic)

mkSubscriptionDeadLetterLimit :: Int32 -> Either SubscriptionDeadLetterLimitOutOfRange SubscriptionDeadLetterLimit
mkSubscriptionDeadLetterLimit value
    | value < 1 || value > 1000 = Left (SubscriptionDeadLetterLimitOutOfRange value)
    | otherwise = Right (SubscriptionDeadLetterLimit value)

subscriptionDeadLetterLimitValue :: SubscriptionDeadLetterLimit -> Int32

-- | 100 rows.
defaultSubscriptionDeadLetterLimit :: SubscriptionDeadLetterLimit

{- | What to read. 'consumerGroupMember' 'Nothing' reads every member's rows;
'after' 'Nothing' starts from the newest row.
-}
data SubscriptionDeadLetterQuery = SubscriptionDeadLetterQuery
    { subscriptionName :: !SubscriptionName
    , consumerGroupMember :: !(Maybe Int32)
    , after :: !(Maybe SubscriptionDeadLetterCursor)
    , limit :: !SubscriptionDeadLetterLimit
    }
    deriving stock (Eq, Show, Generic)

-- | Every member, from the newest row, 'defaultSubscriptionDeadLetterLimit' rows.
defaultSubscriptionDeadLetterQuery :: SubscriptionName -> SubscriptionDeadLetterQuery

{- | One page. 'nextCursor' is 'Just' exactly when more rows exist beyond this
page in the documented order; pass it back as 'after' to continue.
-}
data SubscriptionDeadLetterPage = SubscriptionDeadLetterPage
    { deadLetters :: !(Vector SubscriptionDeadLetter)
    , nextCursor :: !(Maybe SubscriptionDeadLetterCursor)
    }
    deriving stock (Eq, Show, Generic)
```

`Data.Aeson (Value)`, `Data.Int (Int64)`, and `Kiroku.Store.Types (EventId)` need importing;
`Control.Lens ((^.))` and `Data.Generics.Labels ()` are needed for the label access (or write
the cursor helper by pattern matching, which avoids the imports). Export the limit newtype
without its constructor (`SubscriptionDeadLetterLimit,` not `SubscriptionDeadLetterLimit (..)`).

**SQL** (new file `kiroku-store/src/Kiroku/Store/Subscription/DeadLetter/SQL.hs`, listed under
`other-modules` in `kiroku-store/kiroku-store.cabal` next to the checkpoint SQL modules). The
module exports one session-level function and the two statements it chooses between:

```haskell
{-# LANGUAGE MultilineStrings #-}

module Kiroku.Store.Subscription.DeadLetter.SQL (
    listSubscriptionDeadLettersSession,
    listSubscriptionDeadLettersStmt,
    listSubscriptionMemberDeadLettersStmt,
) where

-- | Newest first across every member. Params: (name, cursor position, cursor id, rows to fetch).
listSubscriptionDeadLettersStmt :: Statement (Text, Int64, Int64, Int32) (Vector SubscriptionDeadLetter)
listSubscriptionDeadLettersStmt =
    preparable
        """
        SELECT dead_letter_id, subscription_name, consumer_group_member, global_position,
               event_id, reason, reason_summary, attempt_count, created_at
        FROM dead_letters
        WHERE subscription_name = $1
          AND (global_position, dead_letter_id) < ($2, $3)
        ORDER BY global_position DESC, dead_letter_id DESC
        LIMIT $4
        """
        ( contrazip4
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.int4))
        )
        (D.rowVector deadLetterRow)

-- | Newest first for one member. Params: (name, member, cursor position, cursor id, rows to fetch).
listSubscriptionMemberDeadLettersStmt :: Statement (Text, Int32, Int64, Int64, Int32) (Vector SubscriptionDeadLetter)
listSubscriptionMemberDeadLettersStmt =
    preparable
        """
        SELECT dead_letter_id, subscription_name, consumer_group_member, global_position,
               event_id, reason, reason_summary, attempt_count, created_at
        FROM dead_letters
        WHERE subscription_name = $1
          AND consumer_group_member = $2
          AND (global_position, dead_letter_id) < ($3, $4)
        ORDER BY global_position DESC, dead_letter_id DESC
        LIMIT $5
        """
        (contrazip5 … the same encoders with an int4 for the member …)
        (D.rowVector deadLetterRow)

deadLetterRow :: D.Row SubscriptionDeadLetter
deadLetterRow =
    SubscriptionDeadLetter
        <$> D.column (D.nonNullable D.int8)
        <*> (SubscriptionName <$> D.column (D.nonNullable D.text))
        <*> D.column (D.nonNullable D.int4)
        <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
        <*> (EventId <$> D.column (D.nonNullable D.uuid))
        <*> D.column (D.nonNullable D.jsonb)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.int4)
        <*> D.column (D.nonNullable D.timestamptz)

-- | Fetch one row beyond the limit, trim, and derive 'nextCursor'.
listSubscriptionDeadLettersSession :: SubscriptionDeadLetterQuery -> Session SubscriptionDeadLetterPage
listSubscriptionDeadLettersSession query = do
    let SubscriptionName name = query ^. #subscriptionName
        pageSize = subscriptionDeadLetterLimitValue (query ^. #limit)
        fetch = pageSize + 1
        (cursorPosition, cursorId) = case query ^. #after of
            Nothing -> (maxBound, maxBound)
            Just cursor ->
                let GlobalPosition position = cursor ^. #cursorGlobalPosition
                 in (position, cursor ^. #cursorDeadLetterId)
    rows <- case query ^. #consumerGroupMember of
        Nothing -> Session.statement (name, cursorPosition, cursorId, fetch) listSubscriptionDeadLettersStmt
        Just member -> Session.statement (name, member, cursorPosition, cursorId, fetch) listSubscriptionMemberDeadLettersStmt
    pure (paginate pageSize rows)

paginate :: Int32 -> Vector SubscriptionDeadLetter -> SubscriptionDeadLetterPage
paginate pageSize rows
    | V.length rows > fromIntegral pageSize =
        let page = V.take (fromIntegral pageSize) rows
         in SubscriptionDeadLetterPage page (Just (subscriptionDeadLetterCursor (V.last page)))
    | otherwise = SubscriptionDeadLetterPage rows Nothing
```

`contrazip4` and `contrazip5` come from `Contravariant.Extras` (package
`contravariant-extras`, already a dependency; this repository's encoder style is the
`contrazip<N>` form). The row comparison `(global_position, dead_letter_id) < ($2, $3)` is
PostgreSQL row-wise comparison; because both columns are consecutive `DESC` columns of
`ix_dead_letters_subscription_position`, the planner can use it as an index condition and walk
the index in its own order, which is what the structural gate checks. `maxBound :: Int64`
makes the predicate true for every row when there is no cursor. `D.jsonb` decodes the column to
an aeson `Value` unchanged.

**Effect** (`kiroku-store/src/Kiroku/Store/Effect.hs`). Import the new types from
`Kiroku.Store.Subscription.Types` and `Kiroku.Store.Subscription.DeadLetter.SQL qualified as DeadLetterSQL`.
Add the constructor immediately after `GetSubscriptionCheckpointInventory`:

```haskell
    {- | Page the dead letters recorded for one subscription, newest first by
    @(global position, dead-letter id)@, optionally for one consumer-group
    member, from an exclusive cursor. The page carries the cursor for the next
    page when more rows exist. Read-only; the write and cleanup paths of
    @kiroku.dead_letters@ are unchanged by this operation.

    Surfaced as 'Kiroku.Store.Subscription.subscriptionDeadLetters'.
    -}
    ListSubscriptionDeadLetters :: SubscriptionDeadLetterQuery -> Store m SubscriptionDeadLetterPage
```

and the interpreter branch after the inventory branch:

```haskell
    ListSubscriptionDeadLetters query ->
        usePool (store ^. #pool) (DeadLetterSQL.listSubscriptionDeadLettersSession query)
```

No `decodeEvents` hook applies: the row is not a `RecordedEvent`.

**Wrapper** (`kiroku-store/src/Kiroku/Store/Subscription.hs`). Add
`ListSubscriptionDeadLetters` to the explicit `Store (…)` import, add
`subscriptionDeadLetters` to the "Observability" export group, and define it next to
`subscriptionCheckpointInventory` with Haddock that states, in plain words: the order is newest
first by global position then dead-letter id and is the same order the write index maintains;
`after` is exclusive and comes from a previous page's `nextCursor`; `consumerGroupMember`
`Nothing` means every member and `Just n` one member (an ungrouped subscription is member 0);
an empty page for a name means no dead letters were recorded, not that the subscription is
unknown; `reason` is the JSON the worker wrote, served unchanged; `nextCursor` is `Just` only
when more rows exist; the read is one statement and one round trip; a hard delete of a source
stream removes that stream's rows, and a cursor taken before it stays valid; the operation is
read-only and consumers must not read the table directly.

```haskell
subscriptionDeadLetters ::
    (HasCallStack, Store :> es) =>
    SubscriptionDeadLetterQuery ->
    Eff es SubscriptionDeadLetterPage
subscriptionDeadLetters = send . ListSubscriptionDeadLetters
```

Because `Kiroku.Store` re-exports `Kiroku.Store.Subscription` (which re-exports its `Types`),
everything above is reachable with `import Kiroku.Store`.

**Test helper** (`kiroku-store/test/Test/Helpers.hs`). Generalize the seeding helper without
changing existing callers: add and export
`insertDeadLetterWith :: KirokuStore -> Text -> Int32 -> Value -> Text -> Int32 -> RecordedEvent -> IO ()`
(subscription name, member, reason, summary, attempt count, event), and make
`insertDeadLetterForEvent store name event = insertDeadLetterWith store name 0 (object [("source", String "test")]) "test dead letter" 1 event`.

**Database tests** (new file `kiroku-store/test/Test/SubscriptionDeadLetters.hs`,
`spec :: Spec`, `describe "SubscriptionDeadLetters"`). Each case uses `withTestStore`, appends
single-event streams with `appendToStream` and `makeEvent` so global positions are 1, 2, 3, …,
reads them back with `readAllForward (GlobalPosition 0) n` to obtain `RecordedEvent`s, and
seeds rows with the helpers. A local `readPage store query` runs
`runStoreIO store (subscriptionDeadLetters query)` and fails the test on `Left`. Cases:

- an empty store returns an empty page with `nextCursor = Nothing` for any name;
- the resource-backed interpreter path works: `runEff . runErrorNoCallStack @StoreError .
  runKirokuStoreWith store . runStoreResource $ subscriptionDeadLetters (defaultSubscriptionDeadLetterQuery name)`
  returns `Right` an empty page (mirrors the inventory test);
- keyset paging never skips or repeats: seed positions 1 through 5 for `"dl-page"` and
  positions 6 and 7 for `"dl-other"`; with limit 2, the first page holds positions `[5, 4]`
  and a `Just` cursor; the second (from that cursor) `[3, 2]` and a `Just` cursor; the third
  `[1]` and `Nothing`; the concatenation is exactly `[5, 4, 3, 2, 1]` with distinct
  `deadLetterId`s, and no row of `"dl-other"` appears;
- limit 5 on the same fixture returns all five rows and `nextCursor = Nothing` (the over-fetch
  does not leak a sixth row or a spurious cursor); limit 1000 behaves the same;
- the member filter: seed position 1 for member 0 and position 2 for member 1 under one name
  (`insertDeadLetterWith`); `Just 1` returns only position 2, `Just 0` only position 1,
  `Nothing` returns `[2, 1]`; `Just 7` returns an empty page;
- the reason JSON round-trips structurally: seed with reason
  `object ["kind" .= "other", "summary" .= "s", "detail" .= object ["code" .= (42 :: Int)]]`
  and assert the returned `reason` equals that `Value`, not a string;
- a real worker-produced dead letter reads back: subscribe with the handler from
  `Test/SubscriptionRetryDeadLetter.hs` (returns `DeadLetter (DeadLetterPoison "boom")` at
  position 2 and `Stop` at 3), wait for a clean stop, then assert one row with
  `globalPosition = 2`, `eventId` equal to the event's id, `reason` equal to
  `object ["kind" .= "poison", "detail" .= "boom"]`, `reasonSummary = "poison: boom"`,
  `attemptCount = 1`, `consumerGroupMember = 0`, and `createdAt <= now`;
- agreement with the internal statement: for member 0 of `"dl-page"`, the positions from
  `Pool.use store.pool (Session.statement (name, 0) SQL.readDeadLettersStmt)` equal the
  concatenated pages' positions;
- a cursor survives a hard delete: seed positions for two streams, take the page-1 cursor,
  `hardDeleteStream` the stream that owns the cursor row's event, and assert paging from that
  cursor still returns the remaining older rows in order;
- `mkSubscriptionDeadLetterLimit` returns `Left` for `0`, `-1`, and `1001`, and `Right` for
  `1` and `1000`; `subscriptionDeadLetterLimitValue defaultSubscriptionDeadLetterLimit == 100`.

**Mock test** (new file `kiroku-store/test/Test/SubscriptionDeadLettersMock.hs`), modelled on
`Test/SubscriptionCheckpointInventoryMock.hs`: an `interpret_` that answers
`ListSubscriptionDeadLetters query` from an in-memory list of `SubscriptionDeadLetter` values
(sorted newest first, filtered by the query's member and cursor, truncated with the same
over-fetch rule) and counts calls; assert that `subscriptionDeadLetters` returns the expected
page, that a second call with the returned cursor returns the rest, and that each wrapper call
dispatched exactly once. This proves IR-9 acceptance 4.

**Structural gate** (`kiroku-store/test/Test/PerformanceStructure.hs`). In `noOpAppendSpec`
add `mkSubscriptionDeadLetterLimit 0 `shouldSatisfy` either (const True) (const False)` and
`mkSubscriptionDeadLetterLimit 1001 …` to the zero-checkout case (import them from
`Kiroku.Store`). In `queryPlanSpec` add, importing the statements from
`Kiroku.Store.Subscription.DeadLetter.SQL` (add it to the test stanza's reachable modules by
exposing it, or, since it is an `other-module`, re-export the two statements from
`Kiroku.Store.SQL`'s dead-letter group; choose the re-export so the module stays internal):

```haskell
            it "member-scoped dead-letter pages use ix_dead_letters_subscription_position without Sort" $ \store -> do
                plan <-
                    explainProductionStatement
                        store
                        SQL.listSubscriptionMemberDeadLettersStmt
                        [ ("$5", "50::int4")
                        , ("$4", "9223372036854775807::bigint")
                        , ("$3", "9223372036854775807::bigint")
                        , ("$2", "0::int4")
                        , ("$1", "'performance-read'::text")
                        ]
                expectIndex "ix_dead_letters_subscription_position" plan
                expectNoNodeType "Sort" plan

            it "all-member dead-letter pages use ix_dead_letters_subscription_position" $ \store -> do
                plan <-
                    explainProductionStatement
                        store
                        SQL.listSubscriptionDeadLettersStmt
                        [ ("$4", "50::int4")
                        , ("$3", "9223372036854775807::bigint")
                        , ("$2", "9223372036854775807::bigint")
                        , ("$1", "'performance-read'::text")
                        ]
                expectIndex "ix_dead_letters_subscription_position" plan
```

Replacement order matters: `$5` is substituted before `$1` so that `$1` does not also match the
prefix of `$10`-style placeholders; the existing cases do the same. The second case allows a
`Sort` node deliberately (see the Decision Log); it is a bounded top-N sort under `LIMIT`. If
the first case shows a `Sort`, or the row comparison appears as a `Filter` rather than in
`Index Cond`, rewrite both predicates as
`(global_position < $n OR (global_position = $n AND dead_letter_id < $m))`, re-run, and record
the evidence in Surprises & Discoveries.

Register `Test.SubscriptionDeadLetters` and `Test.SubscriptionDeadLettersMock` in
`kiroku-store/test/Main.hs` (import and call after `SubscriptionRetryDeadLetter.spec`) and in
the cabal test stanza's `other-modules`.

**Versions and changelogs.** In `kiroku-store/kiroku-store.cabal` set `version: 0.9.0.0` and
add a `## 0.9.0.0 — <date>` entry at the top of `kiroku-store/CHANGELOG.md` (or add to the
existing unreleased 0.9.0.0 heading) with a "Breaking Changes" bullet (the `Store` effect gains
`ListSubscriptionDeadLetters`; exhaustive custom and mock interpreters must handle it) and a
"New Features" bullet naming `subscriptionDeadLetters`, the query/page/cursor types, and
`mkSubscriptionDeadLetterLimit`. Change every `kiroku-store ^>=0.8` to `^>=0.9` in
`kiroku-cli/kiroku-cli.cabal` (0.2.0.7), `kiroku-otel/kiroku-otel.cabal` (0.2.0.8), and
`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` (0.5.1.2) unless already done, adding to
each `CHANGELOG.md` an "Other Changes" entry in the phrasing of the 2026-08-16 entries
("Requires `kiroku-store ^>=0.9`, whose exported `Store` effect gains the dead-letter read
constructor. No source change was required and no … API or runtime behavior changed."). If a
package in the repository has an exhaustive `Store` interpreter, the build tells you; add the
arm (delegate in a real interpreter, `error` in a mock) and record it. `kiroku-metrics`'s bound
moves in Milestone 4 with its own changelog entry.

Acceptance for Milestone 1: `cabal build all` succeeds with no warnings, and
`cabal test kiroku-store-test --test-options='--match "SubscriptionDeadLetters"'` and
`cabal test kiroku-store-test --test-options='--match "production query plans"'` pass every
case above. The whole store suite is green.

### Milestone 2: the dead-letter WAI application in `kiroku-metrics`

Scope: a new module turns the library operation into the HTTP route, fully testable with a
scripted provider and no database. It is not yet mounted in the server.

Create `kiroku-metrics/src/Kiroku/Metrics/DeadLetters.hs`:

```haskell
{- | The @GET /subscriptions/\<name\>/dead-letters@ HTTP endpoint (IR-9).

Serves one subscription's parked dead letters, newest first, as a cursor-paginated
JSON page, read through the public 'Kiroku.Store.Subscription.subscriptionDeadLetters'
operation. The failure reason is served as JSON. The route is read-only: redrive,
delete, and retry-policy changes are not offered here, and non-GET methods answer 405.
-}
module Kiroku.Metrics.DeadLetters (
    DeadLetterProvider,
    storeDeadLetters,
    DeadLetterItem (..),
    DeadLetterPageResponse (..),
    deadLetterPageResponse,
    renderDeadLetterCursor,
    parseDeadLetterCursor,
    DeadLetterRequest (..),
    parseDeadLetterRequest,
    deadLettersApp,
) where

type DeadLetterProvider = SubscriptionDeadLetterQuery -> IO (Either StoreError SubscriptionDeadLetterPage)

storeDeadLetters :: KirokuStore -> DeadLetterProvider
storeDeadLetters store = runStoreIO store . subscriptionDeadLetters
```

Wire types use plain `Int64`, `Int32`, `Text`, `UUID`, `Value`, and `UTCTime` so the JSON shape
does not depend on library newtypes, with hand-written `ToJSON` and `FromJSON` instances (the
package's other wire types do the same so the shape is explicit and stable):

```haskell
data DeadLetterItem = DeadLetterItem
    { deadLetterId :: !Int64
    , subscription :: !Text
    , member :: !Int32
    , globalPosition :: !Int64
    , eventId :: !UUID
    , reason :: !Value
    , reasonSummary :: !Text
    , attemptCount :: !Int32
    , createdAt :: !UTCTime
    }
    deriving stock (Eq, Show)

data DeadLetterPageResponse = DeadLetterPageResponse
    { items :: ![DeadLetterItem]
    , nextCursor :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

deadLetterPageResponse :: SubscriptionDeadLetterPage -> DeadLetterPageResponse
```

Keys are exactly `dead_letter_id`, `subscription`, `member`, `global_position`, `event_id`,
`reason`, `reason_summary`, `attempt_count`, `created_at`, `items`, and `next_cursor`; the
`ToJSON` instance for the page emits `next_cursor` only when it is `Just` (build the key list
with `maybe [] (\c -> ["next_cursor" .= c])`), and the `FromJSON` instance treats a missing key
as `Nothing`. `UTCTime` encodes through aeson as an RFC 3339 UTC string; `UUID` through aeson's
`ToJSON UUID` instance as its canonical text; `reason` is embedded as the `Value` it is.

The cursor codec is two total functions: `renderDeadLetterCursor (SubscriptionDeadLetterCursor
(GlobalPosition p) i) = T.pack (show p) <> ":" <> T.pack (show i)` and
`parseDeadLetterCursor`, which splits on the first `:`, requires both halves to be non-empty
strings of ASCII digits that parse as `Int64` without overflow (use `Data.Text.Read.decimal`
and check that the remainder is empty), and returns `Nothing` otherwise.

Query parsing is one pure function over the WAI query string:

```haskell
data DeadLetterRequest = DeadLetterRequest
    { requestMember :: !(Maybe Int32)
    , requestAfter :: !(Maybe SubscriptionDeadLetterCursor)
    , requestLimit :: !SubscriptionDeadLetterLimit
    }

-- | Left carries (status, code, message, details) for the structured envelope.
parseDeadLetterRequest :: Query -> Either (Status, Text, Text, Maybe Value) DeadLetterRequest
```

Rules: `limit` must be a decimal integer accepted by `mkSubscriptionDeadLetterLimit` (so 1
through 1000), defaulting to `defaultSubscriptionDeadLetterLimit`; `member` must be a decimal
integer in `[0, maxBound :: Int32]`; `from` must satisfy `parseDeadLetterCursor`; a parameter
given without a value (`?limit`) is treated as invalid; repeated parameters use the first
occurrence; unknown parameters are ignored. Any violation is HTTP 400 with code
`invalid_query_parameter` and `details` `{"parameter": "<name>", "value": "<raw>", "reason": "<what was expected>"}`
(the same code and details shape plan 88 uses, so a UI handles one vocabulary).

The application:

```haskell
deadLettersApp :: DeadLetterProvider -> Application
deadLettersApp provider req respond =
    case pathInfo req of
        ["subscriptions", name, "dead-letters"]
            | requestMethod req /= methodGet ->
                respond (errorResponse status405 "method_not_allowed"
                    "Dead letters are read-only over HTTP; only GET is supported." Nothing)
            | otherwise ->
                case parseDeadLetterRequest (queryString req) of
                    Left (status, code, message, details) -> respond (errorResponse status code message details)
                    Right parsed -> do
                        result <- provider (toQuery name parsed)
                        respond $ case result of
                            Right page -> jsonResponse status200 (encode (deadLetterPageResponse page))
                            Left (ConnectionError message) ->
                                errorResponse status503 "dead_letters_unavailable"
                                    ("could not read dead letters: " <> message) Nothing
                            Left other ->
                                errorResponse status500 "store_error" (T.pack (show other)) Nothing
        _ -> respond (errorResponse status404 "not_found" "Not found" Nothing)
```

where `toQuery name parsed = SubscriptionDeadLetterQuery (SubscriptionName name)
(requestMember parsed) (requestAfter parsed) (requestLimit parsed)`. `errorResponse` is the
structured-envelope helper resolved by coordination rule 3. Reads raise no `StoreError` other
than `ConnectionError`, so the `store_error` arm is defensive. Exceptions thrown by a provider
propagate to Warp exactly as they do for the sibling routes.

Register the module under `exposed-modules` in `kiroku-metrics/kiroku-metrics.cabal` (the
library already depends on `aeson`, `text`, `time`, `uuid`, `vector`, `wai`, `http-types`, and
`kiroku-store`) and add `module Kiroku.Metrics.DeadLetters` to the export and import lists of
`kiroku-metrics/src/Kiroku/Metrics.hs`. Add a `## Unreleased` section at the top of
`kiroku-metrics/CHANGELOG.md` if none exists, with a `### New Features` bullet describing the
route, the module, and the provider.

**Tests.** Create `kiroku-metrics/test/Test/DeadLettersSpec.hs`, register it in
`kiroku-metrics/test/Main.hs` and the test-suite `other-modules`, and add `time` and `vector`
to the test-suite `build-depends` if they are not there. A `describe "Kiroku.Metrics.DeadLetters (scripted provider)"`
block, all database-free:

- codec: build a `SubscriptionDeadLetterPage` with two rows (positions 4211 and 4200,
  ids 7 and 3, reasons `{"kind":"poison","detail":"unknown SKU"}` and
  `{"kind":"max_attempts_exceeded","attempts":5}`, `createdAt = UTCTime (fromGregorian 2026 9 10) 0`)
  and `nextCursor = Just (cursor 4200 3)`; assert `toJSON (deadLetterPageResponse page)` equals
  the literal `object` with the exact keys above, `"reason"` as the nested object, and
  `"next_cursor" .= ("4200:3" :: Text)`; assert the same page with `nextCursor = Nothing`
  encodes with no `next_cursor` key at all; assert `eitherDecode (encode response) == Right response`;
- cursor codec: `parseDeadLetterCursor "4211:7"` is `Just`; each of `""`, `"abc"`, `"1:"`,
  `":1"`, `"1:2:3"`, `"-1:2"`, `"1:-2"`, `"1.5:2"`, and `"99999999999999999999:1"` is
  `Nothing`; render then parse is the identity on a few values;
- request parsing through the app: mount `deadLettersApp provider` with
  `Warp.testWithApplication`, where `provider` records the query it receives in an `IORef` and
  returns an empty page; GET `/subscriptions/orders/dead-letters?member=1&from=4211:7&limit=5`
  yields 200 and a recorded query with name `orders`, member `Just 1`, after `Just (cursor 4211 7)`,
  limit value `5`; a bare GET yields member `Nothing`, after `Nothing`, limit `100`;
- validation: `limit=0`, `limit=1001`, `limit=abc`, `limit=`, `member=-1`, `member=x`, and
  `from=garbage` each yield 400 with `error.code == "invalid_query_parameter"` and
  `error.details.parameter` naming the offending parameter; the provider is not called;
- `POST /subscriptions/orders/dead-letters` yields 405 `method_not_allowed`;
  `/subscriptions/orders/dead-letters/extra` and `/nope` yield the structured 404 `not_found`;
- a provider returning `Left (ConnectionError "boom")` yields 503 `dead_letters_unavailable`
  with `boom` in the message;
- a provider returning a two-row page with a cursor yields the documented body, with `reason`
  decoded as a JSON object (assert `reason` is an `Object`, never a `String`).

Acceptance for Milestone 2: `cabal build kiroku-metrics` succeeds and
`cabal test kiroku-metrics-test --test-options='--match "DeadLetters"'` passes every case
above without any of them opening a database (the shared PostgreSQL still starts because
`main` wraps the run).

### Milestone 3: mounting the route in the server

Scope: the store-aware server serves the route; every existing starter keeps its signature and
behaviour except for gaining this route where it already owns a store; end-to-end tests prove
the acceptance criteria over real HTTP against a real store.

Apply coordination rules 1 and 2 to `kiroku-metrics/src/Kiroku/Metrics/Server.hs`: add the
`deadLetters :: !(Maybe DeadLetterProvider)` field to the providers record, wire
`Just (storeDeadLetters store)` in the store-backed providers value and in
`startMetricsServerWithStore` (so `withMetricsServerWithStore` inherits it), and add the route
arm with the `/subscriptions` family:

```haskell
        ["subscriptions", _, "dead-letters"] -> deadLettersRoute
  ...
  where
    deadLettersRoute = case providers.deadLetters of
        Just provider -> deadLettersApp provider req respond
        Nothing ->
            respond $ errorResponse status404 "dead_letters_not_configured"
                "dead letters are not configured: start the server from a KirokuStore (startMetricsServerWithStore) or set the deadLetters provider"
                Nothing
```

The catch-all and its `{"error":"Not found"}` body do not change; the `["subscriptions"]` and
`["subscriptions", _]` arms and their configured-404 string body do not change, so a server
started with `startMetricsServerWithStore` still answers `/subscriptions` with that 404 while
answering `/subscriptions/<name>/dead-letters` with a page. Update the module header comment
and the Haddocks of the changed functions. Re-run
`grep -rn "startMetricsServerWith'\|combinedApp\|httpApp" kiroku-metrics --include='*.hs'` and
update any caller the search finds.

**Tests.** Extend `kiroku-metrics/test/Test/DeadLettersSpec.hs` with a
`describe "Kiroku.Metrics.DeadLetters (end to end)"` block using `withMigratedTestDatabase`,
`withStore (defaultConnectionSettings connStr)`, `newKirokuMetrics store`, and servers on
`port = 0` with a 200 ms sleep after start, as the sibling specs do. Helpers: a
`get :: Manager -> String -> IO (Int, ByteString)` that does not throw on non-2xx, an
`ev :: Text -> EventData` builder, and a `seedDeadLetter` that runs
`SQL.insertDeadLetterAndCheckpointStmt` through `Pool.use store.pool` (the store's own test
helpers are not a dependency of this package, so the seeding is written inline, exactly as the
store helper does it). Decode page bodies with `eitherDecode` into `DeadLetterPageResponse`.

1. A real dead letter with its reason intact (IR-9 acceptance 1 and requirement 3). Append
   three events to one stream; subscribe with a handler that returns
   `DeadLetter (DeadLetterPoison "unknown SKU")` for global position 2 and `Stop` for 3
   (`Continue` otherwise), with `batchSize = 100`; `wait handle` for the clean stop. Start
   `withMetricsServerWithStore (defaultConfig{port = 0}) m store []`. GET
   `/subscriptions/<name>/dead-letters?limit=50` is 200; the body has exactly one item whose
   `global_position` is 2, whose `event_id` equals the second event's id (read it back with
   `readAllForward`), whose `reason` decodes to the JSON object
   `{"kind":"poison","detail":"unknown SKU"}` (assert it is an `Object`), whose
   `reason_summary` is `"poison: unknown SKU"`, `attempt_count` 1, `member` 0; `next_cursor`
   is absent.
2. Empty is 200, not an error (acceptance 2). GET `/subscriptions/never-existed/dead-letters`
   is 200 with `{"items":[]}` and no `next_cursor` key.
3. Paging never skips or repeats (acceptance 3). Seed five dead letters for `"paged"` (positions
   1 through 5) and two for `"other"`. Walk `?limit=2` from no cursor, echoing each
   `next_cursor` as `from`, until it is absent: three requests, item positions `[5,4]`,
   `[3,2]`, `[1]`, seven distinct `dead_letter_id`s in total is false (five, all distinct),
   and no item has `subscription == "other"`; `?member=0&limit=10` returns the same five;
   `?member=3&limit=10` returns none.
4. Existing endpoints unchanged (acceptance 5). On the same store-backed server:
   `/subscriptions` is 404 with exactly the body `{"error":"subscription status not configured"}`,
   `/nope` is 404 with exactly `{"error":"Not found"}`, `/metrics` and `/health/ready` are 200;
   the full pre-existing suite (`ServerSpec`, `SubscriptionsSpec`, `WebSocketSpec`,
   `IntegrationSpec`, `CollectorSpec`) passes with no assertion changes.
5. Not configured. `startMetricsServer (defaultConfig{port = 0}) m []`:
   `/subscriptions/x/dead-letters` is 404 with `error.code == "dead_letters_not_configured"`.
6. Both routes on one server. Start with the store-backed providers value (`storeProviders` or
   `storeServerProviders` per the coordination rules) and a running live subscription:
   `/subscriptions` is 200 with one row and `/subscriptions/<name>/dead-letters` is 200.

Acceptance for Milestone 3: `cabal test kiroku-metrics-test` passes in full, and the transcripts
Milestone 4 pastes into the guide are captured from these tests (print the bodies with
`hspec`'s `--format` off, or capture them in a scratch executable).

### Milestone 4: documentation, example, capabilities, changelog, and request evidence

Scope: an operator can learn the route from `docs/user/metrics.md`, a library user can learn the
operation from `docs/user/subscriptions.md`, the example proves the route, the capability
catalog and the request carry the evidence, and the package changelog is release-ready.

`docs/user/metrics.md`: add `/subscriptions/<name>/dead-letters` to the deployment-assumption
call-out (no authentication; conventions section 8); add a Contents entry "Dead letters over
HTTP"; in "Starting the server" say that store-backed starters serve the route automatically;
in "HTTP endpoints" list the route; and add a section "Dead letters over HTTP" after
"Subscription status over HTTP" (after plan 87's durable-checkpoints section if it exists)
containing: the request and the response transcript from Purpose (copied from a real run, with
a real id and timestamp); a field table (`dead_letter_id` the row's stable identity;
`subscription` and `member` the checkpoint key, member 0 for an ungrouped subscription;
`global_position` and `event_id` the parked event, fetchable at plan 88's `GET /events/<event_id>`
once that ships; `reason` the structured JSON with its `kind` vocabulary `poison`,
`invalid_payload`, `max_attempts_exceeded`, `other`; `reason_summary`; `attempt_count`;
`created_at`); a "Pagination" paragraph (newest first by global position then dead-letter id;
`from` is the opaque `next_cursor` string echoed back, never computed; `limit` default 100,
maximum 1000; `next_cursor` omitted on the last page; a `member` filter); a sentence that an
unknown subscription name answers an empty page, not 404; the error table
(`invalid_query_parameter` 400, `method_not_allowed` 405, `dead_letters_not_configured` 404,
`dead_letters_unavailable` 503, `store_error` 500, `not_found` 404 when mounted standalone) and
the note that this route uses the structured envelope while older routes keep their string
errors; a "Read-only" paragraph (no redrive, delete, or retry-policy change here; those need
separate safety semantics per the cross-project conventions; POST or DELETE answers 405); a
note that names containing `/` are written percent-encoded; and one sentence that, once
released, the route and its keys are a published contract under the guide's "Wire-format
stability" section and ADR-9 (do not restate the rules; link to that section). Update the
summary line for `metrics.md` in `docs/user/README.md`.

`docs/user/subscriptions.md`: in "Per-Event Retry And Dead-Letter", add a "Reading dead
letters" paragraph with the Haskell signature, the exclusive-cursor paging idiom
(`after = page ^. #nextCursor`), the member filter, and a short example that prints each
row's summary, plus a link to the HTTP section. `docs/user/schema.md`: replace the stale
`ix_dead_letters_subscription_created_at` row with `ix_dead_letters_subscription_position`
(`dead_letters(subscription_name, consumer_group_member, global_position DESC, dead_letter_id DESC)`,
"Operator read path: newest-first dead-letter pages, index-ordered per member") and add one
sentence under `## dead_letters` pointing at `subscriptionDeadLetters` and the HTTP route as
the supported readers.

`kiroku-metrics/example/Main.hs`: after the HTTP checks, GET
`/subscriptions/example/dead-letters?limit=10`, check status 200, decode the body, and check
`items` is empty and `next_cursor` absent (the example runs no subscription, so nothing is
parked; say so in the step text). Renumber the steps and mirror the new line in the "Try it"
transcript of `docs/user/metrics.md`.

`docs/capabilities/resilient-delivery.md` (CAP-12): extend `description` and the body to say
dead letters are readable through the public `subscriptionDeadLetters` operation, add
`Kiroku.Store.Subscription` to `interface`, and add an `evidence` entry for
`kiroku-store/test/Test/SubscriptionDeadLetters.hs` (keyset paging in the canonical order with
the reason JSON intact). `docs/capabilities/operational-http-endpoints.md` (CAP-17): name the
route in `description` and body, add `Kiroku.Metrics.DeadLetters` to `interface`, and add an
`evidence` entry for `kiroku-metrics/test/Test/DeadLettersSpec.hs`. Add dated `**Update**`
entries to `docs/capabilities/log.md`. Do not change `generated.at`, `since`, or
`capabilityId`. Run `just capabilities-validate`.

Update IR-9's body (status stays `in_progress`): add an "Implementation Evidence" section
naming the operation, the module, the route, the response shape, the test files, and the
example; advance `timestamp`; add a log entry; validate.

Finalize the `## Unreleased` section of `kiroku-metrics/CHANGELOG.md`: New Features (the
route, `Kiroku.Metrics.DeadLetters`, `storeDeadLetters`, the `deadLetters` provider field),
Other Changes (requires `kiroku-store ^>=0.9`; all pre-existing endpoints, frames, and starters
unchanged), and set `kiroku-store ^>=0.9` in all three stanzas of `kiroku-metrics.cabal`.

Acceptance for Milestone 4: `nix fmt` is a no-op, `cabal build all`, `cabal test all`, and
`nix build .#kiroku-metrics` succeed, `just capabilities-validate` and the strict
improvement-request validation pass, `git diff --check` is clean, and
`cabal run -fexample kiroku-metrics-example` prints its full passing transcript including the
new step.

### Milestone 5: release, request completion, and ADR distillation

Scope: publish the packages so the keiro-ui initiative can consume the route, close the
request with evidence, and distill durable context. Nothing in this milestone runs before the
user explicitly confirms the release in the implementation session.

Follow `agents/skills/release/SKILL.md`. Immediately before proposing, re-check the
authoritative current versions on Hackage and the latest tags
(`git tag --list 'kiroku-store-v*' | sort -V | tail -1` and the same for `kiroku-metrics`,
`kiroku-cli`, `kiroku-otel`, `shibuya-kiroku-adapter`), and recompute the next versions from
the then-current state: `kiroku-store` major (the effect gained a constructor), the three
dependants patch (bound change only), and `kiroku-metrics` minor or major depending on whether
plan 87's signature change is in the same unreleased section. Prefer releasing together with
plans 87 and 88 as one cohort, in the skill's publish order, so downstream pins one version set;
if the user chooses to release this plan alone, that is also valid. Record the Hackage URLs,
tags, commits, and a clean-consumer check (a scratch Cabal project outside the working tree
that depends on the released `kiroku-store` and `kiroku-metrics` and compiles a call to
`subscriptionDeadLetters` and `storeDeadLetters`) in this plan.

Only then set IR-9 to `status: completed`, add `completedAt`, refresh `timestamp`, rewrite
the `## Status` paragraph to say which versions shipped the operation and the route and cite
this plan, add a `**Completion**` log entry, and validate strictly. Do not edit anything in the
keiro-ui repository.

Finally perform the ADR distillation pass required by PLANS.md: reread the Decision Log and
Surprises & Discoveries and judge whether the two candidate points from this plan are durable
project context: composite keyset cursors are rendered as one opaque scalar and derived only by
the library, and read-only inspection routes refuse mutating methods with 405 rather than
silently ignoring them. If they are, extend
[ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
(its section 2 is the natural home; advance its `timestamp`, add the bundle log entry with
`okf log add`, and run `just adr-validate`), or the ADR plan 88 writes about `Store`-wrapping
endpoints if that exists and fits better; allocate a new handle with
`okf id next docs/adr --profile docs/adr/profile.dhall ADR` (it printed `ADR-10` at planning
time; use whatever it prints) only if neither record is the right home. Otherwise record in
Outcomes why no ADR change was needed. Write Outcomes & Retrospective.

Acceptance for Milestone 5: Hackage lists the released versions with their tags and GitHub
releases, the clean consumer compiles, IR-9 is `completed` and its bundle validates, the ADR
bundle validates, and this plan's Progress shows every item checked.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` inside the Nix dev
shell (`nix develop`, or the direnv-loaded shell from `.envrc`), which provides `cabal`,
GHC 9.12.4, PostgreSQL for the ephemeral test databases, `okf`, `just`, and `bun`.

Establish a clean baseline first:

```bash
git status --short --branch
git log --oneline -5 -- kiroku-metrics/src/Kiroku/Metrics/Server.hs kiroku-store/CHANGELOG.md
cabal build all
cabal test kiroku-store-test
cabal test kiroku-metrics-test
```

Expected: a clean tree, both suites passing, and the log telling you which of the
coordination cases in Context and Orientation applies. Record that in Surprises & Discoveries
before editing.

Milestone 1 edits and checks:

```bash
# edit docs/improvement-requests/expose-a-public-dead-letter-read-api.md   (status: in_progress, timestamp, Status paragraph)
# edit docs/improvement-requests/log.md                                    (dated Implementation entry)
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
# edit  kiroku-store/src/Kiroku/Store/Subscription/Types.hs          (+ dead-letter types, exports)
# write kiroku-store/src/Kiroku/Store/Subscription/DeadLetter/SQL.hs (statements + session)
# edit  kiroku-store/src/Kiroku/Store/SQL.hs                          (re-export the two statements in the dead-letter group)
# edit  kiroku-store/src/Kiroku/Store/Effect.hs                       (+ constructor, interpreter branch)
# edit  kiroku-store/src/Kiroku/Store/Subscription.hs                 (+ wrapper, export, Store import)
# edit  kiroku-store/kiroku-store.cabal                               (+ other-module; test other-modules; version)
# edit  kiroku-store/test/Test/Helpers.hs                             (+ insertDeadLetterWith)
# write kiroku-store/test/Test/SubscriptionDeadLetters.hs
# write kiroku-store/test/Test/SubscriptionDeadLettersMock.hs
# edit  kiroku-store/test/Test/PerformanceStructure.hs                (+ zero-checkout, two plan cases)
# edit  kiroku-store/test/Main.hs                                     (+ two specs)
# edit  kiroku-store/CHANGELOG.md, kiroku-cli/*.cabal+CHANGELOG, kiroku-otel/*.cabal+CHANGELOG, shibuya-kiroku-adapter/*.cabal+CHANGELOG
nix fmt
cabal build all
cabal test kiroku-store-test --test-options='--match "SubscriptionDeadLetters"'
cabal test kiroku-store-test --test-options='--match "production query plans"'
cabal test kiroku-store-test
```

Expected tail of the first focused run:

```text
SubscriptionDeadLetters
  returns an empty page for an empty store [✔]
  runs through the resource-backed Store interpreter [✔]
  pages newest first without skipping or repeating [✔]
  does not leak the over-fetched row or a spurious cursor on the last page [✔]
  filters by consumer-group member [✔]
  serves the reason as structured JSON [✔]
  reads back a worker-produced dead letter [✔]
  agrees with the internal member-scoped statement [✔]
  keeps a cursor valid after the cursor row is hard-deleted [✔]
  validates the page size at construction [✔]
SubscriptionDeadLetters mock interpreter
  returns pages through one Store effect call each [✔]

Finished in 4.10 seconds
11 examples, 0 failures
```

Commit (Conventional Commits, both trailers):

```text
feat(store): add the public paginated dead-letter read operation

Add ListSubscriptionDeadLetters to the Store effect with a keyset-paginated
session in Kiroku.Store.Subscription.DeadLetter.SQL, the public
SubscriptionDeadLetter/Query/Page/Cursor types, a validated page-size limit,
and the subscriptionDeadLetters wrapper. Newest first by (global_position,
dead_letter_id); the existing readDeadLettersStmt and write/cleanup paths are
unchanged.

ExecPlan: docs/plans/89-expose-a-public-dead-letter-read-api.md
Intention: intention_01m24mtzy1embbt15zkh9h3z8c
```

followed by `chore(release): bump kiroku-store to 0.9.0.0 and dependant bounds` (skip if plan
88 already did it) with the same trailers.

Milestone 2 edits and checks:

```bash
# edit  kiroku-metrics/src/Kiroku/Metrics/JSON.hs         (structured envelope helper, if absent)
# write kiroku-metrics/src/Kiroku/Metrics/DeadLetters.hs
# edit  kiroku-metrics/src/Kiroku/Metrics.hs              (+ module re-export)
# edit  kiroku-metrics/kiroku-metrics.cabal               (+ exposed module; test other-modules; test deps time, vector)
# write kiroku-metrics/test/Test/DeadLettersSpec.hs       (scripted-provider block)
# edit  kiroku-metrics/test/Main.hs                       (+ DeadLettersSpec.spec)
# edit  kiroku-metrics/CHANGELOG.md                       (## Unreleased / ### New Features)
nix fmt
cabal build kiroku-metrics
cabal test kiroku-metrics-test --test-options='--match "DeadLetters"'
```

Expected tail:

```text
Kiroku.Metrics.DeadLetters (scripted provider)
  encodes the documented snake_case page and decodes it back [✔]
  omits next_cursor on the last page [✔]
  renders and parses cursors and rejects malformed ones [✔]
  passes member, from, and limit through to the provider [✔]
  defaults to every member, no cursor, and limit 100 [✔]
  answers 400 invalid_query_parameter without calling the provider [✔]
  answers 405 for non-GET methods [✔]
  answers the structured 404 for other paths [✔]
  answers 503 dead_letters_unavailable when the provider fails [✔]
  serves the reason as a JSON object [✔]

10 examples, 0 failures
```

Commit as `feat(metrics): add the dead-letter read WAI application` with both trailers.

Milestone 3 edits and checks:

```bash
# edit kiroku-metrics/src/Kiroku/Metrics/Server.hs   (providers field, route arm, store wiring)
grep -rn "startMetricsServerWith'\|combinedApp\|httpApp" kiroku-metrics --include='*.hs'
# edit kiroku-metrics/test/Test/DeadLettersSpec.hs   (end-to-end block)
nix fmt
cabal build kiroku-metrics
cabal test kiroku-metrics-test
```

Expected: every pre-existing example plus the Milestone 2 examples plus:

```text
Kiroku.Metrics.DeadLetters (end to end)
  serves a worker-produced dead letter with its reason as JSON [✔]
  answers 200 with an empty page for a subscription with no dead letters [✔]
  pages with next_cursor without skipping or repeating [✔]
  leaves the live subscriptions route and the legacy 404 unchanged [✔]
  answers 404 dead_letters_not_configured without a store [✔]
  serves live status and dead letters from one store-backed server [✔]
```

Commit as `feat(metrics): serve GET /subscriptions/<name>/dead-letters from the store-aware server`
with both trailers (add `!` and a `BREAKING CHANGE:` footer only if coordination rule 1 applied
to plan 87's already-changed signatures and you changed them further, which this plan does not
expect).

Milestone 4 edits and checks:

```bash
# edit docs/user/metrics.md, docs/user/subscriptions.md, docs/user/schema.md, docs/user/README.md
# edit kiroku-metrics/example/Main.hs
# edit docs/capabilities/resilient-delivery.md, docs/capabilities/operational-http-endpoints.md, docs/capabilities/log.md
# edit docs/improvement-requests/expose-a-public-dead-letter-read-api.md, docs/improvement-requests/log.md
# edit kiroku-metrics/CHANGELOG.md, kiroku-metrics/kiroku-metrics.cabal
cabal run -fexample kiroku-metrics-example
just capabilities-validate
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
nix fmt
cabal build all
cabal test all
nix build .#kiroku-metrics
git diff --check
git status --short
```

Expected example transcript (the step count depends on which sibling plans landed first; port
varies):

```text
[1/7] ephemeral postgres ready
[2/7] store + collector + metrics server on port 57277
[3/7] appended 3 events to orders-1
[4/7] HTTP /metrics, /prometheus, /health/live, /health/ready all OK
[5/7] GET /subscriptions/example/dead-letters returned an empty page (this example runs no subscription)
[6/7] WebSocket /ws/events received event eventType=OrderRefunded
[7/7] kiroku-metrics-example: all checks passed (snapshot global position = 4)
```

If cabal reports the `example` flag as unknown for another local package, use
`cabal run --constraint='kiroku-metrics +example' kiroku-metrics-example` and record which form
worked. Commit as `docs(metrics): document the dead-letter read API` and
`docs(okf): record dead-letter read evidence in CAP-12, CAP-17, and IR-9` with both trailers.

Milestone 5, only after explicit confirmation:

```bash
git tag --list 'kiroku-store-v*' | sort -V | tail -1
git tag --list 'kiroku-metrics-v*' | sort -V | tail -1
# follow agents/skills/release/SKILL.md for the cohort
```

Then the clean-consumer check in a scratch directory outside the repository:

```bash
mkdir -p "$SCRATCH/dead-letter-consumer" && cd "$SCRATCH/dead-letter-consumer"
cabal update
# write a one-module executable importing Kiroku.Store and Kiroku.Metrics that references
# subscriptionDeadLetters, defaultSubscriptionDeadLetterQuery, and storeDeadLetters,
# with `build-depends: base, kiroku-store ==<released>, kiroku-metrics ==<released>`
cabal build
```

Return to the repository, complete IR-9, run the ADR distillation pass, validate the bundles,
and commit as `docs(improvement-requests): complete IR-9` with both trailers.


## Validation and Acceptance

The plan is complete when every item below is observed, mapped to IR-9's acceptance list:

1. For a subscription with parked dead letters,
   `GET /subscriptions/<name>/dead-letters?limit=50` returns HTTP 200 with a JSON page whose
   items each carry `reason` as structured JSON (an object, never a string), and `next_cursor`
   is present exactly when more rows exist (end-to-end tests 1 and 3).
2. For a subscription with none, the same request returns HTTP 200 with `{"items":[]}` and no
   `next_cursor` key, not an error (end-to-end test 2).
3. Items appear newest first by global position then dead-letter id, the order is documented in
   `docs/user/metrics.md` and in the `subscriptionDeadLetters` Haddock, and walking pages with
   the returned cursor visits every row exactly once while the set is unchanged (store paging
   test; end-to-end test 3); the member-scoped statement is index-ordered with no sort and the
   all-member statement uses the same index (structural gate).
4. `subscriptionDeadLetters` and its types are exported from `Kiroku.Store.Subscription` (and
   `Kiroku.Store`), `Test.SubscriptionDeadLettersMock` passes with no SQL executed, and the
   metrics scripted-provider block passes with no database.
5. Every pre-existing endpoint, WebSocket frame, and JSON body is unchanged: the existing specs
   pass with no assertion edits; `git diff` shows no change under
   `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, no change to `readDeadLettersStmt`,
   `insertDeadLetterAndCheckpointStmt`, or `deleteDeadLettersForOrphanedEventsStmt` in
   `kiroku-store/src/Kiroku/Store/SQL.hs`, and no change to the migrations package; `GET /nope`
   still returns exactly `{"error":"Not found"}` (end-to-end test 4).

Beyond the request: `cabal build all` produces no warnings; a limit of 0 or 1001 is refused
before any pool checkout (structural gate) and as HTTP 400 without calling the provider;
`POST` on the route is 405; `just capabilities-validate` and the strict improvement-request
validation pass; the example exits 0; and after Milestone 5 the released packages resolve from
Hackage in a clean consumer and IR-9 is `completed`.


## Idempotence and Recovery

All source, test, and documentation edits are additive or mechanical and can be re-applied;
`nix fmt`, `cabal build`, `cabal test`, `okf validate`, `just capabilities-validate`, and the
example are safe to rerun. The operation and the route are read-only and never write to the
store, so repeating a request or a test is always safe. Tests use a fresh migrated database per
example and OS-assigned ports, so reruns cannot collide. The seeding statement is
`ON CONFLICT DO NOTHING` on the natural key, so a repeated seed is a no-op.

If `cabal build all` fails after Milestone 1 with an incomplete-patterns error in a package
other than `kiroku-store`, that package has an exhaustive `Store` interpreter; add the arm and
record it. If a version bump conflicts with a concurrent unreleased bump from plan 88, keep the
single higher heading and merge the bullets under it. If the structural-gate case for the
member-scoped statement reports a `Sort`, or the row comparison lands in a `Filter` instead of
the `Index Cond`, rewrite the predicate as the expanded disjunction given in Milestone 1 and
re-run; if the all-member case reports no index at all (the planner chose a sequential scan for
the fixture's ten-percent selectivity), record the plan in Surprises & Discoveries and keep only
the member-scoped assertion as the gate, since the documented index promise is per member.

If `Server.hs` has changed under you because a sibling plan landed mid-implementation, re-read
the "Coordinating with plans 87 and 88" rules, rebase this plan's field and route arm onto the
record that now exists, and never leave two providers records or two envelope helpers in the
package. To roll back before release, revert the milestone's commits in reverse order; nothing
outside the repository observes the change until a release.

The IR and capability bundle edits are validated by strict profile checks; a failure names the
offending field (typically a `timestamp` that did not advance or a missing dated log entry).
Keep `status: in_progress` until release evidence exists; never set `completed` on the strength
of a local build. Publishing is not idempotent: before retrying a partially failed release,
inspect Hackage, local and upstream tags, and `git status` to see which step succeeded, follow
the release skill's recovery guidance, and never reuse a version for different contents or move
a pushed tag. If the release is declined or deferred, Milestones 1 to 4 remain complete and
valid on `master`, the changelog sections stay unreleased, and IR-9 stays `in_progress` with
its evidence.


## Interfaces and Dependencies

At the end of Milestone 1, `kiroku-store` (version 0.9.0.0) exports:

```haskell
-- Kiroku.Store.Subscription.Types (re-exported by Kiroku.Store.Subscription and Kiroku.Store)
data SubscriptionDeadLetter = SubscriptionDeadLetter
    { deadLetterId :: !Int64, subscriptionName :: !SubscriptionName, consumerGroupMember :: !Int32
    , globalPosition :: !GlobalPosition, eventId :: !EventId, reason :: !Value
    , reasonSummary :: !Text, attemptCount :: !Int32, createdAt :: !UTCTime }
data SubscriptionDeadLetterCursor = SubscriptionDeadLetterCursor
    { cursorGlobalPosition :: !GlobalPosition, cursorDeadLetterId :: !Int64 }
subscriptionDeadLetterCursor :: SubscriptionDeadLetter -> SubscriptionDeadLetterCursor
newtype SubscriptionDeadLetterLimit                       -- constructor not exported
newtype SubscriptionDeadLetterLimitOutOfRange = SubscriptionDeadLetterLimitOutOfRange Int32
mkSubscriptionDeadLetterLimit :: Int32 -> Either SubscriptionDeadLetterLimitOutOfRange SubscriptionDeadLetterLimit
subscriptionDeadLetterLimitValue :: SubscriptionDeadLetterLimit -> Int32
defaultSubscriptionDeadLetterLimit :: SubscriptionDeadLetterLimit   -- 100
data SubscriptionDeadLetterQuery = SubscriptionDeadLetterQuery
    { subscriptionName :: !SubscriptionName, consumerGroupMember :: !(Maybe Int32)
    , after :: !(Maybe SubscriptionDeadLetterCursor), limit :: !SubscriptionDeadLetterLimit }
defaultSubscriptionDeadLetterQuery :: SubscriptionName -> SubscriptionDeadLetterQuery
data SubscriptionDeadLetterPage = SubscriptionDeadLetterPage
    { deadLetters :: !(Vector SubscriptionDeadLetter), nextCursor :: !(Maybe SubscriptionDeadLetterCursor) }

-- Kiroku.Store.Effect
ListSubscriptionDeadLetters :: SubscriptionDeadLetterQuery -> Store m SubscriptionDeadLetterPage

-- Kiroku.Store.Subscription
subscriptionDeadLetters :: (HasCallStack, Store :> es) => SubscriptionDeadLetterQuery -> Eff es SubscriptionDeadLetterPage

-- Kiroku.Store.SQL (re-exported from the internal Kiroku.Store.Subscription.DeadLetter.SQL)
listSubscriptionDeadLettersStmt :: Statement (Text, Int64, Int64, Int32) (Vector SubscriptionDeadLetter)
listSubscriptionMemberDeadLettersStmt :: Statement (Text, Int32, Int64, Int64, Int32) (Vector SubscriptionDeadLetter)
```

No new library dependency is added to `kiroku-store`; the SQL uses `hasql`,
`contravariant-extras`, `aeson` (`Value`), `uuid`, `time`, and `vector`, all present.

At the end of Milestone 2, `kiroku-metrics` exports `Kiroku.Metrics.DeadLetters` with
`DeadLetterProvider`, `storeDeadLetters :: KirokuStore -> DeadLetterProvider`,
`DeadLetterItem (..)`, `DeadLetterPageResponse (..)`,
`deadLetterPageResponse :: SubscriptionDeadLetterPage -> DeadLetterPageResponse`,
`renderDeadLetterCursor :: SubscriptionDeadLetterCursor -> Text`,
`parseDeadLetterCursor :: Text -> Maybe SubscriptionDeadLetterCursor`,
`DeadLetterRequest (..)`, `parseDeadLetterRequest :: Query -> Either (Status, Text, Text, Maybe Value) DeadLetterRequest`,
and `deadLettersApp :: DeadLetterProvider -> Application`; and, unless a sibling plan already
provides an equivalent, `Kiroku.Metrics.JSON` exports `errorEnvelope :: Text -> Text -> Maybe Value -> Value`
and `errorResponse :: Status -> Text -> Text -> Maybe Value -> Response`. No new library
dependency; the test suite gains `time` and `vector` if absent.

At the end of Milestone 3, the providers record in `Kiroku.Metrics.Server` has a field
`deadLetters :: !(Maybe DeadLetterProvider)`; the no-providers value sets it to `Nothing`; the
store-backed providers value and `startMetricsServerWithStore` set it to
`Just (storeDeadLetters store)`; every previously exported name keeps its exact type and
observable behaviour apart from store-backed starters additionally serving the route.

Wire contract owned by this plan (frozen once released):

```json
{
  "items": [
    {
      "dead_letter_id": 7,
      "subscription": "inventory-projection",
      "member": 0,
      "global_position": 4211,
      "event_id": "0198f2f3-8a9e-7c31-b1d4-2f6f0f4b9d21",
      "reason": { "kind": "poison", "detail": "unknown SKU" },
      "reason_summary": "poison: unknown SKU",
      "attempt_count": 1,
      "created_at": "2026-09-10T02:41:07.512339Z"
    }
  ],
  "next_cursor": "4211:7"
}
```

Request parameters: `member` (optional, integer 0 or greater), `from` (optional, an opaque
cursor string previously returned as `next_cursor`), `limit` (optional, 1 through 1000, default
100). Error bodies on this route: `400 {"error":{"code":"invalid_query_parameter","message":…,"details":{"parameter":…,"value":…,"reason":…}}}`,
`405 {"error":{"code":"method_not_allowed",…}}`, `404 {"error":{"code":"dead_letters_not_configured",…}}`,
`503 {"error":{"code":"dead_letters_unavailable",…}}`, `500 {"error":{"code":"store_error",…}}`,
and, standalone only, `404 {"error":{"code":"not_found","message":"Not found"}}`.

Dependency direction is unchanged: `kiroku-metrics` depends on `kiroku-cli` and `kiroku-store`;
nothing depends on `kiroku-metrics`; `kiroku-store` gains no web dependency. The only runtime
service is PostgreSQL with the existing Kiroku migrations (no new migration). Locate dependency
sources through `mori registry show <project> --full` (for example `hasql/hasql`,
`yesodweb/wai`, `haskell/aeson`) when behaviour is uncertain; do not inspect `/nix/store`.


## Revision Notes

- 2026-09-10: Linked IR-9 to this plan in the same session the plan was created. The request's
  frontmatter now reads `status: accepted` with its Status section citing this plan, and the
  improvement-request bundle log records the acceptance. No implementation scope changed.
