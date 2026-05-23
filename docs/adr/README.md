# Architecture Decision Records

This directory holds Architecture Decision Records (ADRs): short, durable notes
that capture a significant architectural decision, why it was made, and what it
trades off. An ADR is the one-page answer to "why is it built this way?" so a
reader does not have to reconstruct it from the ExecPlans in `docs/plans/`.

ADRs complement, not replace, ExecPlans. An ExecPlan is a working document for
*doing* a piece of work (and may explore dead ends); an ADR is the distilled,
lasting *decision* that came out of it. When an ExecPlan reaches a decision
worth remembering, write (or update) an ADR and link the two.

## Conventions

- One decision per file, named `NNNN-kebab-case-title.md` (zero-padded, e.g.
  `0001-resolve-stream-names-via-lookup.md`). Numbers are sequential and never
  reused.
- Keep it to roughly one page. Link out to the ExecPlan, commits, or code for
  detail rather than restating them.
- **Status** is one of `Proposed`, `Accepted`, `Superseded by ADR-NNNN`, or
  `Deprecated`. Once `Accepted`, do not rewrite an ADR's decision: supersede it
  with a new ADR and mark the old one `Superseded by ADR-NNNN`.
- Record the alternatives you rejected and the evidence (benchmarks, etc.) —
  that is usually the most valuable part for the next person.

## Format

Each ADR has: Title, Status (+ date), Context, Decision, Consequences, and
Alternatives Considered. Copy an existing ADR as a starting template.

## Index

- [ADR-0001](0001-resolve-stream-names-via-lookup-not-recordedevent-field.md) —
  Resolve stream names via an on-demand lookup API, not a `RecordedEvent` field.
