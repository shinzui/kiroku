---
id: 54
slug: add-prefix-matching-subscription-target-for-fan-in-subscriptions
title: "Add prefix-matching subscription target for fan-in subscriptions"
kind: exec-plan
created_at: 2026-06-03T14:43:06Z
intention: "intention_01kt6yyawwewj80gv5q9qt5m0f"
provenance:
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T19:19:06Z
      mode: "discuss"
      note: "Record shared prefix/browse physical design and cumulative append-cost constraint; no index authorized."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T23:28:20Z
      mode: "implement"
      note: "Prototype shared browse access and bounded namespace windows; final ordering and layout remain under review."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-26T14:13:28Z
      mode: "update"
      note: "Refresh current schema and subscription lifecycle; plan bounded namespace windows, selective wakeups, safe scan checkpoints, and focused cumulative performance validation."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-26T16:08:29Z
      mode: "implement"
      note: "Implement namespace target, bounded scan checkpoints, selective wake routing, and acceptance tests."
---

# Add prefix-matching subscription target for fan-in subscriptions

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current. The 2026-10-26 revision
replaces the obsolete implementation instructions; historical measurements below
retain their original scope and uncertainty.

## Purpose / Big Picture


Allow one subscription to follow a family of categories, including categories
created after the subscription starts. A category is the part of a stream name
before its first hyphen: `pm:fulfillment-1` and `pm:billing-1` have different
categories, so neither existing exact `Category` target covers both.

Use the previously recommended namespace semantics consistently in this plan:
`CategoryNamespace "pm"` matches category `pm` and categories beginning with the
literal `pm:`. It does not match `pmm`, `orders`, or `pmish`. Nested namespaces
work the same way. Keep the existing exact `Category` and `AllStreams` semantics.
This is a category namespace, not an arbitrary stream-name prefix; callers pass
`"pm"`, not `"pm:"`. The title and filename retain the original plan identity.

Reduce performance impact through three concrete changes to the earlier design:
read bounded windows from the existing global event index instead of probing every
stream in the family; fetch event payloads only for matching rows; and wake live
workers on their namespace rather than every global append. Add no event/stream
index, append column, append trigger, or publisher decode work. A small forward
migration is still required to allow the new durable subscription target kind.

A test will append to `pm-1`, `pm:fulfillment-1`, `pm:billing-1`, and `orders-1`,
then prove the namespace subscription delivers precisely the first three in
global order during catch-up and continues to include newly created categories
in live operation. Consumer groups partition the same target without overlap.

The 2026-10-26 implementation request authorizes production implementation and
validation of this plan. The implementation scope is `kiroku-store`, its migration and test packages, and
relevant user/adapter documentation. A public one-shot namespace read API is
optional follow-up, not part of the required delivery.

## Progress


- [x] (2026-10-10) Shared access research retained: 224 disposable SQL checks
  passed, including 48 bounded namespace-window cases. These prove query
  behavior, not subscription delivery or active-feature performance.
- [x] (2026-10-11, reconciled 2026-10-26) Browsing order/layout settled in ADR-17:
  migration 0015 installs the shared browse-name index. Its inspection cohort
  received explicit practical acceptance; it does not certify this feature.
- [x] (2026-10-26) Refresh against current source and ADRs; select namespace
  semantics, bounded global windows and selective wakeups as the implementation
  direction. Remove obsolete index installation and two-match-site instructions.
- [x] (2026-10-26) M1: Namespace workers use bounded windows, completed scan
  frontiers and distinct bindings. Catch-up/live/restart and grouped paths pass;
  migration 0016 fresh apply, upgrade from 0015 and rerun pass on PG 17/18.
- [x] (2026-10-26) M2: Reference-counted selective wakes pass plain/grouped
  delivery, snapshot/drain race, lost-notification safety tick, listener/worker
  reconnect, failed-startup and idempotent final-release tests.
- [ ] M3: Correctness/topology and 96 production query-plan cases pass; the
  focused cumulative performance comparison remains blocked by incompatible
  deployed cell/client schemas (FRIC-8). Zero remote trials or pairs executed.
- [x] (2026-10-26) M4: User/schema/adapter documentation, changelogs and ADR-4/17
  record semantics, cutover, downgrade limits and scan/wake contracts. Retained
  evidence classifies functional/structural completion separately from blocked
  performance acceptance; no package version or release verdict was invented.

The original M0–M5 breakdown is superseded by these four verifiable milestones.
The namespace constructor, worker, wake registry and migration 0016 are
implemented. The focused Hspec group passes 26 examples, including 96 production
EXPLAIN cases. The full PG18 store suite passes 522 examples and the adapter suite
passes 45 examples; migrations pass 25 examples on both PG17 and PG18. Performance
comparison stopped before upload on the cell descriptor/client mismatch. Its
[report](../../kiroku-store/bench/results/ep54-namespace/README.md) retains the
single budget, zero executed/verified trials, cleanup and exact remaining work. The optional old M3 `readPrefix` combinator is deferred because a
vector-only result cannot express an empty but non-exhausted scan window.

