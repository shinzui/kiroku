---
id: 79
slug: document-compaction-for-operators-and-add-embeddable-kiroku-cli-compaction-commands
title: "Document compaction for operators and add embeddable kiroku-cli compaction commands"
kind: exec-plan
created_at: 2026-08-22T14:06:35Z
intention: "intention_01m0mwdmnfex3tv9fg0t57htfv"
master_plan: "docs/masterplans/11-manifest-driven-selective-event-compaction.md"
---

# Document compaction for operators and add embeddable kiroku-cli compaction commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After the preceding plans in this initiative land, `kiroku-store` can preview and apply a
*compaction manifest* — an immutable, digest-sealed list of events that a consumer has proven
redundant and wants physically removed — but only a Haskell programmer who reads the source can
use it. This plan makes the capability usable by operators and by teams embedding Kiroku. When it
is complete, an operator can open `docs/user/compaction.md` and learn, in plain language, how
selective physical deletion differs from the logical `truncate_before` marker, from whole-stream
hard delete, from reusable PostgreSQL space, and from returning disk to the operating system.
They can follow a documented workflow from "read the store identity" through "build a manifest",
"preview it", "review the digest", "apply it", and "read the ledger". A host application that
already embeds the `kiroku` operator command tree gains four new commands:
`kiroku compaction preview --manifest FILE`, `kiroku compaction apply --manifest FILE
--confirm-digest HEX`, `kiroku compaction ledger`, and `kiroku store identity`. Each renders a
human table or JSON, and — unlike the existing remote status command — each exits non-zero on
refusal or failure, so a shell script cannot mistake a refused apply for success. The capability
catalogue gains a validated record, the observability and production guides describe the new
events and grants, and every OKF bundle still validates.

To see it working: run the `kiroku-cli` test suite, which drives every new command against an
ephemeral PostgreSQL database, and open the rendered documentation.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Write `docs/user/compaction.md` with the four-way distinction, the consumer workflow, the manifest JSON example, the refusal vocabulary, lease interaction, chunking, authorization, and audit guidance.
- [ ] M1: Update `docs/user/lifecycle.md`, `docs/user/observability.md`, `docs/user/schema-migrations.md`, `docs/user/README.md`, `docs/PRODUCTION-DEPLOYMENT.md`, and `README.md`.
- [ ] M1: Review Haddock on `Kiroku.Store.Compaction`, `Kiroku.Store.Compaction.Types`, `Kiroku.Store.Read`, and `Kiroku.Store.Transaction` for the same distinctions; fix gaps.
- [ ] M2: Allocate a capability handle with `okf id next`, write `docs/capabilities/selective-event-compaction.md`, update `docs/capabilities/index.md` and `log.md`, run `just capabilities-validate` and `just adr-validate`.
- [ ] M3: Add `KirokuCompaction`, `KirokuStore`, `CompactionCommand`, `StoreCommand`, and option records to `Kiroku.Cli.Command`.
- [ ] M3: Extend `Kiroku.Cli.Parser` with the `compaction` and `store` subcommands and their flags.
- [ ] M3: Create `Kiroku.Cli.Compaction` with manifest loading, `--confirm-digest` check, and table/JSON renderers for reports, refusals, ledger records, and the store identity.
- [ ] M3: Add `KirokuCommandOutcome` and `executeKirokuCommandWithStore` to `Kiroku.Cli.Run`; route `runKirokuCommandWithStore` through it with non-zero exits; keep `renderKirokuCommandWithStore`.
- [ ] M3: Make `resolveStandaloneOptions` refuse compaction and store commands with the exact guidance text; extend `runStandaloneCommand` exhaustively.
- [ ] M3: Register the new module in `kiroku-cli/kiroku-cli.cabal`; add the `kiroku-cli` changelog entry; add the `docs/user/operator-cli.md` section.
- [ ] M4: Parser tests, host-embedding test, manifest decode failure, confirm-digest mismatch, renderer golden strings, standalone refusal.
- [ ] M4: Live `withTestStore` tests: preview refusal exit 2, preview success, apply success, apply already-applied, ledger listing, store identity.
- [ ] M4: `cabal build all`, `cabal test kiroku-cli:kiroku-cli-test`, `cabal test all`, `nix fmt`, `nix flake check` green; commit with trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Compaction and store-identity commands are embeddable-only. The standalone `kiroku`
  binary refuses them with guidance, and no HTTP endpoint is added to `kiroku-metrics`.
  Rationale: Since `kiroku-cli` 0.2.0.0 the standalone binary is a pure remote client with no
  database connectivity; the only remote surface it has is the read-only `kiroku-metrics`
  `/subscriptions` endpoint. Exposing a destructive apply over HTTP would turn a read-only
  observability package into a mutating one and would bypass the host's authorization layer,
  which the MasterPlan's Vision & Scope explicitly excludes. A host that owns a `KirokuStore`
  already embeds the command tree through `kirokuSubparser`; that is where destructive work
  belongs. The standalone, database-connected console for Kiroku-backed deployments is
  `mori://shinzui/keiro/packages/keiro-ops` (its `Keiro.Ops.Stream` domain already wraps
  `softDeleteStream`, `hardDeleteStream` with stream-name confirmation and `--force`, and the
  truncate-before marker with preview, resolving its connection from `--database-url` /
  `KEIRO_OPS_DATABASE_URL`), and Mori's consumer plan mounts keiro-ops rather than building its
  own confirmation surface. A `stream compact …` command there is a keiro improvement request to
  file after `docs/plans/80-release-the-compaction-cohort-and-prove-it-from-a-clean-external-consumer.md`
  ships; it should reuse this plan's `Kiroku.Cli.Compaction` renderers the way `kiroku-metrics`
  reuses `SubscriptionStatusRow`. Design the renderers and `KirokuCommandOutcome` with that
  second host in mind: no `putStrLn`, no `exitWith` inside the library, all output returned as
  `Text`.
  Date: 2026-08-22

- Decision: Introduce `KirokuCommandOutcome` and `executeKirokuCommandWithStore` rather than
  changing `renderKirokuCommandWithStore`'s type.
  Rationale: `renderKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO Text` is
  public and used by hosts; the existing remote status command deliberately folds fetch errors
  into its output text with exit code 0, and a test pins that. A refused or failed compaction
  must not inherit that behaviour. A new outcome-carrying entry point gives hosts an exit code
  without breaking the old signature.
  Date: 2026-08-22

- Decision: `apply` requires `--confirm-digest HEX` equal to the manifest's own digest, checked
  before any database work.
  Rationale: The manifest file already carries its digest and is validated on decode. Requiring
  the operator to repeat the digest on the command line is the "explicit operator confirmation"
  IR-14 acceptance item 1 asks for: the value is produced by preview, reviewed by a human, and
  re-typed at apply time, so a stale or wrong file cannot be applied by habit.
  Date: 2026-08-22

