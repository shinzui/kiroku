# Bundle Update Log

## 2026-10-11
* **Update**: IR-18 links the opt-in API, Plan 97 evidence and ADR-19; publication remains pending.
* **Update**: IR-9 records locally complete public/library dead-letter inspection, bounded existing-index reads, real worker reasons and passing full-suite/example/Nix evidence. Status remains `in_progress` until plan 96 publishes the cohort.
* **Implementation**: IR-9 moves to `in_progress`; plan 89 starts public paginated dead-letter reads and the HTTP inspection route under MasterPlan 13.

## 2026-10-10
* **Update**: IR-12 gains local WebSocket convergence evidence and a ten-element guide mapping; status stays in\_progress for cohort performance acceptance and publication.
* **Implementation**: IR-12 is in progress under [ExecPlan 94](../plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md): bounded tail name resolution, coded errors, metrics lifecycle and ordered overflow notices. Publication remains with the cohort release.
* **Update**: Record the user-approved byte-order browsing implementation, bounded Store primitives, HTTP routes, tests and shared migration 0015; final-layout cost and cohort publication remain pending.
* **Update**: IR-8 retains category-first existing-index evidence requested by the user. Category equality is useful, while ordered pages and prefix filtering still scale with selected-category size. Arbitrary prefix search remains required; no new index or production API was added and status remains `in_progress`.
* **Implementation**: IR-8 moves to `in_progress`; plan 88 executes its required PostgreSQL 18 SQL promotion check and rejects inventory-proportional prefix scans. Evidence is retained; production browse APIs and routes await a reviewed read/write design.
* **Implementation**: IR-10 moves to `in_progress`; plan 87 adds durable checkpoint inventory and the provider-based inspection composition under MasterPlan 13. Release remains with plan 96.
* **Update**: IR-7 through IR-18 gain recorded authoring-metadata reviews where absent. These reviews check profile metadata only and record comments; they provide no technical acceptance or release evidence. Empty lists did not satisfy the existing strict requirement.
* **Update**: IR-11 moves to `in_progress`; plan 90 implements and tests the default-off CORS foundation under MasterPlan 13. Release and completion remain with plan 96.

## 2026-10-09
* **Update**: PR \#1 merged IR-18. Its SQL feasibility evaluation records approximately 20-33% extra read latency when the head probe is added to every `getStream`, recommends an opt-in combined metadata/head operation, and checks in reproducible PostgreSQL 18.6 evidence. The existing origin index needs no schema or append/link changes; `0012` retained it. The request now scopes the freshness guarantee to origin-only streams with retained history and documents the linked-stream and reserved `$all` caveats. Status remains `proposed` pending implementation and release.

## 2026-10-06
* **Addition**: IR-18 asks `getStream` (or a sibling read) to answer a stream's newest visible global position beside its `version`, so a consumer holding a stream-version floor can wait for a projection cursor on exactly that stream's events. It originates from `mori://tan/notification-render-service/plans/16-give-the-admin-api-one-command-answer-and-a-read-your-writes-position-floor`, which today waits on Keiro's category visible head as a documented proxy; the request is non-blocking and additive in intent, and the existing `ix_stream_events_all_by_origin` index already serves the probe.

## 2026-09-30
* **Update**: IR-8 and IR-12 are accepted under [MasterPlan 13](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md) (`mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`), which coordinates the five open keiro-ui requests (IR-8, IR-9, IR-10, IR-11, IR-12) as one cohort and adds the standalone `kiroku-inspect` server and a `GET /capabilities` discovery route so the surface also serves an independent Kiroku UI. IR-8 keeps [ExecPlan 88](../plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md) (EP-3); IR-12 gains [ExecPlan 94](../plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md) (`mori://shinzui/kiroku/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention`, EP-5), whose audit corrected the request's ping candidate gap and found that the documented overflow `error` frame is never emitted under `DropOldest`. Plans 87, 88, 89, and 90 were adopted as children; their releases and the `completed` transitions of IR-8 through IR-12 now belong to the cohort release plan, [ExecPlan 96](../plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md). The Status sections of IR-9, IR-10, and IR-11 (already `accepted` with plans 89, 87, and 90) now cite the MasterPlan and the cohort release as well, so all five records read alike.
* **Update**: IR-15 is accepted; [ExecPlan 93](../plans/93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime.md) (`mori://shinzui/kiroku/plans/93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime`) plans the lifetime-held session-level member guard on a dedicated connection with fail-closed start-up and heartbeat reacquisition, structural tests pinning zero new pool checkouts, documentation and ADR updates, and the confirmation-gated `kiroku-store` release. IR-17 is accepted; [ExecPlan 92](../plans/92-expose-the-lifetime-member-guard-in-the-shibuya-adapter.md) (`mori://shinzui/kiroku/plans/92-expose-the-lifetime-member-guard-in-the-shibuya-adapter`) plans the dependent opt-in `consumerGroupGuard` fields on `KirokuAdapterConfig` and `KirokuConsumerGroupConfig`, their two-store tests, documentation, and the confirmation-gated adapter release. Both stay short of `completed` until release evidence exists.