## Surprises & Discoveries


2026-10-26 implementation: custom plans near the tail could choose the partial
category index and sort metadata before LIMIT; ordinary payload joins could also
choose a full events scan. The production statement selects the integral range
`0 <= stream_id < 1` and orders both global index keys before LIMIT, making the
partial category index ineligible without changing the selected rows. A
parameterized per-event LATERAL probe with `OFFSET 0` keeps payload work behind
matching, including in generic plans. These are per-event probes, not the rejected
per-stream discovery strategy. All 96 custom/generic cases at 1,000/20,000 rows,
W=32/1024, dense/sparse/absent matches, beginning/tail cursors and plain/groups pass.
Materialize bounded matching payloads before adding the empty-result sentinel,
so empty windows invoke zero payload-probe loops (rather than a zero-I/O NULL
probe). The shared scan state is allocated only for namespace workers. Old targets retain
their read statements and publisher decode path.

The remote proof could not reach execution: the client built from the registered
`mori://shinzui/load-testing-infra` source rejects the deployed descriptor's
`instances.broker` field before any submission upload (FRIC-8). The journal's
failed row records a client-side submission intent, not an interrupted measured
sample. The controller released its lease and removed its template; an explicit
final check verified all four instances stopped and the temporary SSH identity
revoked. No performance comparison was launched or accepted. Do not bypass the
descriptor contract or restart this experiment's clock to obtain a verdict.

The 2026-10-26 source audit found that `kiroku-store/kiroku-store.cabal` already
sets `-Wall -Werror=incomplete-patterns`. Adding that flag is no longer work.
`kiroku-store/src/Kiroku/Store/Subscription.hs` now selects a `LiveSource` at
registration, and exact-category consumer-group members also use category NOTIFY
wakes. `Worker.hs` dispatches on `LiveSource`, rather than the old two-site target
match described in the June draft. Target encoding, decoding and checkpoint-save
dispatch in `Subscription/Checkpoint/SQL.hs` also need new arms. The decoder's
fallback to unbound is particularly important: the compiler will not flag a new
kind swallowed by that fallback.

Category reads no longer enumerate `streams`. Migration 0012 stores category on
`stream_events` rows for `$all`, and `SQL.hs` reads exact categories through
`ix_stream_events_all_by_category`. Migration 0015 already installs
`ix_streams_browse_name`; migration 0005 already tunes `streams` fillfactor.
The old claims of three catalog indexes, default fillfactor 100 and a necessary
new `text_pattern_ops` index are obsolete. The actual migration directory is
`kiroku-store-migrations/migrations`, with a native manifest, not timestamped
files in `sql-migrations` or a new Codd migration.

Migration 0014 restricts `subscriptions.target_kind` to `unbound`, `all`, and
`category`, and permits a non-null `target_category` only for `category`.
Consequently the feature requires a forward constraint migration even though
its reads need no additional index. Persisting a namespace as an ordinary
category would silently change checkpoint identity and is forbidden.

The existing worker interprets an empty fetched batch as caught-up. Its delivery
primitive calls `V.last` on a nonempty batch and checkpoints the last event;
neither behavior can consume an empty namespace window safely. `Stop` is an
explicit disposition that checkpoints the stopping event in today's code;
it must not checkpoint the rest of a prefetched window. Unhandled decode failure
must leave durable progress before that event. These are implementation
requirements, not properties proven by the SQL prototype.

Retained research: the [shared-access report](../../kiroku-store/bench/results/mp13-ep3-shared-access/README.md)
contains 176 browse and 48 namespace checks. Namespace diagnostics used windows
of 32 and observed at most 38 examined rows / 9 buffers. Earlier generic-plan
failures and a fixture repair remain retained. Its statements about a pending
browse-order decision are historical; ADR-17 records the later selection.
The prototype selects positions/category/source IDs, not production event
payloads, and its limits cannot be reused as a full payload-query buffer budget.

The [replacement-index report](../../bench/mp13-index/evidence/2026-10-10/README.md)
measured fresh throughput -0.677% (95% interval -2.687% to +1.374%) and descriptive
WAL/event +2.43%. Observer results were exploratory. The
[selected browse-index report](../../bench/mp13-index/evidence/2026-10-10-byte-name/README.md)
retains five pairs per workload: fresh throughput -2.980% [-6.128%, +0.274%] and
existing appends with category subscription/browsing -1.722% [-4.631%, +1.276%].
WAL/event rose 5.668% and 0.187%; the index added 3.180 MiB on 40,000 streams.
The zero-slowdown statistical verdicts remained inconclusive. Later explicit
inspection-cohort acceptance is recorded in ADR-15/17; it grants this feature
no independent regression allowance. All historical owned clusters were reported
stopped. No experiment was launched for this refresh.

## Decision Log


