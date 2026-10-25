# Bundle Update Log

## 2026-10-25
* **Update**: FRIC-3 accepted: Correct the earlier mistaken ignored-config diagnosis: git ls-files confirms the configuration is tracked; retain required formatting on edited files and run the normal hook.
* **Update**: FRIC-3 accepted: The commit hook shares the same local override; validate under repository formatting defaults without retaining unrelated rewrites.
* **Update**: FRIC-3 accepted: Keep repository-wide formatting outside Plan 103 while retaining the successful formatter check and recording the local override.
* **Addition**: FRIC-3 records detour tooling friction with mori://shinzui/kiroku: Repository formatter rewrites untouched Haskell files
* **Update**: FRIC-2 accepted: Retain the pre-existing whole-manifest type error without expanding Plan 99 into a schema migration.
* **Addition**: FRIC-2 records detour tooling friction with mori://shinzui/kiroku: Mori manifest type-check fails before the Plan 99 bundle addition
* **Update**: FRIC-1 resolved: Document the working Nix invocation after the plain-shell build failed.
* **Addition**: FRIC-1 records detour documentation friction with mori://shinzui/kiroku: Plan benchmark commands require the Nix development environment
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