## 2026-09-27
* **Addition**: IR-17 requests an opt-in lifetime member guard in `KirokuAdapterConfig` after IR-15 makes the store guard effective for the worker's lifetime. Kenshou's released and current-tested adapter runs showed duplicate handler effects with two processes sharing one member while preserving at-least-once delivery.

## 2026-09-25
* **Addition**: IR-16 requests bounded, prompt publisher retries after returned pool errors. PostgreSQL 17 and 18 verification runs kept the at-least-once guarantee but exceeded kenshou's local 60-second blackhole-recovery target; the diagnostic PostgreSQL 18 run recorded successive publisher pool errors separated by safety-poll waits. This is a recovery-latency request, not a bug report for a promised 60-second deadline.

## 2026-09-24
* **Addition**: IR-15 asks consumerGroupGuard to hold a session-level advisory lock for the worker's lifetime instead of a transaction-scoped probe that cannot see a running peer. The request originates from mori://shinzui/notification-hub (plan 75) and is non-blocking: the application holds the lock itself with Kiroku's key.

## 2026-09-10
* **Update**: IR-11 is accepted; [ExecPlan 90](../plans/90-add-configurable-cors-support-to-kiroku-metrics.md) (`mori://shinzui/kiroku/plans/90-add-configurable-cors-support-to-kiroku-metrics`) plans the default-off `cors` policy on `MetricsServerConfig`, the WAI middleware covering HTTP responses, preflights, and WebSocket upgrades, its tests and documentation, and the confirmation-gated major release that will complete the request.
* **Update**: IR-9 is accepted; [ExecPlan 89](../plans/89-expose-a-public-dead-letter-read-api.md) (`mori://shinzui/kiroku/plans/89-expose-a-public-dead-letter-read-api`) plans the public `subscriptionDeadLetters` Store operation with keyset pagination and the `GET /subscriptions/<name>/dead-letters` route in `kiroku-metrics`, its tests and documentation, and the confirmation-gated release that will complete the request.
* **Completion**: IR-13 is complete; [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md) (`mori://shinzui/kiroku/okf/adrs/concepts/ADR-9`) records the wire-format stability contract and the sister-package endpoint-ownership boundary, and `docs/user/metrics.md` cites it from a new wire-format stability section. Written directly from the request without an ExecPlan.
* **Update**: IR-8 now names its implementation plan, [Plan 88](../plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md) (`mori://shinzui/kiroku/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events`), which adds listStreams/listCategories/getEvent to the Store effect and the paginated browse routes to kiroku-metrics; status stays proposed until implementation lands.
* **Update**: IR-10 is accepted; [ExecPlan 87](../plans/87-serve-durable-subscription-checkpoints-over-http.md) plans the `GET /subscriptions/checkpoints` route in `kiroku-metrics`, its tests and documentation, and the confirmation-gated 0.2.0.0 release that will complete the request.

## 2026-08-22
* **Addition**: IR-14 requests a manifest-driven transactional selective-event compaction primitive that preserves retained identities, stream versions, positions, links, and append correctness; it originates from Mori MasterPlan 27 and hard-gates its legacy Repository compaction plan.

## 2026-08-19
* **Addition**: Add the keiro-ui UI-endpoint request set (IR-8..IR-13): a REST read API for browsing streams, categories, and events; a public dead-letter read API; durable subscription checkpoints over HTTP; configurable CORS in kiroku-metrics; additive WebSocket convergence with the cross-project convention; and a wire-format stability ADR. All raised by mori://shinzui/keiro-ui with origin recorded per request.

## 2026-08-16
* **Addition**: IR-7 requests source-before-`$all` lock ordering in `appendMultiStream` for streams that do not exist yet, closing the multi-versus-single deadlock that the EP-1 F4 pre-lock leaves open for fresh streams. Filed as a request rather than a defect: the published `appendMultiStream` claim covers multi-versus-multi contention only, and a repeated conflict now surfaces as the retryable `TransientTransactionFailure`. Adoption is gated on append-throughput measurement.

## 2026-08-15
* **Completion**: IR-4 is complete; `kiroku-store` 0.6.0.0 published the visible-head API on 2026-08-12 and Keiro adopted it in `Keiro.ReadModel` and `Keiro.ReadModel.Rebuild`, retiring its temporary Kiroku-schema head query.
* **Completion**: IR-3 is complete; `kiroku-store` 0.5.0.0 published the checkpoint lifecycle API on 2026-08-11, Keiro adopted the policy in its projection catalog and the reset combinator in coordinated rebuilds, and the downstream cohort shipped as Keiro 0.12.0.0.
* **Correction**: IR-3 and IR-4 left the non-vocabulary status `implemented` for Mori's closed lifecycle set; both now record `completed`.

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