2026-10-26 — Adopt the earlier recommended `CategoryNamespace !Text` semantics
for this implementation plan: literal category equality or literal prefix
`namespace <> ":"`. This resolves the old alternating `CategoryPrefix`,
`StreamNamePrefix` and namespace examples. Do not trim, normalize Unicode, strip
colons, or case-fold. `%`, `_`, backslashes and commas are literal characters.
Empty namespace matches empty category and categories beginning with `:`; it
never means all categories. A namespace containing a hyphen has no matches under
the category extraction rule. A trailing colon is literal: `"pm:"` matches
`pm:` and descendants beginning `pm::`. These choices keep the value total
without a new invalid-configuration exception. Document them and test them.

2026-10-26 — Use the ADR-17 bounded-window direction for both catch-up and live.
The global log already stores the category, so enumerate at most W global rows
first, then filter by namespace and group, then join only survivors to `events`.
Use `starts_with` on this bounded set, avoiding LIKE escaping and prefix indexes.
Keep the existing exact-category statements and specialized paths intact. Reject
the old per-stream LATERAL plan and an unrestricted global scan with a LIMIT
applied only after matching: both have unbounded work for sparse/no matches.

2026-10-26 — Introduce explicit scan progress. A frontier is a global position
through which every applicable event has been resolved. It can move past unrelated
rows but not past an unresolved matching event. Do not infer exhaustion from an
empty vector, use notification versions as global positions, or advance to the
publisher position without scanning. Preserve existing at-least-once delivery:
a checkpoint-save failure may cause replay, never a skip.

2026-10-26 — Add namespace wake registration as the second milestone, using the
existing NOTIFY payload and safety-poll model. Generate only the notified
category's colon ancestors and exact category, and look up active namespaces;
do not scan every registered namespace or retain every historical category in
a second unbounded map. No namespace registrations means no namespace parsing,
ancestor generation or map mutation beyond the empty-registry check. This check
is still shared callback work and must be acknowledged in disabled-path evidence.

2026-10-26 — No additional writer index or append denormalization. Extend only
subscription-target constraints and save dispatch. Defer shared scan caches,
tries, per-namespace database channels, maintained category inventories and
adaptive per-category query merging until a measured remaining bottleneck
justifies their invalidation, lifecycle and ordering complexity.

2026-10-26 — Keep evidence proportional. Reuse retained query research; verify the
production payload query and worker invariants first. Measure namespace-disabled
notification overhead and one active sparse namespace workload before expanding
coverage. A bounded window limits one fetch, not total replay work or total work
across workers. Preserve ADR-15's original-control cumulative comparison and
report active-reader cost without claiming that unchanged append SQL proves
neutrality.

2026-10-26 — Stop the performance attempt at the incompatible deployed cell/client
interface. Preserve the zero-trial journal and original budget; leave M3 performance
acceptance open. Production correctness, documentation and structural completion
stand independently. Resume performance work only with a compatible infrastructure
contract and a new explicit budget, retaining this failed attempt.

Historical decisions retained in substance: June's additive target, exact-category
compatibility, consumer-group support and explicit performance accounting still
apply. June's LIKE/index/per-stream SQL and global-wake recommendations are
superseded. October 10's shared-cost requirement still applies; its unselected
browse layout was resolved by ADR-17 and migration 0015 on October 11.
ADR-10's October 25 acceptance of the existing category architecture likewise
does not authorize another write-cost allowance.

## Outcomes & Retrospective


Plan-refresh outcome, 2026-10-26: the plan now describes the current code and a concrete design that
removes per-family stream probes and extra writer indexes while suppressing
unrelated live queries. This is a design outcome, not a measured speedup. The
remaining cost is scanning global history for each namespace/group member,
matching-row payload fetch/decode, checkpoint saves, and active notification
routing. SQL production plans, worker correctness and performance acceptance
remain open. No production source or schema was changed during this refresh.

Implementation outcome, 2026-10-26: `CategoryNamespace` is implemented with a
manifest-allocated migration, safe completed-window checkpoints and selective
reference-counted wakes. The final store suite passes 522 examples; adapter 45;
migrations 25 each on PG17/18; focused namespace 26 each on PG17/18, including
96 production EXPLAIN cases per major. Append/category statements, publisher
sources and released migration bytes are preserved. The feature is functionally
and structurally complete, with cumulative performance acceptance still open.
The [evidence report](../../kiroku-store/bench/results/ep54-namespace/README.md)
retains the production plans, local delivery proof, frozen candidate/control,
failed client-side submission, and cleanup. No remote benchmark ran, no pair was
verified, and no speedup or neutrality claim is made.

FRIC-4 in `docs/friction-log/` is resolved by correcting the Hspec commands.
FRIC-5 is accepted: retain mandatory formatting on edited files and verify SQL
bodies independently. FRIC-6 is resolved by documenting the infrastructure shell.
FRIC-7 is resolved by documenting Python 3.14 and testing safe pre-acquire resume.
FRIC-8 remains logged and blocks performance acceptance outside this plan's
production scope. FRIC-9 is accepted: use an explicit usable task-scoped SSH
identity, then revoke it and remove its temporary files.

