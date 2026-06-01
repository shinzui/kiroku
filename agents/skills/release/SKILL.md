---
name: release
description: Release Kiroku packages to Hackage following PVP, with independent per-package versions
argument-hint: "[package] [major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Kiroku Release Skill

Release Kiroku's public packages to [Hackage](https://hackage.haskell.org/)
following the Haskell **PVP**. Each package is **versioned and tagged
independently** — there is no shared version number.

## Versioning Strategy

Each package owns its own PVP version (`A.B.C.D`) and its own git tag
`<package>-v<version>` (e.g. `kiroku-store-v0.1.0.0`). A release may cover a
single package or several at once; only the packages that actually changed
need to be bumped and published.

PVP rules for `A.B.C.D`:
- `A.B` — **major**: breaking API changes (removed/renamed exports, changed
  types or semantics).
- `C` — **minor**: backwards-compatible API additions (new exports/modules/
  instances).
- `D` — **patch**: bug fixes, docs, internal-only or performance changes.

Increment:
- **major**: bump `B`, reset `C`,`D` to 0 (`0.2.0.1` → `0.3.0.0`)
- **minor**: bump `C`, reset `D` to 0 (`0.2.0.1` → `0.2.1.0`)
- **patch**: bump `D` (`0.2.0.1` → `0.2.0.2`)

## Packages (in dependency order)

Publish in this order — dependencies first:

1. **kiroku-store** (`kiroku-store/`) — core PostgreSQL event store. No
   internal dependencies.
2. **kiroku-store-migrations** (`kiroku-store-migrations/`) — schema
   migrations + `kiroku-store-migrate` exe. Depends on `kiroku-store`.
3. **kiroku-otel** (`kiroku-otel/`) — OpenTelemetry instrumentation (sister
   package). Depends on `kiroku-store`.
4. **kiroku-cli** (`kiroku-cli/`) — embeddable operator CLI + `kiroku` exe.
   Depends on `kiroku-store`.
5. **shibuya-kiroku-adapter** (`shibuya-kiroku-adapter/`) — adapter bridging
   `kiroku-store` and `shibuya-core`. Depends on `kiroku-store` (and the
   external, already-published `shibuya-core`).

**Not released** to Hackage:
- **kiroku-test-support** — shared test fixtures; consumed only by other
  packages' test-suites. Internal.
- Example executables and benchmark components (e.g.
  `kiroku-consumer-group-example`, `kiroku-store-bench`,
  `kiroku-shibuya-overhead`, `kiroku-store-bench-explain`) — these ship as
  components inside their package's sdist; they are not separate Hackage
  packages.

## Arguments

`$ARGUMENTS` is optional:
- A **package name** (e.g. `kiroku-otel`) to scope the release to one package.
- A **bump level** (`major` | `minor` | `patch`).
- Either, both, or neither. If a package is omitted, determine the scope from
  changes (step 1). If a bump level is omitted, infer it from the commits
  (step 2).

## Steps

### 1. Determine the release scope

- For each publishable package, find its last release tag matching
  `<package>-v*`. With `git log <last-tag>..HEAD -- <package-dir>` list the
  commits that touched that package's directory.
- If a package has **no tag yet**, this is its **first release**: treat its
  whole history under `<package-dir>` as the change set, and the current cabal
  version as the initial version (do not bump on a first release unless the
  user asks).
- A package "needs release" if it has commits since its last tag (or has never
  been released). If `$ARGUMENTS` names a package, scope to just that one.
- Present a summary table: package | current version | last tag (or "none") |
  commits since last tag. If nothing changed and no package was named, report
  that there is nothing to release and stop.

### 2. Determine each package's next version (PVP)

For every package in scope:
- If `$ARGUMENTS` gives a bump level, apply it.
- Otherwise infer from that package's commits:
  - "breaking"/"remove"/"rename"/"change type" → major
  - "add"/"new"/"feature"/"export" → minor
  - "fix"/"docs"/"refactor"/"internal"/"perf" → patch
- First release (no prior tag): keep the current cabal version as-is unless the
  user requests a bump.
- Present the proposed per-package bumps and **ask the user to confirm** before
  changing anything.