- Decision: The manifest file format is the `FromJSON CompactionManifest` codec defined by
  `docs/plans/76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md`;
  the CLI defines no second format.
  Rationale: One codec, owned by the library, keeps the digest check in one place and lets the
  consuming project (Mori) write the same JSON the CLI reads.
  Date: 2026-08-22

- Decision: Documentation, capability record, Haddock review, and CLI live in one plan.
  Rationale: They are all operator-facing delivery of the same behaviour, share the same
  vocabulary, and must be consistent with each other; splitting them would multiply reviews of
  identical prose.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a Cabal multi-package project (`cabal.project` at the root, GHC 9.12.4).
The packages that matter here are `kiroku-store` (the event-store library), `kiroku-cli` (the
operator command tree and standalone binary), `kiroku-metrics` (an HTTP observability server
that depends on `kiroku-cli` only to reuse one JSON codec), and `kiroku-test-support` (ephemeral
PostgreSQL fixtures for tests). Developer recipes live in `justfile`; the ones used here are
`just capabilities-validate`, `just adr-validate`, and plain `cabal` commands.

**What "compaction" means in this plan.** A *compaction manifest* is a value of type
`Kiroku.Store.Compaction.Types.CompactionManifest`: an immutable list of *selections* (event ID,
originating stream name, original stream version, global position, and any acknowledged link
memberships), plus the store identity, an operation label, two reference policies, and the
expected head version of every affected stream, sealed by a SHA-256 *digest* over a canonical
byte encoding. *Preview* (`previewCompaction`) validates a manifest against the live store
without writing anything and returns either a non-empty list of typed *refusals* or a
deterministic *report* with counts and its own digest. *Apply* (`applyCompaction`) runs preview's
validation under locks inside one transaction, deletes exactly the accounted rows, writes a
*ledger* record into `kiroku.event_compactions`, and returns the record; applying the same
manifest again returns the stored record as `CompactionAlreadyApplied`. The *store identity*
(`storeIdentity`) is a UUID installed by migration `0012`. The *reference inventory*
(`lookupEventReferences`) lists an event's memberships (home stream row, `$all` row, link rows),
dead-letter count, and causation dependents; consumers use it to build manifests. All of these
are delivered by the sibling plans
`docs/plans/74-add-a-store-identity-and-an-append-only-event-compaction-ledger.md`,
`docs/plans/75-expose-an-event-membership-and-reference-inventory-read-api.md`,
`docs/plans/76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md`,
`docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md`, and
`docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md`. This
plan assumes all five are complete; verify with `grep -n "previewCompaction\|applyCompaction\|compactionLedger" kiroku-store/src/Kiroku/Store/Compaction.hs`
before starting.

The public signatures this plan consumes (from `Kiroku.Store.Compaction`, re-exported by
`Kiroku.Store`) are:

```haskell
previewCompaction :: (Store :> es) => CompactionManifest -> Eff es (Either (NonEmpty CompactionRefusal) CompactionReport)
applyCompaction   :: (Store :> es) => CompactionManifest -> Eff es (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
compactionLedger  :: (Store :> es) => CompactionLedgerQuery -> Eff es (Vector CompactionRecord)
storeIdentity     :: (Store :> es) => Eff es StoreIdentity          -- Kiroku.Store.Read
mkCompactionLedgerLimit :: Int32 -> Either CompactionLedgerError CompactionLedgerLimit   -- 1..1000
compactionDigestHex :: CompactionDigest -> Text
parseCompactionDigestHex :: Text -> Either Text CompactionDigest
manifestDigest :: CompactionManifest -> CompactionDigest
maxCompactionSelections :: Int   -- 100000
```

`CompactionApplyResult` is `CompactionAppliedNow CompactionRecord | CompactionAlreadyApplied
CompactionRecord`. `CompactionRecord` carries `compactionId`, `report`, `appliedAt`, and
`appliedBy`. `CompactionReport` carries the manifest digest, store identity, operation, the two
policies, eleven counters and positions (`selectedEvents`, `homeMemberships`,
`globalMemberships`, `linkMemberships`, `deadLettersRemoved`, `causationDependents`,
`lowestGlobalPosition`, `highestGlobalPosition`), `affectedStreams`, and `reportDigest`.
`CompactionManifest`, `CompactionReport`, `CompactionRecord`, and `CompactionRefusal` have
hand-written Aeson instances with snake_case keys and lowercase-hex digests; `FromJSON
CompactionManifest` requires a `digest` key and fails when it does not match the recomputed
value. The store effect is run with `runStoreIO :: KirokuStore -> Eff '[Store, Error StoreError,
IOE] a -> IO (Either StoreError a)` from `Kiroku.Store.Effect`. The exact field names are
authoritative in `kiroku-store/src/Kiroku/Store/Compaction/Types.hs`; read it before writing
renderers.

**The `kiroku-cli` package today.** Its library (`kiroku-cli/kiroku-cli.cabal`, `exposed-modules`)
has six modules under `kiroku-cli/src/Kiroku/Cli/`:

- `Command.hs` defines the command tree as plain data: `data KirokuCommand = KirokuNoCommand |
  KirokuSubscriptions SubscriptionCommand`, `data SubscriptionCommand = SubscriptionStatus
  StatusOptions`, `data StatusOptions = StatusOptions { outputFormat :: !OutputFormat, endpoint
  :: !(Maybe RemoteEndpoint) }`, `data OutputFormat = OutputTable | OutputJson`, and
  `newtype RemoteEndpoint = RemoteEndpoint Text`. Everything is exported with `(..)`.
- `Parser.hs` builds `optparse-applicative` parsers by hand: `kirokuCommandParser :: Parser
  KirokuCommand` is `maybe KirokuNoCommand id <$> optional (subparser (command "subscriptions"
  ...))`; `kirokuParserInfo :: ParserInfo KirokuCommand` wraps it with `helper`, `fullDesc`, and
  `header "kiroku - operator commands for Kiroku event stores"`; `kirokuSubparser ::
  (KirokuCommand -> command) -> Mod CommandFields command` is the *embedding hook* — it returns a
  `command "kiroku" ...` modifier that a host's own `subparser` can append with `<>`. The
  private `statusOptionsParser` shows the house style: `option (eitherReader parseOutputFormat)
  (long "format" <> metavar "table|json" <> value Command.OutputTable <> help "...")` and
  `optional (... <$> strOption (long "remote-url" <> metavar "URL" <> help "..."))`.
- `Run.hs` exports `runKirokuCommand :: KirokuCommand -> IO ()` (prints guidance when no store
  is available), `runKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO ()` (renders
  and prints), and `renderKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO Text`
  (the real dispatcher). For status it either calls `renderRemoteSubscriptionStatus` or reads
  `subscriptionStates store`.