## Context and Orientation


All paths below are repository-relative. Run commands at the repository root.
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` defines targets, validated
batch/group sizes, dispositions and configuration. `Subscription.hs` registers
live sources and owns cleanup. `Subscription/Worker.hs` implements `LiveSource`,
`nextInput`, `fetchBatch`, `processEvents`, checkpoint saves and reconnect behavior.
`Subscription/Fsm.hs` is the pure state machine: it describes lifecycle transitions
and effects, while the worker executes them. The new window-completion protocol
must connect these pieces rather than bypassing lifecycle/retry handling.

`kiroku-store/src/Kiroku/Store/SQL.hs` owns event reads and specialized checkpoint
save statements. `Subscription/Checkpoint/SQL.hs` owns startup target validation,
`targetColumns`, `targetBindingRow`, `saveBoundCheckpointSession`, adoption,
resize support and rebind SQL. `Subscription/Checkpoint.hs` exposes transactional
checkpoint operations. Rebinding changes identity and position explicitly;
ordinary saves stay monotonic. `Subscription/CheckpointInventory/SQL.hs` exposes
positions, not target kinds; preserve the published inventory shape.

`kiroku-store/src/Kiroku/Store/Notification.hs` already parses the full stream
name from comma-containing notification payloads and derives category once.
It updates category generation counters (monotonically changing wake tokens),
not a trustworthy global position. `Subscription/EventPublisher.hs` tracks global
publisher position and serves ungrouped `AllStreams` queues. Do not add category
lookups or filtering to that publisher's default decode path.

`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql` defines `$all`
(stream ID 0), `stream_events` and `ux_stream_events_stream_version`.
Migration `0012.sql` adds category to global rows; `0014.sql` binds subscription
targets; `0015.sql` adds the browse index. The manifest and package README govern
new migrations. Never edit released SQL bytes. Read the committed `$all` stream
row's `stream_version` to capture an authoritative upper head H, following
`FromCurrentHead` initialization in `Subscription/Checkpoint/SQL.hs`; this avoids
depending on publisher decode progress. A sweep processes only positions up to H.

Relevant durable decisions are [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md)
(stable SQL hash partitioning), [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md)
(durable target identity and explicit rebind), [ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md)
(configuration/refusal contracts), [ADR-10](../adr/0010-category-reads-use-a-denormalized-category-index-on-all-rows.md)
(existing category storage/access), [ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
(proportional evidence and default-path protection), [ADR-12](../adr/0012-decode-failures-are-per-event-outcomes-with-independent-subscription-dispositions.md)
(per-event decode dispositions), [ADR-15](../adr/0015-inspection-observers-preserve-wire-contracts-and-bound-shared-work.md)
(cumulative cost and frozen inspection contracts), and
[ADR-17](../adr/0017-stream-browsing-uses-byte-order-and-one-shared-name-index.md)
(one browse index and bounded namespace windows). Existing category write cost
and browsing-cohort acceptance are baselines, not authorization for additional
regressions. Coordinate changes with
[plan 88](88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md)
and [MasterPlan 13](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md);
do not reopen their completed ordering choice or install another browse index.

`kiroku-store/test/Main.hs` is the Hspec test driver. Reuse
`Test.SubscriptionTarget`, `Test.SubscriptionReconnect`,
`Test.SubscriptionRetryDeadLetter`, `Test.CategoryIdleNoSpin`,
`Test.ConsumerGroup`, and `Test.Helpers` under `kiroku-store/test/Test/`.
`kiroku-store/bench/Explain.hs` and `scripts/mp13-shared-name-index-probe.py`
provide structural-query precedents. `bench/mp13-release/README.md` documents
the retained cumulative comparison infrastructure.

## Plan of Work


### Milestone 1 — Bounded windows and an end-to-end namespace worker


Add `CategoryNamespace !Text` to `SubscriptionTarget`. Add internal `NamespaceWindow` containing events,
`scannedThrough :: GlobalPosition`, `scannedCount :: Int32`, and `exhausted :: Bool`.
Carry decoded events and completion fields in the FSM `NamespaceWindowFetched`
input and `DeliverNamespaceWindow` effect; publish progress only through
`NamespaceWindowCompleted` after processing. Capture H once per sweep. Initially choose
W = min(1024, batchSizeValue (batchSize config)); batch size remains an upper
bound on delivered events, while W also bounds unrelated rows inspected per
fetch. Do not issue a request when the scan cursor is already at or beyond H.

Add plain and grouped namespace statements in
`kiroku-store/src/Kiroku/Store/SQL.hs`. The essential query shape is below;
parameterize W, H and namespace in production. This position-only diagnostic
illustrates progress independently of delivery. It is not the payload decoder.

```sql
WITH scanned AS MATERIALIZED (
  SELECT event_id, stream_version, original_stream_id,
         original_stream_version, category
  FROM stream_events
  WHERE stream_id = 0 AND stream_version > $1
  ORDER BY stream_version
  LIMIT $4
), eligible AS MATERIALIZED (
  SELECT * FROM scanned WHERE stream_version <= $2
)
SELECT count(*) AS scanned_count,
       max(stream_version) AS last_scanned,
       count(*) < $4 OR coalesce(max(stream_version) = $2, false) AS exhausted,
       coalesce(array_agg(stream_version ORDER BY stream_version)
         FILTER (WHERE category COLLATE "C" = $3
                       OR starts_with(category, $3 || ':')), '{}') AS matches
