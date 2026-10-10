# Published subscription-hardening cohort

Release commit: `364ffa82136fcfc83d39ead1234abffaf500844b` on master.
Publication uses the user's existing explicit authorization. The bounded
`publish.py` controller completed all 18 source/docs/GitHub actions in dependency
order, with exit code zero and no retry. Reviewed archives and metadata are in
`../ep6-artifacts/`.

| Package | Version | Release |
| --- | --- | --- |
| kiroku-store | 0.10.0.0 | [Hackage](https://hackage.haskell.org/package/kiroku-store-0.10.0.0) |
| kiroku-store-migrations | 0.7.0.0 | [Hackage](https://hackage.haskell.org/package/kiroku-store-migrations-0.7.0.0) |
| kiroku-otel | 0.2.0.11 | [Hackage](https://hackage.haskell.org/package/kiroku-otel-0.2.0.11) |
| kiroku-cli | 0.2.0.9 | [Hackage](https://hackage.haskell.org/package/kiroku-cli-0.2.0.9) |
| kiroku-metrics | 0.2.0.0 | [Hackage](https://hackage.haskell.org/package/kiroku-metrics-0.2.0.0) |
| shibuya-kiroku-adapter | 0.6.0.0 | [Hackage](https://hackage.haskell.org/package/shibuya-kiroku-adapter-0.6.0.0) |

`registry-verification.json` records matching public source hashes, representative
Haddocks and public GitHub release URLs. `tag-proof.json` verifies each remote tag
is annotated and peels to the release commit; the raw remote inventory is retained.

The first normal clean consumer attempt failed while the signed Hackage index
still predated publication. Preserve that attempt in
`index-propagation-first-attempt/`. During propagation an isolated consumer built
and ran against all six exact public HTTPS archives: `consumer-proof.json`,
`consumer-resolved-packages.json` and its build/run logs. No local package sources
or GHC package environment were used.

A later index update reached 2026-10-10T14:41:55Z. With the original single-local-
fixture project and exact version bounds, normal index resolution, build and run
now pass. `consumer-index-proof.json` verifies all six libraries use `repo-tar`
from Hackage at their exact versions; `consumer-index-build.log` and
`consumer-index-run.log` retain the successful commands. Both consumer project
variants are recorded. A helper initially used a relative evidence destination
from the external fixture and failed before changing its project; the subsequent
absolute-path invocation corrected that preparation error.

Performance acceptance remains the user's practical decision documented in
`../ep6-release/practical-acceptance.md`. No strict verdict, adverse sample,
telemetry failure, input fingerprint or statistical uncertainty is rewritten.
No remote experiment or lease remains active.

Downstream adoption is complete in mori://shinzui/keiro at commit `2c3a5389353d290b532cafff14122bf9ab1af79a`, verified
on remote master. Its project-relative evidence folder is
`keiro/bench/results/mp12-kiroku-adoption` (artifact URI pending). Full workspace
build, 719 Keiro examples, 50 Ops examples, strict ADR/user documentation and
native formatting/pre-commit checks pass. `downstream-proof.json` records the
commit and checks. Earlier fixture, schema and invocation failures are retained
in that downstream evidence. No Keiro package release was performed.
