# Bundle Update Log

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