- `Subscription/Status.hs` is the rendering template: a row record with hand-written
  `ToJSON`/`FromJSON` (snake_case wire keys), `renderSubscriptionStatusRows :: OutputFormat ->
  [SubscriptionStatusRow] -> Text` dispatching to a padded-column `renderTable` (header
  `SUBSCRIPTION  MEMBER  PHASE  GLOBAL_POSITION`, widths from `columnWidth`/`pad`) or an Aeson
  `renderJson`, and a remote fetcher that maps HTTP failures to `Left Text`. Note the quirk:
  `renderRemoteSubscriptionStatus` *collapses* `Left err` into the returned text, so an
  unreachable worker prints `kiroku: could not reach ...` on stdout with exit code 0, and the
  test "reports an unreachable endpoint as a readable error, not an exception" pins that. The
  new commands must not inherit this.
- `Standalone.hs` owns the standalone binary's option type `newtype StandaloneOptions =
  StandaloneOptions { command :: KirokuCommand }`, `standaloneParserInfo`, and the pure
  `resolveStandaloneOptions :: [(String, String)] -> StandaloneOptions -> Either Text
  StandaloneRuntime`, which takes the process environment as an argument so it is testable,
  fills `--remote-url` from `KIROKU_REMOTE_URL`, and fails with an exact guidance string when
  neither is present. `runStandaloneCommand :: StandaloneRuntime -> IO Text` matches
  `KirokuCommand` exhaustively. Since `kiroku-cli` 0.2.0.0 the standalone binary has no database
  connectivity at all (`--database-url` was removed); it is a remote client of a worker's
  `kiroku-metrics` `/subscriptions` endpoint.
- `kiroku-cli/app/Main.hs` runs `execParser standaloneParserInfo`, `getEnvironment`,
  `resolveStandaloneOptions`; a `Left` prints to stderr and `exitFailure` (code 1); a `Right`
  runs the command under `try`, prints exceptions to stderr with exit 1, and prints output with
  exit 0.
- `kiroku-cli/test/Main.hs` is an hspec suite with seven `describe` groups: parser checks via
  `execParserPure defaultPrefs kirokuParserInfo [...]` and a local `renderedHelp :: ParserResult a
  -> String`; a fake host `data HostCommand = HostOnly | HostKiroku KirokuCommand` whose parser
  is `subparser (Options.command "host" ... <> kirokuSubparser HostKiroku)`; standalone
  resolution with explicit environments; codec round trips; `subscriptionStatusRows`; renderer
  golden strings; and one live group that uses `withTestStore` (defined locally as
  `Kiroku.Test.Postgres.withMigratedTestDatabase` plus `withStore (defaultConnectionSettings
  connStr)`), appends an event, subscribes, polls until `"live"`, and asserts the rendered table.

All packages share a `common common` stanza with `GHC2024`, the default extensions
`DeriveAnyClass DuplicateRecordFields OverloadedLabels OverloadedStrings`, and `-Wall
-Werror=incomplete-patterns`. That last flag is the safety net for this plan: adding a
constructor to `KirokuCommand` turns every unhandled `case` into a compile error, so the
exhaustive matches in `Run.hs` and `Standalone.hs` cannot be forgotten.

**Documentation layout.** User guides live in `docs/user/` with an index at
`docs/user/README.md` (the "Schema And Lifecycle" section lists `schema.md`,
`schema-migrations.md`, `lifecycle.md`, `history-retention.md`). `docs/user/lifecycle.md` has
sections "Soft Delete", "Undelete", "Hard Delete" (with "Event-Preservation Semantics",
"Authorization Model", "Auditing Hard Deletes"), "Close-the-Book Compaction" (the logical
`truncate_before` marker), "Choosing Soft vs. Hard" (a table), and "See Also".
`docs/user/observability.md` documents every `KirokuEvent` constructor.
`docs/user/schema-migrations.md` describes the migration plan (it currently says `0008` through
`0011` are native-only forward migrations). `docs/user/operator-cli.md` has sections "Standalone
Usage", "How Status Is Sourced", and "Embedding In A Host CLI". `docs/PRODUCTION-DEPLOYMENT.md`
lists runtime privileges (its bullet list starts "Privileges required at runtime by the
application user") and a "Hard-delete authorization" section. The repository `README.md` has a
"What It Provides" section.

**OKF bundles.** `docs/capabilities/` and `docs/adr/` are profile-governed Open Knowledge
Format bundles registered in `mori.dhall`. A capability is one Markdown file with YAML
frontmatter; `docs/capabilities/protected-replay-history.md` is the model:

```yaml
---
title: "Protected replay history"
type: Capability
description: "Protect long global rebuilds with durable renewable retention leases and short one-stream repairs with transaction-scoped history guards."
generated:
  by: openai/gpt-5
  at: "2026-08-13T21:59:54Z"
capabilityId: CAP-21
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.7.0.0"
packages:
  - kiroku-store
  - kiroku-store-migrations
interface:
  - Kiroku.Store.HistoryRetention
requires:
  - CAP-4
evidence:
  - kind: test
    resource: kiroku-store/test/Test/HistoryRetention.hs
    proves: Validated durable lease lifecycle, effect events, typed hard-delete conflicts, ...