FROM eligible;
```

Here `$1` is the exclusive cursor, `$2` is H, `$3` is the literal namespace and
`$4` is W. Limiting the lower-bounded global scan before the upper-head and
namespace predicates preserves the successful generic-plan prototype shape.
If eligible count is less than W, or its final position equals H, the sweep is
exhausted and its completed frontier is H. Otherwise the next scan cursor is
its maximum position, even if no namespace rows matched. Gaps from hard deletion
do not imply a missing event to wait for; an empty eligible set exhausts this
captured head. A full final window may require one additional empty fetch.

Production SQL must return progress and payload rows in the same statement
snapshot. Compute a single progress row from `eligible`, filter namespace and
group membership in a bounded matching CTE, then join matching event IDs to
`events` using the existing RecordedEvent projection. Return progress with a
nullable event row (one sentinel row when there are no matches), and decode the
sentinel explicitly. Sort only the bounded matching set by global position.
Do not join all W rows to payloads before filtering, run a second snapshot to
recover progress, or apply a smaller matching-event LIMIT and checkpoint past
unreturned matches. Missing payloads for selected junction rows must be treated
as an error, not silently counted as resolved. Retain normal delete semantics
from existing reads.

Apply the current group formula to `eligible.original_stream_id`, never reserved
stream ID 0, and only after limiting the global scan:

```sql
(((hashtextextended(original_stream_id::text, 0) % group_size)
   + group_size) % group_size) = member
