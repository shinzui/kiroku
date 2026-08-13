# Bundle Update Log

## 2026-08-13
* **Completion**: IR-6 shipped in `kiroku-store` 0.7.0.0 and `kiroku-store-migrations` 0.3.2.0 with the four required dependent patch releases; Hackage source/docs, annotated tags, GitHub releases, and an isolated clean consumer agree on the replay-history retention contract.
* **Completion**: IR-5 shipped in `kiroku-store-migrations` 0.3.1.0; Hackage, the annotated upstream tag, the published source archive, and an isolated clean consumer agree on the nine-migration checkpoint-relation contract.
* **Implementation**: IR-5 is implemented in repository source with migration 0009, frozen catalog and behavior proofs, least-privilege isolation, dependency replacement evidence, indexed planning, user documentation, and ADR-6; publication remains pending.
* **Correction**: IR-5 now specifies semantic non-null view values, a structurally read-only owner-rights definition, and a focused catalog contract test while preserving pg-migrate's plan-versus-ledger verifier semantics.
* **Addition**: IR-6 requests renewable fan-in history-retention leases and transaction-scoped stream-history guards that serialize replay with destructive lifecycle mutations.
* **Addition**: IR-5 requests a frozen Kiroku-owned SQL relation for exact durable subscription-member checkpoints so database consumers do not depend on the private subscriptions table.

## 2026-08-12
* **Implementation**: IR-4 is implemented in repository source with a payload-free visible-head API, lifecycle and mock evidence, and an indexed no-sort query-plan gate; release publication and Keiro adoption remain pending.
* **Addition**: IR-4 requests a public payload-free visible global head, distinct from the monotonic append frontier, so Keiro can remove private Kiroku SQL after the owning API is released.

## 2026-08-11
* **Implementation**: IR-3 is implemented in repository source with explicit atomic startup policies, typed refusal telemetry, exact transactional reset, and full acceptance evidence; downstream release remains pending.

## 2026-08-09
* **Addition**: IR-3 requests explicit missing-subscription-checkpoint policies and a
transaction-composable lifecycle reset API; [Plan 70](../plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit.md)
and `mori://shinzui/keiro/masterplans/33-make-subscription-checkpoint-lifecycle-explicit-before-the-next-release`
coordinate implementation before the next release.

## 2026-08-08
* **Update**: IR-2 now records that Keiro removed its process-local and cross-schema substitutes;
the durable checkpoint-inventory and projection-lag commands wait on the Kiroku API.
* **Addition**: IR-2 requests a public, member-aware inventory of exact durable subscription
checkpoints. It lets Keiro add database-only checkpoint reporting without private Kiroku SQL and
keeps that state distinct from Kiroku and Shibuya's process-local live snapshots.
* **Addition**: IR-1 requests a public global-head read and bounded `$all` / category paging so
offline projection replays can prove completion through a captured frontier while concurrent
appends continue. The request originates from
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-20` and is explicitly non-blocking.