---
```

Handles are allocated with `okf id next docs/capabilities --profile docs/capabilities/profile.dhall CAP`
(at planning time it printed `CAP-22`; re-run it, never count files). Existing related
capabilities are `CAP-8` (stream lifecycle, `docs/capabilities/stream-lifecycle.md`), `CAP-9`
(logical truncate-before, `docs/capabilities/logical-truncate-before.md`), and `CAP-21`
(protected replay history). The bundle keeps `index.md` (a bullet list, one line per concept)
and `log.md` (dated entries, newest first, written with `okf log add docs/capabilities ...`).
Validation is `just capabilities-validate` (runs `mori validate`, `okf validate docs/capabilities
--profile docs/capabilities/profile.dhall --profile-enforce --log-enforce`, and `okf graph`).
`just adr-validate` is the same for `docs/adr`. The improvement-request bundle
`docs/improvement-requests/` (OKF 0.1, no profile) holds
`add-manifest-driven-selective-event-compaction.md` (IR-14, `status: proposed`); its status
transitions are owned by the release plan
`docs/plans/80-release-the-compaction-cohort-and-prove-it-from-a-clean-external-consumer.md`,
not this one.

**Relevant ADRs.** [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) establishes
that deterministic structural assertions and a controlled workload benchmark are the
authoritative performance gates; this plan adds no store code, but its live CLI tests must not
weaken any gate and `just perf-check` must still pass before release.
[ADR-6](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md) explains
why database-native integration surfaces are frozen versioned relations; it is why this plan
documents the ledger as reachable through the Haskell API and CLI, not through a new SQL view.
[ADR-7](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md) defines
the history-retention leases, the coordinator lock, and the ascending-`stream_id` lock order that
compaction reuses; the user guide must tell operators that an active lease makes apply refuse
and that a held stream guard makes apply wait. The compaction-contract ADR created by
`docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md` is
the decision record this plan's prose must agree with; read it before writing the guide. The
consuming project is `mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`,
which remains blocked until the documented capability is released.


## Plan of Work

### Milestone 1 — Operator and user documentation

Goal: an operator who has never seen the code can understand what compaction does, what it
refuses, how it relates to the other lifecycle operations, and how to run it end to end.

Work. Create `docs/user/compaction.md` with these sections, in prose:

*What compaction is and is not.* Define selective physical deletion: removing the `events`
payload row and the home, `$all`, and explicitly acknowledged link rows in `stream_events` for a
reviewed set of originated events, leaving every retained event's ID, stream version, global
position, payload, metadata, causation and correlation IDs, and memberships unchanged, and
leaving every affected stream's `stream_version` high-water mark unchanged so expected-version
appends continue from the same number. Contrast it explicitly with the four things IR-14
acceptance item 8 names: logical truncate-before (`setStreamTruncateBefore`; hides events from
per-stream reads, deletes nothing, reversible, leaves `$all` complete), whole-stream hard delete
(`hardDeleteStream`; removes a whole stream, its events, and its links everywhere, irreversible),
reusable database space (a physical delete leaves dead tuples that autovacuum or `VACUUM` turns
into free space *inside* the relation files), and filesystem reclamation (`VACUUM FULL`,
`pg_repack`, or a restore, which rewrite relation files and return space to the operating
system; a separate maintenance window, never performed by Kiroku). State that reads skip gaps:
per-stream, category, and `$all` reads use exclusive cursors, so a removed version or position
is simply never returned, and subscription checkpoints keep moving forward.

*The consumer workflow.* Walk through: read the store identity with `storeIdentity`; gather
each candidate's memberships and references with `lookupEventReferences`; build a
`CompactionManifestInput` and call `mkCompactionManifest` (explain the mandatory stream-head
witnesses, `acknowledgedLinks`, `DeadLetterPolicy`, `CausationPolicy`, and
`maxCompactionSelections`); preview with `previewCompaction` and read every refusal or the
report; review the manifest digest and the report digest with a human; apply with
`applyCompaction`; confirm through `compactionLedger`. Say plainly that Kiroku never decides an
event is redundant — the consumer proves equivalence and archives envelopes before building a
manifest — and that preview and apply fail closed on any discrepancy.

*Manifest document.* Show the JSON wire format the library's `ToJSON`/`FromJSON` instances
produce. Read the exact key names from `kiroku-store/src/Kiroku/Store/Compaction/Types.hs`; the
shape is:

```json
{
  "format": "kiroku-compaction-manifest/1",
  "store_identity": "019900a1-7b3c-7d2e-9f00-0123456789ab",
  "operation": "mori/repository-ref-observed-dedup/v1",
  "dead_letter_policy": "refuse",
  "causation_policy": "refuse",
  "stream_heads": [
    { "stream": "repository-acme-2025-03-01", "head_version": 412 }
  ],
  "selections": [
    {
      "event_id": "0195f3a0-1c2d-7e4f-8a9b-0c1d2e3f4a5b",
      "origin_stream": "repository-acme-2025-03-01",
      "origin_version": 207,
      "global_position": 88213,
      "acknowledged_links": []
    }
  ],
  "digest": "3f7c1d…(64 lowercase hex characters)…"
}
```

Explain that `format` is required and fixed to `kiroku-compaction-manifest/1` (a document with
another value is rejected before anything else is read), that `digest` is the SHA-256 over the canonical encoding defined in the Haddock of
`Kiroku.Store.Compaction.Types.canonicalCompactionManifestBytes`, that a document whose digest
does not match its contents is rejected at decode time, and that selections are sorted by global
position and stream heads by name.

*Refusals.* Describe each `CompactionRefusal` constructor in a sentence of prose (store
identity mismatch; active history-retention lease; missing or soft-deleted stream; stream head
drift; selected event missing; witness mismatch; unexpected link; acknowledged link missing; dead
letters present; causation dependents present; ledger conflict) and what the operator does about
each. State that preview returns every refusal it can find, that apply re-validates under locks,
and that a refusal never changes a row.

*Leases and locks.* Say that apply refuses while any history-retention lease is active (the
same rule as hard delete), that it takes the coordinator lock first and then every affected
stream row in ascending internal ID order, that it waits for a held `lockStreamHistoryForReplayTx`
guard, and that concurrent appends to affected streams wait for apply and then continue from the
unchanged head. Link `history-retention.md`.

*Sizing and chunking.* `maxCompactionSelections` is 100,000; larger jobs are several manifests,
each one transaction, and stream-head witnesses stay valid across chunks because compaction never
changes `stream_version` — only an intervening append invalidates them, which is the point.

*Authorization.* Mirror the hard-delete model: apply sets `kiroku.enable_hard_deletes` for its
transaction, so the connecting role needs `DELETE` on `events`, `stream_events`, and (under
`RemoveDeadLetters`) `dead_letters`, plus `INSERT` on `event_compactions` and `SELECT, UPDATE` on
`history_retention_coordinator`; the GUC is an accident guard, not a security boundary. Point to
`docs/PRODUCTION-DEPLOYMENT.md`.

*Audit.* The ledger row is the durable evidence; `compactionLedger` reads it newest first; the
four `KirokuEvent` constructors (`KirokuEventCompactionPreviewed`, `KirokuEventCompactionRefused`,
`KirokuEventCompactionApplied`, `KirokuEventCompactionAlreadyApplied`) are process-local signals.
Link `observability.md`.

*Idempotence.* Reapplying an identical manifest returns `CompactionAlreadyApplied` with the
stored record and the same report digest; a manifest whose digest is in the ledger but whose
events partly survive is a `CompactionLedgerConflict`, which indicates a restore from a
pre-compaction backup and needs an operator decision.

Then update the neighbours. In `docs/user/lifecycle.md`, add a "Selective Physical Compaction"
paragraph after "Close-the-Book Compaction" that points to `compaction.md`, extend the
"Choosing" section with a sentence (or a third column) placing selective compaction between the
two existing options, and add a "See Also" link. In `docs/user/observability.md`, document the
four events with their fields and when they fire (after the transaction ends; refusals carry the
first refusal and the total count; payloads never appear). In `docs/user/schema-migrations.md`,
change `0008` through `0011` to `0008` through `0012`, describe migration `0012` (the
`kiroku.store_identity` singleton and the append-only `kiroku.event_compactions` ledger, both
protected by the existing mutation/deletion/truncation triggers), and note the schema comment
`Managed by pg-migrate component kiroku through 0012`. In `docs/user/README.md`, add a
"Selective Compaction" bullet to "Schema And Lifecycle". In `docs/PRODUCTION-DEPLOYMENT.md`, add
a privilege bullet for compaction and a short runbook paragraph ("Compaction runbook": rehearse
on a restored clone, which shares the store identity; confirm no lease is active; preview; record
the digest; apply; verify the ledger; schedule `VACUUM`). In `README.md` "What It Provides", add
one bullet for manifest-driven selective compaction.

Finally review Haddock. Open `kiroku-store/src/Kiroku/Store/Compaction.hs`,
`Compaction/Types.hs`, `Read.hs` (`storeIdentity`, `lookupEventReferences`), and
`Transaction.hs` (`storeIdentityTx`, `lookupEventReferencesTx`) and make sure the module and
function comments state the same four-way distinction, the lock order, the lease rule, and the
no-renumbering guarantee in the same words as the guide. Fix omissions in this plan's commits.

Result and proof: the files exist; `cabal haddock kiroku-store` builds without warnings about
the touched modules; a reviewer can answer "what happens to stream version 207 after compaction"
from the guide alone (it is gone from reads; version 208 keeps its number; the head stays 412).

### Milestone 2 — Capability record and bundle validation

Goal: the capability catalogue records selective compaction as a shipped-in-progress capability
backed by openable evidence, and both profiled bundles validate.

Work. Run `okf id next docs/capabilities --profile docs/capabilities/profile.dhall CAP` and use
the printed handle (expected `CAP-22`). Create `docs/capabilities/selective-event-compaction.md`
with frontmatter modelled on `protected-replay-history.md`: `title: "Selective event
compaction"`, `type: Capability`, a one-sentence `description`, `generated.by` naming the
authoring model and `generated.at` now, the allocated `capabilityId`, `provider:
mori://shinzui/kiroku`, `status: shipped`, `stability: experimental`, `since: "0.9.0.0"` (the
`kiroku-store` version the release plan will publish; the release plan corrects it if the number
changes), `packages: [kiroku-store, kiroku-store-migrations, kiroku-cli]`, `interface:
[Kiroku.Store.Compaction, Kiroku.Store.Compaction.Types, Kiroku.Store.Read,
Kiroku.Store.Transaction, Kiroku.Cli.Compaction]`, `requires: [CAP-8, CAP-9, CAP-21]`, and
`evidence` entries of `kind: test` for `kiroku-store/test/Test/StoreIdentity.hs`,
`kiroku-store/test/Test/EventReferences.hs`, `kiroku-store/test/Test/CompactionManifest.hs`,
`kiroku-store/test/Test/CompactionPreview.hs`, `kiroku-store/test/Test/CompactionApply.hs`,
`kiroku-store-migrations/test/Main.hs` (the `compaction schema` group), and
`kiroku-cli/test/Main.hs`, each with a `proves` sentence. (Confirm the exact test module names
against the working tree; the sibling plans name them, but the files are authoritative.) The
body has "Usage" (a short Haskell snippet calling `previewCompaction` then `applyCompaction`),
"Limits" (never renumbers, refuses rather than widens, one transaction per manifest of at most
100,000 selections, embeddable-only CLI, space is reusable not reclaimed), and a paragraph
noting that the store identity and the event reference inventory are delivered as parts of this
capability. Add the bullet to `docs/capabilities/index.md` (same format as the others) and
record the addition with `okf log add docs/capabilities --entry "**Addition**: CAP-NN records
manifest-driven selective event compaction ..."` (check `okf log add --help` for the exact flag
names; the existing `log.md` entries are the target shape). Run `just capabilities-validate` and
`just adr-validate`.