```

Use validated group values and `member`/`size` accessors. Every member scans the
global windows independently; the union of deliveries covers the namespace,
but the scan cost multiplies with member count. Apply `decodeEvents` only to
matched events so unrelated payload/decode failures cannot stop this worker.

Integrate the window path into `Subscription.hs`, `Worker.hs` and `Fsm.hs`.
Introduce a namespace live source and namespace-specific fetch/completion input
and effect handling as needed. Keep legacy vector fetch behavior for the old
targets. A window with no matches is progress, not `CaughtUp`; only exhausted
H permits the catch-up-to-live transition. Feed completed-window progress back
after processing rather than putting the speculative frontier in the durable
checkpoint or observable completed state before handlers finish. Never call the
existing nonempty `processEvents` primitive with an empty vector.

Extend the delivery primitive with an internal completion position so a fully
resolved namespace window can save its frontier once, instead of saving the
last matching event and then performing a second ordinary save. Existing targets
retain last-event behavior. Preserve early `Stop` checkpointing at the stopping
event, atomic DeadLetter/checkpoint transactions, Retry handling and decode
refusal. On exceptions, cancellation or fetch failure, do not persist an
uncompleted frontier. Reconnect/restart from the existing safe checkpoint rules;
replaying completed events after a failed save is acceptable.

For consecutive empty-match windows, advance a volatile scan cursor and coalesce
ordinary saves: flush on reaching H and every 32 completed empty windows during
a long sweep, only if progress advanced. A nonempty window's successful completion
also flushes pending safe progress. Thus empty history cannot cause one database
write per fetch, while a restart rechecks a bounded amount of empty work. A
failed flush retains the pending safe frontier for a subsequent retry; it must
not masquerade as a successful durable save. Keep cancellation and reconnect
checks between windows; do not drain unbounded history inside one uninterruptible
effect. Preserve the existing save-failure observability and at-least-once policy.

Implement target identity before using any namespace worker: add
`("category_namespace", Just namespace)` to `targetColumns`, its decoder, and
`saveBoundCheckpointSession`, with a new specialized namespace save statement in
`SQL.hs`. Preserve existing all/category save statements to avoid adding work to
their frequent path. Audit initialization, adoption, dead-letter save, resize,
rebind, target mismatch reporting and any consumer rendering with a repository
search; wildcard decoders require explicit tests, not only exhaustive warnings.

Generate a new native migration with the standard CLI. Extend both CHECK
constraints from migration 0014: allowed kinds include `category_namespace`, and
`target_category IS NOT NULL` iff kind is `category` or `category_namespace`.
Use the existing column for the namespace value; do not widen the public
checkpoint-inventory relation or change existing bindings. Discover actual
constraint names from the migrated schema and use schema-qualified ALTER TABLE.
The generated migration is currently expected to follow 0015; use the allocator,
not a hard-coded next number. No stream/event table or index is altered.
Stop affected workers during upgrade and verify fresh apply, upgrade, and rerun.

M1 acceptance is an early integrated test, not compilation alone: create a
namespace worker, scan across multiple empty windows followed by a match, reach
H, receive a live event in a newly created category, persist its namespace
binding, and restart without skips. Test a grouped worker in the same path.
A temporary global-generation wake is acceptable inside this development
milestone; it is not the final M2 behavior or release acceptance.

### Milestone 2 — Selective namespace wakeups without per-stream discovery


Add a registry in `kiroku-store/src/Kiroku/Store/Notification.hs` keyed by active
namespace with a reference count and a per-namespace generation TVar. Return
an idempotent registration release action. Share a cell for duplicate namespaces
(including group members), and remove the entry only after the last registration
releases it. Allocate/register before initial catch-up, release on failed startup,
Stop, cancellation and exceptions through `Subscription.hs`'s existing cleanup.
A stale release must not remove a later replacement registration.

Reuse the callback's parsed category. For `pm:billing:retry`, inspect the exact
category and ancestors `pm` and `pm:billing`; retain empty segments so the total
semantics for empty/trailing-colon namespaces remain correct. Look up those
candidates in the active registry and bump only their cells. Do not scan the
whole registry or create entries for unsubscribed ancestors. Without namespace
subscribers, take the empty-registry branch before ancestor generation. Publish
namespace bumps with the existing callback transaction; avoid STM dependencies
on unrelated namespace cells in workers so unrelated notifications do not wake
all subscribers to recompute a sum over every category.

For both plain and grouped namespace workers: snapshot generation **before**
capturing H; drain bounded windows through H; then block on that generation
changing or the existing 30-second safety interval. A notification arriving
during the drain forces another sweep. The timeout reconciles lost notifications
across listener reconnect. Capturing H directly from the database makes progress
independent of publisher decode lag. Use namespace generation only as a wake
hint; neither a stream-local NOTIFY version nor generation is a global checkpoint.

This gate suppresses notification-triggered reads for unrelated traffic but does
not eliminate periodic safety work: each safety sweep still inspects new global
rows since its safe cursor. A quiet namespace in a busy store consequently does
batched periodic work, not zero lifetime database work. A busy namespace can
still keep up to the global event rate busy; each group member repeats the scan.
Do not claim the gate changes that asymptotic cost.

M2 acceptance: after initial drain, unrelated category appends produce no
namespace fetch until an injected safety tick, while matching notifications
wake promptly. A notification between snapshot and drain completion is not lost.
Lost notifications recover at the safety tick; reconnect, new categories,
overlapping namespaces and reference-count cleanup retain exact delivery.
Use injectable test timing rather than many real 30-second waits. Include the
empty-registry fast path and ensure no namespace registration survives a failed
worker startup or final release.

### Milestone 3 — Correctness and focused cost evidence


Add `kiroku-store/test/Test/SubscriptionNamespace.hs`, register it in the cabal
stanza and `test/Main.hs`, and extend the existing target/reconnect/disposition
tests where they already own the behavior. Assert event IDs or source IDs; use
an explicit lookup only when asserting names, since RecordedEvent has no stream
name field. Cover bare `pm`, distinct `pm:*` categories, exclusions, nested and
literal metacharacter names, Unicode, comma-containing names, empty namespaces,
and hard-deletion gaps. Retain global ordering and disjoint, complete grouped
delivery, including a member with no matches in several successive windows.

Exercise batch size 1, a full matching window, partial/empty matching windows,
a captured head followed by concurrent appends, and windows ending in unrelated
rows. Test Stop in the middle, Retry, explicit dead-lettering, filtered events,
unhandled decode failure, fetch failure and ordinary/atomic checkpoint failures.
Durable progress must never pass the first unresolved matching event. Restart
and reconnect must resume safely; full-window completion can advance beyond the
last match only when every applicable disposition has completed. Extend target
roundtrip, mismatch, legacy adoption, resize and explicit rebind tests so the
new identity cannot silently decode as unbound or exact category.

Add namespace query-plan cases alongside the existing tests (a new
`Test.NamespaceQueryPlans` module is suitable). Test production parameterized SQL
with custom and generic plans, including payload joins, at W=32 and the maximum
selected W=1024. Start with 1,000 and 20,000 global rows, dense/sparse/absent
matches, and a long pre-cursor history. Both plan modes must seek the existing
global index, inspect at most W visible global rows before filtering, and probe
payloads only for survivors. Reject a streams scan, per-stream LATERAL probes,
unbounded bitmap/sort, or payload work proportional to unrelated history.
Logical row limits do not guarantee W physical buffers: visibility checks and
dead tuples can add work. Record actual rows, loops, buffers and sort size and
investigate growth with family/history size. Do not force `enable_seqscan=off`
to manufacture acceptance. Reuse the prototype's 32-row evidence only for its
metadata projection; do not assert its 9-buffer result for production payloads.

Then run the minimum useful performance comparison on PostgreSQL 18 using the
existing controlled harness. First check structural diffs: unchanged append
statements, event/stream schema and indexes, publisher decoding and existing
category SQL; no namespace work when there are no namespace registrations beyond
the recorded empty-registry check. The subscription constraint migration and
notification callback still need their actual costs considered.

Select an inactive-namespace control comparison and one active workload with
appends, existing category/browse activity and a sparse namespace subscriber.
Choose new-stream creation versus existing-stream appends from the code and
remaining regression risk; do not repeat a full writer/index matrix when those
structures are unchanged. Include one small grouped diagnostic if member scan
multiplication is the remaining question. Record writer throughput/latency,
namespace catch-up time and delivery lag, fetch/checkpoint counts, scanned versus
matched rows, and notification work. Preserve the original pre-inspection
control from the release harness for cumulative reporting; a current-tree
comparison may isolate the namespace increment but cannot replace that control
or reset its cost allowance.

Before any remote run, report cases, pair/trial count, warmup and measurement
lengths, setup/calibration/reset allowance, uncertainty target, total estimate
and stop conditions. Fit everything within one 60-minute ceiling unless the user
sets a smaller one. Prove submission, verified result and lease release with one
small run before expanding; reuse valid prior recovery evidence. Use a persistent
bounded controller and owned journal, monitor remote phase/power/verified trials,
retain interrupted/adverse samples, resume the same journal, start stopped owned
instances when resuming, and release the lease on every exit. No statistical
matrix or automatic precision escalation is prescribed here. Do not relabel
inconclusive evidence as neutral or transfer older cohort acceptance. A consistent
adverse signal blocks acceptance pending diagnosis; report a budget/precision
conflict before more trials rather than weakening the gate.

M3 acceptance combines the stated correctness/structural checks with a focused
performance report under the existing ADR-15 policy. If sparse replay throughput
or multi-member load is inadequate, report that measured limitation before
reopening the design. More indexes, a shared dispatcher or category enumeration
are separate evidence-driven choices, not automatic fallbacks hidden in this plan.

### Milestone 4 — Documentation and compatibility handoff


Update `kiroku-store/CHANGELOG.md`, `kiroku-store-migrations/CHANGELOG.md`,
`docs/user/subscriptions.md`, `docs/user/schema.md`, and relevant target Haddocks
in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`. Confirm actual headings
before editing. Explain `CategoryNamespace "pm"`, exact/boundary semantics,
groups, periodic safety work, sparse replay tradeoff, and checkpoints that record
completed scan progress rather than last delivered matching event. Do not promise
constant total cost or zero shared overhead.

