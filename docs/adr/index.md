---
okf_version: "0.2"
---

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

- One decision per file. Existing files keep their `NNNN-kebab-case-title.md`
  names (zero-padded, numbers sequential and never reused) for citation
  stability; new ADRs may use any kebab-case filename, since the durable
  identity is the frontmatter `docId` (`ADR-N`), not the filename.
- Keep it to roughly one page. Link out to the ExecPlan, commits, or code for
  detail rather than restating them.
- Frontmatter `status` is `Accepted`, `Proposed`, `Superseded by ADR-N`, or
  `Deprecated`, optionally with a parenthetical qualifier (e.g. `Accepted
  (amended …)`) when it carries meaning beyond the bare status. Once
  `Accepted`, do not rewrite an ADR's decision: supersede it with a new ADR
  and mark the old one `Superseded by ADR-N`.
- Record the alternatives you rejected and the evidence (benchmarks, etc.) —
  that is usually the most valuable part for the next person.
- This bundle is governed by the shared `docs/adr/profile.dhall` OKF profile.
  Every ADR carries `type`, `title`, `description`, `docId`, `status`, `date`,
  and `timestamp` frontmatter; validate with `just adr-validate` (see
  `migration-reference.md` in the `adopt-architecture-decisions` blueprint for
  the full field contract).

## Format

Each ADR has: Title, Related links, Context, Decision, Consequences, and
Alternatives Considered. Copy an existing ADR as a starting template.

# Files

- [profile.dhall](profile.dhall)

# Architecture Decision Record

- [Resolve stream names via an on-demand lookup API, not a `RecordedEvent` field](0001-resolve-stream-names-via-lookup-not-recordedevent-field.md) - Resolve stream names on demand via a batch lookup API instead of adding an originalStreamName field to RecordedEvent, keeping the read hot path byte-identical and inside the 10% read-regression gate.
- [Consumer groups are static, hash-partitioned competing consumers](0002-static-hash-partitioned-consumer-groups.md) - Implement consumer groups as static, hash-partitioned competing consumers over each stream's surrogate stream_id, with structured per-member checkpoint columns and no dynamic rebalancing.
- [Install Kiroku objects in a dedicated `kiroku` schema](0003-dedicated-kiroku-schema.md) - Install all Kiroku-owned objects into a dedicated schema (default kiroku), making ConnectionSettings.schema authoritative for both table resolution and the LISTEN notification channel.