Result and proof: both commands exit 0 and `okf graph docs/capabilities` includes the new node
with its three `requires` edges.

### Milestone 3 — Embeddable compaction and store commands

Goal: a host that embeds `kirokuSubparser` gains `kiroku compaction preview|apply|ledger` and
`kiroku store identity`, each with table and JSON output and a meaningful exit code; the
standalone binary refuses them with guidance.

Work, file by file.

`kiroku-cli/src/Kiroku/Cli/Command.hs`: extend the tree.

```haskell
data KirokuCommand
    = KirokuNoCommand
    | KirokuSubscriptions SubscriptionCommand
    | KirokuCompaction CompactionCommand
    | KirokuStore StoreCommand
    deriving stock (Eq, Show)

data CompactionCommand
    = CompactionPreview CompactionOptions
    | CompactionApply ApplyOptions
    | CompactionLedger LedgerOptions
    deriving stock (Eq, Show)

data StoreCommand
    = StoreIdentity IdentityOptions
    deriving stock (Eq, Show)

newtype ManifestPath = ManifestPath FilePath
    deriving stock (Eq, Show)

data CompactionOptions = CompactionOptions
    { manifestPath :: !ManifestPath
    , outputFormat :: !OutputFormat
    }
    deriving stock (Eq, Show)

data ApplyOptions = ApplyOptions
    { manifestPath :: !ManifestPath
    , confirmDigest :: !Text        -- lowercase hex as typed; parsed in Kiroku.Cli.Compaction
    , outputFormat :: !OutputFormat
    }
    deriving stock (Eq, Show)

data LedgerOptions = LedgerOptions
    { limit :: !Int32              -- default 50; validated 1..1000 at run time
    , outputFormat :: !OutputFormat
    }
    deriving stock (Eq, Show)

newtype IdentityOptions = IdentityOptions
    { outputFormat :: OutputFormat
    }
    deriving stock (Eq, Show)
```

Export every new type with `(..)`. `DuplicateRecordFields` is on, so repeated `outputFormat`
fields are legal; construct and match positionally or with `OverloadedLabels` lenses as the
existing code does.

`kiroku-cli/src/Kiroku/Cli/Parser.hs`: inside `kirokuCommandParser`'s `subparser`, append
`<> command "compaction" (info (KirokuCompaction <$> compactionCommandParser) (fullDesc <>
progDesc "Preview, apply, or audit manifest-driven selective event compaction."))` and `<>
command "store" (info (KirokuStore <$> storeCommandParser) (fullDesc <> progDesc "Inspect this
store's identity."))`. Write `compactionCommandParser` as a `subparser` with three commands
(`preview`, `apply`, `ledger`), each `<**> helper`, and `storeCommandParser` with `identity`.
Option parsers: `--manifest FILE` is `ManifestPath <$> strOption (long "manifest" <> metavar
"FILE" <> help "Path to a compaction manifest JSON document produced by the consuming project.")`;
`--format` reuses the existing `parseOutputFormat` reader and default; `--confirm-digest HEX` is
`T.pack <$> strOption (long "confirm-digest" <> metavar "HEX" <> help "The manifest digest shown
by preview; apply refuses unless it matches the manifest file.")`; `--limit N` is `option auto
(long "limit" <> metavar "N" <> value 50 <> help "Newest ledger records to show (1..1000).")`.
`kirokuParserInfo` and `kirokuSubparser` need no change.

New `kiroku-cli/src/Kiroku/Cli/Compaction.hs` (add to `exposed-modules`):

```haskell
module Kiroku.Cli.Compaction (
    loadCompactionManifest,
    CompactionCommandError (..),
    renderCompactionReport,
    renderCompactionRefusals,
    renderCompactionRecords,
    renderStoreIdentity,
    renderCompactionCommandError,
) where
```