Document stop-workers/migrate/start-new-workers cutover. Older binaries' target
decoder can treat an unknown kind as unbound; older code must not manage namespace
checkpoint rows. Reverting source alone is therefore not a safe downgrade after
creating such rows. Choose package versions through the normal release process
and PVP review; adding a constructor affects exhaustive downstream matches.
Do not invent a version based on June's package state or change dependency bounds
as an incidental plan task. Summarize final durable target/progress/wake decisions
in the relevant ADRs using the repository's ADR workflow when implementation is
accepted. Retain measured limits and evidence links in this plan.

## Concrete Steps


Run at the repository root. Use `nix develop --no-write-lock-file` when the normal
development tools and PostgreSQL are not already on PATH. Never search or read
`/nix/store`; use Mori for dependency source/documentation.

```bash
rg -n 'SubscriptionTarget|AllStreams|Category|LiveSource|target_kind|targetBindingRow' \
  kiroku-store/src shibuya-kiroku-adapter/src
cabal build kiroku-store shibuya-kiroku-adapter
cabal run kiroku-store-migrate -- new \
  --manifest kiroku-store-migrations/migrations/manifest \
  --description "allow category namespace subscription targets"
cabal run kiroku-store-migrate -- check \
  --manifest kiroku-store-migrations/migrations/manifest
cabal test kiroku-store-migrations:kiroku-store-migrations-test
cabal test kiroku-store:kiroku-store-test --test-options='--match namespace'
cabal test kiroku-store:kiroku-store-test
```

Only run `new` once during M1; it mutates the manifest and allocates the file.
The namespace test command selects the new Hspec examples using `--match`.
The earlier Tasty instruction was incorrect (FRIC-4 in `docs/friction-log/`). Compilation and tests must exit successfully; check output
contains the new cases and zero failures. The migration suite must cover an
upgrade from the preceding manifest as well as fresh apply and idempotent rerun.
Follow the existing migration compatibility requirements for PostgreSQL 17 and 18
in `kiroku-store-migrations/README.md`; performance evidence remains PostgreSQL 18.

For a structural illustration, inspect the retained prototype before deciding
whether a rerun answers a new question:

```bash
python3 scripts/mp13-browse-sql-prototype.py --help
```

