You are upgrading a project that consumes **shibuya-kiroku-adapter** across one
released version edge. The adapter runs Kiroku event-store subscriptions as
Shibuya queue processors: `kirokuAdapter`, `kirokuProcessor` and the
consumer-group helpers turn a subscription into a Shibuya `Adapter` and
`QueueProcessor`.

This blueprint's version space is **`shibuya-kiroku-adapter`** itself. Its breaks
usually come from Shibuya, not from `kiroku-store`, so they cannot be keyed on
the store's version. Store and schema changes belong to the `kiroku-upgrade`
blueprint from the same repository. When an adapter edge needs a store edge, it
says so with `entails`. An edge without `entails` needs no store upgrade.

## What this project may be

- **A direct consumer.** It names `shibuya-kiroku-adapter` in `build-depends` and
  builds `KirokuAdapterConfig` or `KirokuConsumerGroupConfig` values.
- **A framework consumer.** It reaches the adapter through Keiro, Kioku or a
  similar library and never names it. The framework's own blueprint will usually
  have handled the source half. This project may still own trace queries,
  dashboards and tests that depend on span names and trace shape.

Establish which case applies before you change anything. If an edge has nothing
to change in this project, that is a normal result: report the edge *not
applicable* and succeed.

## Ground rules

- **Read before you edit.** Find the real call sites with `rg` before assuming a
  symbol is used.
- **Never force a dependency solve.** Do not add `allow-newer`, jailbreaks or
  source-repository pins for a Shibuya package. If a dependency needed by the edge
  has not been released, stop. Report which package and version is missing and
  leave the project as it was. Do not report the edge as complete: Seihou records
  a completed edge as crossed and will not run it again.
- **Do not decide trace shape silently.** An edge that changes how processing
  spans join traces states the default and how to opt out. Choose based on
  evidence in this project, and report the choice and the evidence.
- **Do not widen the change.** Fix what the edge names. Unrelated warnings,
  formatting and version bumps of other libraries are out of scope.
- **Report what you could not verify.** Tests that need PostgreSQL, a collector or
  external dashboards may be out of reach. Name the commands you did not run and
  the dashboards you could not see; do not claim they pass.

Find dependency sources and documentation through Mori. The adapter is owned by
mori://shinzui/kiroku and Shibuya by mori://shinzui/shibuya.
