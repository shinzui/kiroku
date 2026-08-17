# kiroku-upgrade

> Agent-guided upgrade guidance for projects consuming Kiroku, published as one
> edge per released version window that needs judgement work.

**Version:** `0.1.0`

**Kind:** Blueprint migration (run with `seihou agent migrate`, not
`seihou agent run` — this blueprint declares no baseline and applies no modules)

## Two ways this blueprint is reached

Most projects reach a Kiroku edge **indirectly**. A downstream framework — Keiro,
Kioku — declares that one of its own edges entails an exact edge of this
blueprint, and Seihou runs it first, under this blueprint's prompt and reference
files, filing the receipt under *this* blueprint's identity. Such a project may
never name Kiroku in `build-depends` at all.

A project that uses Kiroku directly runs it by name:

```sh
seihou install https://github.com/shinzui/kiroku.git --module kiroku-upgrade

seihou agent --debug migrate kiroku-upgrade --from 0.7.0.1   # preview
seihou agent migrate kiroku-upgrade --from 0.7.0.1           # run
```

Because the receipt identity is the same either way, a shared edge is crossed
**exactly once** from either entry point. A project that reached this edge
through Keiro and later runs `kiroku-upgrade` directly finds nothing to do, and
the reverse order works the same way. Invoking this blueprint by name expands
nothing it does not need.

## Declared edges

| From | To | Covers |
|---|---|---|
| `0.7.0.1` | `0.8.0.0` | `kiroku-store` 0.8.0.0 (`StoreError` gains `TransientTransactionFailure`) and `kiroku-store-migrations` 0.4.0.0 (migration `0010` re-baseline, forward migration `0011`) |

## Version space

Kiroku ships several packages that version independently. This blueprint's
version space is **`kiroku-store`**, the core library, because that is the
version a consuming project is most likely to know it is on. An edge covers
every Kiroku package released in its window and says which ones it touches —
`kiroku-store-migrations` 0.4.0.0 falls inside the `0.7.0.1 -> 0.8.0.0` edge even
though its own number moves on a different schedule.

Edge `from` versions name the **last release before the break**, not the first
one an edge could apply from. Seihou selects an edge when its `from` is at or
after the cursor, so a lower `from` would be skipped by anyone already past it,
while `0.7.0.1` is reached correctly by every project at or below it.

## Version probe

```
jq -r '."install-plan"[] | select(."pkg-name"=="kiroku-store") | ."pkg-version"' \
  dist-newstyle/cache/plan.json 2>/dev/null | sort -u | tail -1 | grep .
```

Read-only and fast. It reports what this project's build plan actually resolved
rather than a declared bound. A project without a configured Cabal build, or
without `jq`, gets a warning and is asked for `--to` — the intended degradation,
since a guessed window runs the wrong edges against real source.

## What edges here may and may not do

Kiroku owns SQL migrations, so its edges routinely have a **database half** as
well as a source half. The rule these prompts hold to:

- An edge may **classify** a database from read-only evidence, and may name the
  exact fixup script and sequence its operator must run.
- An edge may **not** apply a ledger fix, or any migration, to a database it has
  not established is disposable. Rewriting a ledger row is how a database
  silently skips a migration, and the safe path — backup, restore a clone,
  rehearse, then production — is an operator decision, not an agent's.

Fixup scripts ship in the `kiroku-store-migrations` source distribution under
`ledger-fixups/`. An edge names that path; it never hand-writes equivalent SQL,
so the checksums come from the release rather than from a prompt.

## For maintainers

Add an edge in the same change that cuts a release that needs one. Declare an
edge only for releases requiring judgement work — undeclared gaps are legal and
mean no agent intervention was needed.

Write each edge's precondition explicitly, and write it to survive being run by a
project that does not use Kiroku directly, which for this cohort is most of them.
An edge that finds no direct usage and no affected database should report itself
*not applicable* and change nothing; Seihou will plan it again if the project
starts using the library. Never tell an edge to exit nonzero when it does not
apply — that reports a provider failure and halts every remaining edge in the
chain, including a downstream library's.

```sh
seihou validate-blueprint blueprints/kiroku-upgrade
```
