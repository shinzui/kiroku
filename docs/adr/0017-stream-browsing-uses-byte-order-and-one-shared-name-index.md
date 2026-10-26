---
type: Architecture Decision Record
title: Stream browsing uses byte order and one shared name index
description: "Use stable UTF-8 byte order for new stream pages, share one name index across category and literal-prefix browsing, and retain separate measured write-cost acceptance."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-10T23:40:46Z"
docId: ADR-17
status: Accepted
date: 2026-10-10
timestamp: "2026-10-26T16:23:48Z"
originatingPlan: docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md
---

# ADR-0017: Stream browsing uses byte order and one shared name index

## Context

[Plan 88](../plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md)
needs bounded stream pages, including exact-category browsing and a literal
prefix within a category. The dominant stream convention is category plus
TypeID. Deployment locale order makes general Unicode prefix ranges incorrect;
nullable cursor and unrestricted prefix filters can scan the whole catalog.
[ADR-15](0015-inspection-observers-preserve-wire-contracts-and-bound-shared-work.md)
requires shared physical design and measured aggregate write cost.

## Decision

The user accepted stable UTF-8 byte order for the new stream-browsing API.
Names remain Unicode text, are compared with PostgreSQL COLLATE "C", and use
exclusive name cursors. This preserves TypeID generation order within a category;
it promises neither append order nor commit order. Category enumeration retains
its existing deployment collation. Existing name uniqueness, event order and
published reads keep their contracts.

Select one partial index, `ix_streams_browse_name`, on
`streams(stream_name COLLATE "C") WHERE stream_id <> 0`. Keep the existing unique
name and category indexes. This one new index serves global names, literal
prefixes, exact categories, and their intersection; do not add a separate
category/name index. Exact categories include the bare category name and the
category-plus-hyphen range. Compute their intersection with a prefix before
SQL, with at most two disjoint bounded branches. First and continuation pages
have separate lower-bound operators. Apply an upper bound outside an ordered
LIMIT so generic prepared plans cannot choose an unbounded bitmap and sort.

[Plan 54](../plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md)
uses bounded global event windows and filters existing denormalized categories.
`CategoryNamespace "pm"` includes category `pm` and literal `pm:` descendants;
values are never normalized or interpreted as wildcards. Migration 0016 extends
only subscription-binding constraints. No additional event/stream index, append
column, trigger or publisher decoding is required. Each worker (including each
group member) still scans global history independently.

Production custom plans can select the partial category index at late cursors and
sort metadata before LIMIT. Namespace SQL selects the integral range
`0 <= stream_id < 1` in `(stream_id, stream_version)` index order before LIMIT;
this is exactly stream ID zero and prevents that partial-index substitution.
A per-event LATERAL probe with `OFFSET 0` keeps payloads behind bounded matching,
avoiding full payload-table joins in custom/generic plans. This does not enumerate
or probe source streams. Plan 54 retains production EXPLAIN evidence separately
from the older metadata-only prototype.

Active namespaces share reference-counted generation cells. The callback checks
for an empty namespace registry before deriving colon ancestors, then looks up
only the notified category and its ancestors. It does not scan active subscribers
or retain a second historical-category map. Workers snapshot generation before
capturing the database head and use it only as a wake hint, with a 30-second
lost-notification safety poll. Sparse live namespaces still scan unrelated rows
periodically. Functional/structural checks do not imply performance acceptance;
the focused cumulative comparison remains a separate gate under ADR-15.

Migration 0015 installs the selected index transactionally. Its build requires
a write pause or maintenance window. The selected layout was measured separately
from earlier category/name replacements and accepted for the 2026-10-11 cohort.
The [release record](../../bench/mp13-release/publication-2026-10-11/README.md)
retains the comparison and practical acceptance. Future changes still require
cumulative acceptance under ADR-15, without separate per-feature allowances.

## Consequences

Category and prefix browsing share one index cost. The index adds stream-catalog
storage and maintenance on new stream rows and non-HOT stream updates. It does
not add an event or junction-row index; unchanged HOT eligibility does not prove
zero end-to-end append cost. Keep performance uncertainty and measured adverse
signals visible. Browsing is bounded live pagination, not a cross-request
snapshot. Clients echo names verbatim as cursors.


Plan 54's 2026-10-26 cumulative comparison subsequently completed ten verified
pairs. Its native statistical verdicts remain inconclusive; the user explicitly
accepted practical performance for that cohort and closed its milestone. The
[acceptance record](../../kiroku-store/bench/results/ep54-kenshou/acceptance.json)
preserves that distinction. The bounded scan contract and independent per-member
work limits above remain unchanged; this acceptance creates no future allowance.