The `--scope shared-name-index` experiment includes browsing work outside this
feature. Reuse its retained results; prefer focused production namespace test
cases over rerunning the full prototype by default. No `cabal clean` or full
benchmark suite is required merely to refresh this document.

## Validation and Acceptance


The feature is functionally complete only when a namespace subscription catches
up across empty windows, observes future category creation in live mode,
partitions correctly, persists a distinct binding, and survives the disposition
and reconnect cases without skipping an unresolved matching event. Existing
AllStreams, exact-category, topology and checkpoint tests remain green. A clean
exhaustive-pattern build is useful but does not prove wildcard decoders correct.

It meets the performance design only when production EXPLAIN confirms the bounded
ordered global seek before namespace filtering and bounded matching payload work,
and runtime counters prove selective wakeups and coalesced empty-window saves.
Unchanged event indexes eliminate a proposed new index-maintenance cost, not
CPU, pool, cache or I/O contention from active readers. Full replay still costs
O(global rows traversed) per worker, and live safety sweeps eventually traverse
unrelated new rows too. These limitations must remain visible in acceptance.

The performance report must distinguish verified correctness, structural bounds,
verified trial counts, active remote execution (if any), measured uncertainty,
and accepted results. Historical prototype success and the inspection cohort's
practical release decision cannot mark this feature's remaining milestones done.

## Idempotence and Recovery


Use only a new manifest-allocated migration; preserve every released payload and
all existing checkpoints. The migration changes subscription checks and may scan
that table under DDL locks, so stop affected workers and schedule the upgrade
appropriately. No rebuild of the global event history or new event index is part
of this plan. Native migration reruns must verify the already-applied ledger.

A namespace scan cursor is volatile until its completed frontier is saved. On
failure, reconnect/restart from safe progress and tolerate replay. Never recover
by setting the checkpoint to a notification's version, the latest publisher
position or an unprocessed captured head. Use explicit reset/rebind with workers
stopped when an operator intentionally changes target semantics.

Test fixtures use ephemeral databases; never reset a shared database for these
checks. Release every namespace registration and remote lease on all exits.
Keep retained evidence, failed query plans and adverse samples. Do not attempt a
destructive down migration or run old workers over new namespace bindings as an
automatic recovery step.

## Interfaces and Dependencies


The public addition is `CategoryNamespace !Text` on `SubscriptionTarget`.
The required internal interfaces are window results with progress independent
of events; plain/grouped namespace statements; completion-aware worker delivery;
a namespace `LiveSource`; registry acquire/release plus generation handles; and
the `category_namespace` target encode/decode/save path. No new public read
effect or vector-only `readPrefix` API is required. Existing subscribe/config
signatures and RecordedEvent payloads need no new stream-name field.

No new dependency or dependency-version selection is planned. Follow existing
Hasql statement/decoder patterns after locating dependency sources through Mori.
The notification API reference discovered for this refresh is
[mori://hasql/hasql/docs/hasql-notifications](mori://hasql/hasql/docs/hasql-notifications).
The design reuses the current callback and makes no dependency API change.

PostgreSQL's [CTE materialization documentation](https://www.postgresql.org/docs/18/queries-with.html#QUERIES-WITH-CTE-MATERIALIZATION)
explains the explicit evaluation boundary used by the bounded window;
[`starts_with`](https://www.postgresql.org/docs/18/functions-string.html) supplies
literal prefix matching. [Prepared statement documentation](https://www.postgresql.org/docs/18/sql-prepare.html)
distinguishes generic and custom plans. The exact work bounds here are design
requirements supported by the repository prototype, not guarantees inferred
from those documents; the production statements still require EXPLAIN evidence.

## Revision Notes


2026-06-03 — Original validation corrected missing exhaustive-pattern warnings,
misnamed stream-prefix semantics, per-family live-query cost, tiny-fixture EXPLAIN
expectations, and index write amplification. A second pass recommended colon
namespaces and required writer evidence. Those findings motivated this work;
the old source paths and proposed index are no longer implementation guidance.

2026-10-10 — Shared research coordinated plan 88 and this plan under ADR-15,
retained replacement and byte-name layout evidence, and prototyped namespace
windows without a separate index. The later byte-order decision and October 11
release acceptance now appear in ADR-17/15 rather than remaining open here.

2026-10-26 — Replaced contradictory historical snippets with a current, coherent
namespace plan. Added required binding migration, explicit scanned-frontier
semantics, selective reference-counted wakes, payload filtering and coalesced
checkpoint saves; refreshed source paths, test commands, ADR context and focused
cumulative-cost acceptance. No production implementation or new benchmark result
is claimed by this revision.


2026-10-26 — Implemented the target, constraint migration, bounded payload windows,
completed-frontier FSM protocol, selective wake registry, tests and documentation.
Recorded custom-plan and payload-probe barriers, retained exact production evidence,
and stopped performance acceptance at an incompatible external cell/client schema.
