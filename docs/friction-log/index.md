---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Plan benchmark commands require the Nix development environment](1-plan-benchmark-commands-require-the-nix-development-environment.md) - The plan bare Cabal command cannot find its required GHC 9.12.4 in the ordinary shell and needs the repository Nix environment.
- [Released Kenshou dependency bounds are bypassed by its assembled Nix cohort](10-released-kenshou-dependency-bounds-are-bypassed-by-its-assembled-nix-cohort.md) - Building the current Kenshou operator required a matched compatibility pin and removal of unrelated runtime suite compilation before namespace evidence could run.
- [Mori manifest type-check fails before the Plan 99 bundle addition](2-mori-manifest-type-check-fails-before-the-plan-99-bundle-addition.md) - The existing mori.dhall dependency helpers do not type-check against their pinned schema, preventing whole-manifest validation of the new friction bundle declaration.
- [Repository formatter rewrites untouched Haskell files](3-repository-formatter-rewrites-untouched-haskell-files.md) - The configured nix fmt defaults differ from the checked-in Haskell style, producing unrelated rewrites while formatting this plan.
- [Plan 54 validation commands name the wrong test runner](4-plan-54-validation-commands-name-the-wrong-test-runner.md) - Plan 54 describes Tasty flags for the current Hspec store suite, requiring source inspection to choose a working focused command.
- [Commit hook reformats edited Haskell files in a different repository style](5-commit-hook-reformats-edited-haskell-files-in-a-different-repository-style.md) - The mandatory treefmt commit hook rewrites the surrounding formatting of edited source files, widening the semantic review and requiring restaging and revalidation.
- [Cell workflow needs infrastructure shell tools on operator PATH](6-cell-workflow-needs-infrastructure-shell-tools-on-operator-path.md) - Direct cell publishing and IAP setup lacked zstd and socat in the ordinary operator shell, delaying the proof before any trial submission.
- [Infrastructure shell Python is too old for the retained cell controller](7-infrastructure-shell-python-is-too-old-for-the-retained-cell-controller.md) - The infrastructure shell selects Python 3.13 while the retained controller calls Python 3.14 uuid.uuid7, causing failure before a lease call and requiring an explicit interpreter during resume.
- [Deployed cell descriptor is incompatible with the available cell client](8-deployed-cell-descriptor-is-incompatible-with-the-available-cell-client.md) - The current infrastructure cell client rejects the deployed alpha descriptor broker field before upload, blocking controlled namespace performance trials.
- [Default operator SSH identity is not usable for cell OS Login](9-default-operator-ssh-identity-is-not-usable-for-cell-os-login.md) - The default SSH identity produced agent parsing errors and cell authentication failures, requiring a temporary registered key before privileged proof setup could run.

