---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Plan benchmark commands require the Nix development environment](1-plan-benchmark-commands-require-the-nix-development-environment.md) - The plan bare Cabal command cannot find its required GHC 9.12.4 in the ordinary shell and needs the repository Nix environment.
- [Mori manifest type-check fails before the Plan 99 bundle addition](2-mori-manifest-type-check-fails-before-the-plan-99-bundle-addition.md) - The existing mori.dhall dependency helpers do not type-check against their pinned schema, preventing whole-manifest validation of the new friction bundle declaration.
- [Repository formatter rewrites untouched Haskell files](3-repository-formatter-rewrites-untouched-haskell-files.md) - The configured nix fmt defaults differ from the checked-in Haskell style, producing unrelated rewrites while formatting this plan.