### 3. Update versions, dependency bounds, and changelogs

For each package being released:

**Version** — edit `<package>/<package>.cabal` to the new version.

**Internal dependency bounds** — if a dependency package was bumped, update
its bound in every publishable dependent. Dependents of `kiroku-store` are
`kiroku-store-migrations`, `kiroku-otel`, `kiroku-cli`, and
`shibuya-kiroku-adapter` (update the `kiroku-store` bound in the library *and*
test-suite/executable stanzas).
Use PVP-friendly bounds, e.g. `kiroku-store ^>=A.B` matching the released
version. Leave external bounds (e.g. `shibuya-core ^>=0.5 && <0.6`) alone
unless they genuinely changed.

**Changelog** — add a new section for the new version above prior entries,
dated today (`YYYY-MM-DD`), moving any "Unreleased" content into it. Group
entries under **Breaking Changes** / **New Features** / **Bug Fixes** /
**Other Changes** (only the categories that apply). Each publishable package has
a `CHANGELOG.md`.

**First-release packaging check** — before a package's first Hackage upload,
make sure its `.cabal` has the fields Hackage requires: `synopsis`,
`description`, `category`, `maintainer`, `license` (already BSD-3-Clause), and
ideally `homepage`/`bug-reports` pointing at the GitHub repo. `cabal check`
(step 6) will flag anything missing — fix it before publishing.

Show the user **all** changes (versions, bounds, changelogs) for review.

### 4. Verify builds and checks

Run from the repository root:
- `nix fmt` — format the tree (treefmt).
- `cabal build all` — confirm everything builds.
- `cabal test all` (or the specific suites for the released packages, e.g.
  `cabal test kiroku-store-test`).
- `nix flake check` — runs treefmt + pre-commit gates.
  - **Newly created files (e.g. a new CHANGELOG.md) must be `git add`-ed
    before nix evaluation will see them**, since nix builds from the git tree.
  - If any check fails, fix it before proceeding.

### 5. Commit, tag, and push

- Stage the modified `.cabal` and `CHANGELOG.md` files.
- Create one commit with a Conventional Commits message
  (`chore(release): <pkg> <version>[, <pkg> <version>...]`). The body should
  summarize what's in the release and justify each bump.
- Create an **annotated tag per released package**:
  `git tag -a <package>-v<version> -m "<package> <version>"`.
- Push: `git push && git push --tags`.

### 6. Publish to Hackage (in dependency order)

For each released package, in the dependency order listed above:

1. `cd <package-dir>`
2. `cabal check` — fix any packaging issues before uploading.
3. `cabal test <package>` (skip if the package has no test-suite).
4. `cabal sdist`, then `cabal upload --publish <tarball>`.
5. `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`,
   then `cabal upload --publish --documentation <docs-tarball>`.
6. Report the Hackage URL: `https://hackage.haskell.org/package/<package>-<version>`.

After all uploads, present a summary table:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| kiroku-store | X.Y.Z.W | https://hackage.haskell.org/package/kiroku-store-X.Y.Z.W |
| … | | |

### 7. Create GitHub release(s)

For each released package's tag, create a GitHub release:

```bash
gh release create <package>-v<version> \
  --title "<package> v<version>" \
  --notes "$(cat <<'EOF'
## <package> v<version>

Hackage: https://hackage.haskell.org/package/<package>-<version>

## What's Changed

<this version's entries from <package>/CHANGELOG.md>
EOF
)"
```

Report each GitHub release URL when done.

## Important

- **Always ask the user to confirm** the per-package version bumps and
  changelogs before committing.
- **Always publish in dependency order:** kiroku-store → kiroku-store-migrations
  → kiroku-otel → kiroku-cli → shibuya-kiroku-adapter.
- Never skip `cabal check`, tests, or `nix flake check`.
- Run `nix fmt` before committing, and `git add` new files before `nix flake
  check`.
- If any step fails (including `nix flake check`), stop and report rather than
  continuing.
- If a Hackage upload fails for a package, do **not** continue uploading
  packages that depend on it.
- The commit and tags are created only **after** user approval of all changes.
