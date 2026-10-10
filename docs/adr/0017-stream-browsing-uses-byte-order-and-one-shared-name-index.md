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
timestamp: "2026-10-10T23:40:46Z"
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
should use bounded global event windows and filter existing denormalized
categories for its proposed namespace semantics. The successful prototype needs
no extra prefix index. Its future worker must distinguish scanned progress from
matching events and checkpoint only completed dispositions. That worker and
its final semantic choice remain plan 54's work.

Migration 0015 installs the selected index transactionally. Its build requires
a write pause or maintenance window. Production promotion still requires a
focused cost comparison for this exact layout; earlier category/name replacement
measurements do not certify it. Release acceptance remains cumulative under
ADR-15, without separate per-feature regression allowances.

## Consequences

Category and prefix browsing share one index cost. The index adds stream-catalog
storage and maintenance on new stream rows and non-HOT stream updates. It does
not add an event or junction-row index; unchanged HOT eligibility does not prove
zero end-to-end append cost. Keep performance uncertainty and measured adverse
signals visible. Browsing is bounded live pagination, not a cross-request
snapshot. Clients echo names verbatim as cursors.