`loadCompactionManifest :: ManifestPath -> IO (Either CompactionCommandError CompactionManifest)`
reads the file with `Data.ByteString.readFile`, decodes with `Data.Aeson.eitherDecodeStrict`,
and maps failures to `ManifestUnreadable FilePath Text` (I/O) or `ManifestInvalid FilePath Text`
(decode or digest mismatch; the library's `FromJSON` already includes the digest check).
`CompactionCommandError` also has `ConfirmDigestMismatch { typed :: Text, manifest :: Text }`,
`ConfirmDigestUnparseable Text`, `LedgerLimitOutOfRange Int32`, and `StoreFailure StoreError`.
Renderers follow `Subscription/Status.hs`: each takes an `OutputFormat`; the table forms are
padded columns with upper-case headers. `renderCompactionReport` prints a key/value table
(`MANIFEST_DIGEST`, `STORE_IDENTITY`, `OPERATION`, `DEAD_LETTER_POLICY`, `CAUSATION_POLICY`,
`SELECTED_EVENTS`, `HOME_MEMBERSHIPS`, `GLOBAL_MEMBERSHIPS`, `LINK_MEMBERSHIPS`,
`DEAD_LETTERS_REMOVED`, `CAUSATION_DEPENDENTS`, `LOWEST_GLOBAL_POSITION`,
`HIGHEST_GLOBAL_POSITION`, `REPORT_DIGEST`) followed by an `AFFECTED_STREAMS` table
(`STREAM  HEAD_VERSION`); JSON is the library's `ToJSON CompactionReport`.
`renderCompactionRefusals :: OutputFormat -> NonEmpty CompactionRefusal -> Text` prints one
line per refusal in table mode (`KIND  EVENT_ID  STREAM  DETAIL`) and the library's JSON array
otherwise; it is prefixed by a line `refused: N refusal(s); no rows were changed`.
`renderCompactionRecords :: OutputFormat -> Vector CompactionRecord -> Text` prints
`COMPACTION_ID  APPLIED_AT  APPLIED_BY  OPERATION  SELECTED_EVENTS  MANIFEST_DIGEST`.
`renderStoreIdentity` prints the UUID (table mode: `STORE_IDENTITY` header and one row; JSON:
`{"store_identity": "..."}`). For an apply, prefix the report with `applied: <compaction id> at
<applied_at> by <applied_by>` or `already applied: <compaction id> ...`.

`kiroku-cli/src/Kiroku/Cli/Run.hs`: add

```haskell
data KirokuCommandOutcome = KirokuCommandOutcome
    { output :: !Text
    , exitCode :: !ExitCode
    }
    deriving stock (Eq, Show)

executeKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO KirokuCommandOutcome
```

Its arms: `KirokuNoCommand` and `KirokuSubscriptions` delegate to the existing rendering and
return `ExitSuccess` (preserving today's behaviour, quirk included). `KirokuCompaction
(CompactionPreview opts)`: load the manifest (error → `ExitFailure 1` with the rendered error);
`runStoreIO store (previewCompaction manifest)`; `Left storeErr` → `ExitFailure 1`; `Right (Left
refusals)` → rendered refusals and `ExitFailure 2`; `Right (Right report)` → rendered report and
`ExitSuccess`. `CompactionApply opts`: load; `parseCompactionDigestHex confirmDigest`
(unparseable → `ExitFailure 1`); compare with `manifestDigest manifest` (mismatch → rendered
`ConfirmDigestMismatch`, `ExitFailure 2`, and **no database call**); then `applyCompaction` with
the same mapping, where both `CompactionAppliedNow` and `CompactionAlreadyApplied` are
`ExitSuccess`. `CompactionLedger opts`: `mkCompactionLedgerLimit limit` (out of range →
`ExitFailure 1`), `compactionLedger (CompactionLedgerQuery validated)`, `ExitSuccess`.
`KirokuStore (StoreIdentity opts)`: `storeIdentity`, `ExitSuccess`. Then redefine
`renderKirokuCommandWithStore store cmd = (.output) <$> executeKirokuCommandWithStore store cmd`
(keeping its exported type) and `runKirokuCommandWithStore store cmd = do outcome <- execute...;
TIO.putStrLn outcome.output; when (outcome.exitCode /= ExitSuccess) (exitWith outcome.exitCode)`.
Update `runKirokuCommand` with guidance arms for the two new constructors ("This command needs a
live KirokuStore ..."). Export `KirokuCommandOutcome (..)` and `executeKirokuCommandWithStore`.

`kiroku-cli/src/Kiroku/Cli/Standalone.hs`: in `resolveStandaloneOptions`, add arms
`KirokuCompaction _ -> Left embeddableOnlyMessage` and `KirokuStore _ -> Left
embeddableOnlyMessage` where `embeddableOnlyMessage = "kiroku: compaction and store identity
commands run only inside a host that owns a KirokuStore; the standalone binary is a remote
client"`. In `runStandaloneCommand`, add arms for both constructors that return the same text
(unreachable after resolution, like the existing `Nothing` endpoint arm). Update the
`progDesc` to mention that compaction is embeddable-only. `kiroku-cli/app/Main.hs` needs no
change: a `Left` already exits 1.

`kiroku-cli/kiroku-cli.cabal`: add `Kiroku.Cli.Compaction` to `exposed-modules`; add `vector`
and `time` to the library `build-depends` if the renderers need them (check `cabal build` for
"could not find module"); keep `kiroku-store ^>=0.8` for now — the release plan moves every
bound.

`kiroku-cli/CHANGELOG.md`: add an `## Unreleased` section describing the new commands, the
`KirokuCommand` constructors (a breaking change for exhaustive matches), `KirokuCommandOutcome`,
and the standalone refusal. `docs/user/operator-cli.md`: add a "Compaction And Store Identity"
section with example invocations, the exit-code contract (0 success or already applied, 1
usage/store error, 2 refusal), and a note that these commands are unavailable in the standalone
binary and why.

Result and proof: `cabal build all` succeeds; `cabal run kiroku -- compaction preview --manifest
/dev/null` prints the embeddable-only guidance on stderr and exits 1; the host-embedding test
below parses `host kiroku compaction apply --manifest m.json --confirm-digest ab12`.

### Milestone 4 — Tests and full verification

Goal: every new parser path, renderer, exit code, and live command is covered, and the whole
repository still builds, tests, formats, and validates.

Work, in `kiroku-cli/test/Main.hs`. Add to `describe "kirokuParserInfo"`: examples parsing
`["compaction","preview","--manifest","m.json"]` to `KirokuCompaction (CompactionPreview
(CompactionOptions (ManifestPath "m.json") OutputTable))`, `["compaction","apply","--manifest",
"m.json","--confirm-digest","ab12","--format","json"]`, `["compaction","ledger"]` (limit 50) and
`["compaction","ledger","--limit","5"]`, `["store","identity"]`, and that `["compaction",
"apply","--manifest","m.json"]` without `--confirm-digest` fails to parse. Add to
`describe "kirokuSubparser"`: `["host","kiroku","compaction","preview","--manifest","m.json"]`.
Add to `describe "standaloneParserInfo (remote client)"`: `resolveStandaloneOptions []` of a
compaction command and of a store command each returns `Left` with the exact guidance text. Add
`describe "Kiroku.Cli.Compaction"`: `loadCompactionManifest` on a missing file returns
`ManifestUnreadable`; on a JSON document whose `digest` is altered returns `ManifestInvalid`
whose message mentions the digest; renderer golden strings for an empty ledger (`COMPACTION_ID
APPLIED_AT  APPLIED_BY  OPERATION  SELECTED_EVENTS  MANIFEST_DIGEST` header only), a one-refusal
table, and the store identity in both formats. Add `describe "executeKirokuCommandWithStore"`
using the local `withTestStore`: seed a stream with three events through `appendToStream`, read
the store identity with `storeIdentity`, build a manifest selecting the middle event with
`mkCompactionManifest` (stream head witness 3, no links, refuse policies), encode it to a temp
file with `Data.Aeson.encodeFile` (use `System.IO.Temp.withSystemTempDirectory` — add
`temporary` to the test `build-depends`), then assert: `store identity` outputs the UUID with
`ExitSuccess`; `compaction preview` returns `ExitSuccess` and a report with `SELECTED_EVENTS  1`;
a manifest with a wrong head witness previews to `ExitFailure 2` and output containing
`CompactionStreamHeadDrift`; `compaction apply` with the wrong `--confirm-digest` returns
`ExitFailure 2` and `countEvents` unchanged; `compaction apply` with the right digest returns
`ExitSuccess`, output starting `applied:`, and `countEvents` decreased by one; a second identical
`apply` returns `ExitSuccess` with output starting `already applied:` and the same compaction id;
`compaction ledger` lists one record; `--format json` outputs decode with `Data.Aeson.decode`.
The test needs `countEvents`, which `kiroku-cli/test/Main.hs` does not have — copy the two-line
helper from `kiroku-store/test/Test/Helpers.hs` (`Pool.use` of `SELECT count(*) FROM events`)
or add a local statement.

Then run the full verification listed in Concrete Steps and commit.

Result and proof: `cabal test kiroku-cli:kiroku-cli-test` reports the new examples passing;
`cabal test all` is green; `nix fmt` changes nothing; `nix flake check` passes.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

Before starting, confirm the prerequisites exist:

```bash
grep -n "previewCompaction\|applyCompaction\|compactionLedger" kiroku-store/src/Kiroku/Store/Compaction.hs
grep -n "storeIdentity\|lookupEventReferences" kiroku-store/src/Kiroku/Store/Read.hs
ls kiroku-store/test/Test/ | grep -i "compaction\|storeidentity\|eventreferences"
```

Milestone 1:

```bash
$EDITOR docs/user/compaction.md docs/user/lifecycle.md docs/user/observability.md \
  docs/user/schema-migrations.md docs/user/README.md docs/PRODUCTION-DEPLOYMENT.md README.md
cabal haddock kiroku-store 2>&1 | grep -i "compaction\|warning" | head
git add -A docs README.md kiroku-store/src
git commit -m "docs(compaction): add the selective compaction operator guide" \
  -m "Explain selective physical deletion against logical truncate-before, whole-stream hard delete, reusable space, and filesystem reclamation; document the manifest workflow, refusals, leases, chunking, grants, and audit." \
  -m "MasterPlan: docs/masterplans/11-manifest-driven-selective-event-compaction.md" \
  -m "ExecPlan: docs/plans/79-document-compaction-for-operators-and-add-embeddable-kiroku-cli-compaction-commands.md" \
  -m "Intention: intention_01m0mwdmnfex3tv9fg0t57htfv"
```

Milestone 2:

```bash
okf id next docs/capabilities --profile docs/capabilities/profile.dhall CAP
$EDITOR docs/capabilities/selective-event-compaction.md docs/capabilities/index.md
okf log add --help
okf log add docs/capabilities ...   # per the printed usage; entry text: "**Addition**: CAP-22 records manifest-driven selective event compaction with its store identity and reference inventory."
just capabilities-validate
just adr-validate
```

Expected tail of `just capabilities-validate`:

```text
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
OK: 23 concepts validated
```

(The exact count is one more than before; the wording is whatever the installed `okf` prints —
the requirement is exit status 0.)

Milestone 3:

```bash
$EDITOR kiroku-cli/src/Kiroku/Cli/Command.hs kiroku-cli/src/Kiroku/Cli/Parser.hs \
  kiroku-cli/src/Kiroku/Cli/Compaction.hs kiroku-cli/src/Kiroku/Cli/Run.hs \
  kiroku-cli/src/Kiroku/Cli/Standalone.hs kiroku-cli/kiroku-cli.cabal \
  kiroku-cli/CHANGELOG.md docs/user/operator-cli.md
cabal build kiroku-cli
cabal run kiroku -- compaction preview --manifest /dev/null; echo "exit=$?"
```

Expected:

```text
kiroku: compaction and store identity commands run only inside a host that owns a KirokuStore; the standalone binary is a remote client
exit=1
```

Milestone 4:

```bash
$EDITOR kiroku-cli/test/Main.hs kiroku-cli/kiroku-cli.cabal
cabal test kiroku-cli:kiroku-cli-test --test-show-details=direct
cabal build all
cabal test all
nix fmt
git status --short   # must be empty after nix fmt
nix flake check
just capabilities-validate && just adr-validate
```

Expected from the CLI suite (abbreviated):

```text
executeKirokuCommandWithStore
  prints the store identity
  previews a valid manifest with exit 0
  refuses a drifted stream head with exit 2 and changes nothing
  refuses a mismatched --confirm-digest before touching the store
  applies a confirmed manifest and removes exactly the selected event
  reports an identical reapply as already applied with exit 0
  lists the ledger newest first
Finished in 4.1 seconds
NN examples, 0 failures
```

Commit each milestone. Example message:

```text
feat(cli): add embeddable compaction preview, apply, ledger, and store identity commands

Extend KirokuCommand with compaction and store subtrees, decode manifests through
the library codec, require --confirm-digest for apply, and return typed exit
codes through executeKirokuCommandWithStore. The standalone binary refuses these
commands with guidance because it owns no store.

MasterPlan: docs/masterplans/11-manifest-driven-selective-event-compaction.md
ExecPlan: docs/plans/79-document-compaction-for-operators-and-add-embeddable-kiroku-cli-compaction-commands.md
Intention: intention_01m0mwdmnfex3tv9fg0t57htfv
```


## Validation and Acceptance

Acceptance is behaviour an operator can observe.

Documentation: reading `docs/user/compaction.md` alone, a reader can state that after compacting
version 207 of a stream whose head is 412, `readStreamForward` returns 206 then 208, `getStream`
still reports version 412, `appendToStream name (ExactVersion 412)` succeeds and lands at 413,
and disk space is not returned to the operating system until a `VACUUM FULL` or equivalent. The
guide names every `CompactionRefusal` constructor. `docs/user/observability.md` names all four
compaction events. `docs/user/schema-migrations.md` names migration `0012` and its two tables.

Catalogue: `just capabilities-validate` and `just adr-validate` exit 0; the new capability file
carries the handle printed by `okf id next`, `requires` `CAP-8`, `CAP-9`, and `CAP-21`, and
every `evidence.resource` path exists (`for f in $(grep resource: docs/capabilities/selective-event-compaction.md | awk '{print $2}'); do test -e "$f" || echo "missing $f"; done` prints nothing).

CLI, inside a host: `executeKirokuCommandWithStore store (KirokuCompaction (CompactionPreview
(CompactionOptions (ManifestPath "m.json") OutputTable)))` on a valid manifest returns
`exitCode == ExitSuccess` and output containing `SELECTED_EVENTS`; on a manifest whose stream
head witness is stale returns `ExitFailure 2` and output containing the refusal name; apply with
a wrong `--confirm-digest` returns `ExitFailure 2` and performs no database call (the test
asserts `countEvents` unchanged and, optionally, zero pool checkouts through an
`observationHandler`); apply with the right digest removes exactly the selected events; a
repeated apply reports `already applied:` with the same compaction id; `compaction ledger`
lists it; `store identity` prints the same UUID `storeIdentity` returns. `--format json` output
for every command decodes as JSON.

CLI, standalone: `cabal run kiroku -- compaction ledger` and `cabal run kiroku -- store identity`
print the embeddable-only guidance on stderr and exit 1; `cabal run kiroku -- subscriptions
status --remote-url http://127.0.0.1:1` still behaves as before (readable error, exit 0), proving
the old contract is untouched.

Repository: `cabal build all`, `cabal test all`, `nix fmt` (no diff), and `nix flake check` all
succeed.


## Idempotence and Recovery

Every step in this plan is additive and repeatable. Re-running the documentation edits is a
no-op once the text is in place. `okf id next` is read-only; if a handle was already allocated
in a previous attempt (the file exists with `capabilityId: CAP-NN`), keep it — never renumber.
`okf log add` appends; if an entry was already written, do not add a duplicate. The CLI changes
are compile-guarded by `-Werror=incomplete-patterns`; a half-finished edit fails to build rather
than misbehaving. Live tests use `withMigratedTestDatabase`, which creates and drops a fresh
database per example from a shared template, so a failed run leaves nothing behind. No step in
this plan touches a persistent database or publishes anything; the release is
`docs/plans/80-release-the-compaction-cohort-and-prove-it-from-a-clean-external-consumer.md`.
If `nix flake check` fails on formatting, run `nix fmt` and commit the result. If `okf validate`
fails on the capability frontmatter, compare field by field with
`docs/capabilities/protected-replay-history.md`; the profile descriptor
`docs/capabilities/profile.dhall` is authoritative.


## Interfaces and Dependencies

Libraries: `optparse-applicative >=0.19 && <0.20` (already a dependency), `aeson` (already),
`vector` and `time` (add to `kiroku-cli` library `build-depends` if needed for `Vector
CompactionRecord` and `UTCTime` rendering), `temporary` (test suite only, for manifest files),
`kiroku-test-support` (already in the test suite). The `kiroku-store` bound stays `^>=0.8` in
this plan; the release plan raises it together with the version.

Signatures that must exist at the end of Milestone 3:

```haskell
-- Kiroku.Cli.Command
data KirokuCommand = KirokuNoCommand | KirokuSubscriptions SubscriptionCommand
                   | KirokuCompaction CompactionCommand | KirokuStore StoreCommand
data CompactionCommand = CompactionPreview CompactionOptions | CompactionApply ApplyOptions | CompactionLedger LedgerOptions
data StoreCommand = StoreIdentity IdentityOptions
newtype ManifestPath = ManifestPath FilePath
data CompactionOptions = CompactionOptions { manifestPath :: !ManifestPath, outputFormat :: !OutputFormat }
data ApplyOptions = ApplyOptions { manifestPath :: !ManifestPath, confirmDigest :: !Text, outputFormat :: !OutputFormat }
data LedgerOptions = LedgerOptions { limit :: !Int32, outputFormat :: !OutputFormat }
newtype IdentityOptions = IdentityOptions { outputFormat :: OutputFormat }

-- Kiroku.Cli.Parser (unchanged exports; kirokuCommandParser now parses the new subtrees)
kirokuCommandParser :: Parser KirokuCommand
kirokuParserInfo :: ParserInfo KirokuCommand
kirokuSubparser :: (KirokuCommand -> command) -> Mod CommandFields command

-- Kiroku.Cli.Compaction
data CompactionCommandError
    = ManifestUnreadable FilePath Text
    | ManifestInvalid FilePath Text
    | ConfirmDigestUnparseable Text
    | ConfirmDigestMismatch { typed :: Text, manifest :: Text }
    | LedgerLimitOutOfRange Int32
    | StoreFailure StoreError
loadCompactionManifest :: ManifestPath -> IO (Either CompactionCommandError CompactionManifest)
renderCompactionReport :: OutputFormat -> Maybe CompactionRecord -> CompactionReport -> Text
renderCompactionRefusals :: OutputFormat -> NonEmpty CompactionRefusal -> Text
renderCompactionRecords :: OutputFormat -> Vector CompactionRecord -> Text
renderStoreIdentity :: OutputFormat -> StoreIdentity -> Text
renderCompactionCommandError :: OutputFormat -> CompactionCommandError -> Text

-- Kiroku.Cli.Run
data KirokuCommandOutcome = KirokuCommandOutcome { output :: !Text, exitCode :: !ExitCode }
executeKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO KirokuCommandOutcome
renderKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO Text   -- unchanged type
runKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO ()        -- exits non-zero on failure
runKirokuCommand :: KirokuCommand -> IO ()

-- Kiroku.Cli.Standalone
resolveStandaloneOptions :: [(String, String)] -> StandaloneOptions -> Either Text StandaloneRuntime
    -- KirokuCompaction and KirokuStore commands yield Left with the embeddable-only guidance
```

Exit-code contract: `ExitSuccess` for a rendered report, an applied or already-applied
manifest, a ledger listing, or a store identity; `ExitFailure 2` for any compaction refusal
(including a `--confirm-digest` mismatch); `ExitFailure 1` for unreadable or invalid manifest
files, an unparseable digest, an out-of-range ledger limit, or a `StoreError`.

Consumed from `kiroku-store`: `Kiroku.Store.Compaction` (`previewCompaction`,
`applyCompaction`, `compactionLedger`, and the re-exported `Kiroku.Store.Compaction.Types`),
`Kiroku.Store.Read.storeIdentity`, `Kiroku.Store.Effect.runStoreIO`, `Kiroku.Store.Error.StoreError`.
