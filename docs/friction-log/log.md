# Bundle Update Log

## 2026-10-26
* **Update**: FRIC-9 accepted: Keep authentication scoped to an expiring task key and verify its removal on exit.
* **Update**: FRIC-7 resolved: Use an explicit current interpreter when the infrastructure shell places Python 3.13 first.
* **Update**: FRIC-6 resolved: Publish and IAP prerequisites are now explicit in the retained harness instructions.
* **Update**: FRIC-5 accepted: The repository hook passes after restaging its required formatting; no formatter configuration changed.
* **Addition**: FRIC-9 records detour environment friction with mori://shinzui/load-testing-infra: Default operator SSH identity is not usable for cell OS Login
* **Addition**: FRIC-8 records blocked interface friction with mori://shinzui/load-testing-infra: Deployed cell descriptor is incompatible with the available cell client
* **Addition**: FRIC-7 records detour environment friction with mori://shinzui/kiroku: Infrastructure shell Python is too old for the retained cell controller
* **Addition**: FRIC-6 records detour environment friction with mori://shinzui/load-testing-infra: Cell workflow needs infrastructure shell tools on operator PATH
* **Addition**: FRIC-5 records detour tooling friction with mori://shinzui/kiroku: Commit hook reformats edited Haskell files in a different repository style
* **Update**: FRIC-4 resolved: Fix the documented runner instead of carrying a contributor workaround.
* **Addition**: FRIC-4 records nuisance documentation friction with mori://shinzui/kiroku: Plan 54 validation commands name the wrong test runner

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
