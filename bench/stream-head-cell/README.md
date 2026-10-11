# Stream-head cell evidence

This isolated package runs the exact `StreamHeadCost.hs` and `RegressionGate.hs`
actions from a pinned Kiroku commit. It replaces only test-database lifecycle:
the cell creates five disposable PostgreSQL 18 databases and owns their reset and
cleanup. No production code changes or ephemeral PostgreSQL on the driver are used.

Infrastructure belongs to `mori://shinzui/load-testing-infra`; project-relative
`scripts/cell/` and `nixos/pkgs/cell-agent/src/` supply lifecycle scripts and `cellctl`
(artifact-level URIs pending). The package set reuses the existing pinned input
from `mori://shinzui/keiro-runtime-kenshou`. `run.py` scopes GCP project selection
to its subprocesses, holds only its own lease and retains one immutable journal
per stage. Re-running the same stage resumes/collects that run, never substitutes
a new favorable trial. It checks actual remote phase, power states and verified
trial count. Every exit after acquisition releases and checks the owned lease.

The controller requires Python 3.14 (UUIDv7), the current `cellctl`, and authenticated
`gcloud` access. Build with a full local committed revision, so unrelated working-tree changes
cannot enter the payload:

```bash
nix build path:./bench/stream-head-cell#packages.x86_64-linux.default \
  --override-input kiroku "git+file://$PWD?rev=<full-candidate-revision>" \
  --out-link /tmp/ep97-cell-payload --print-out-paths
```

Publish the result with `cellctl payload-publish --store-path <build-result>
--entry bin/stream-head-cell`. The publisher requires `zstd`; use the already
pinned nixpkgs package through `nix shell` if absent. The lock's local Git URL is
an evidence input; override it with the current checkout when reproducing.

Before any submission, report the complete scope, estimated runtime, uncertainty
and stop policy required by repository AGENTS.md. Pass the original experiment's
UTC start file; the 60-minute budget is never restarted by a new stage. Run `proof`,
verify results and lease release, then `head` and `gate` sequentially. `head` has
six cases (100 warmup calls each, batches of 100, 5% deviation, 60 seconds per case).
`gate` is the existing 16-case append/category comparison without changed thresholds.

```bash
python3 bench/stream-head-cell/run.py --kind proof \
  --cellctl <cellctl-executable> --infra <infrastructure-checkout> \
  --payload <published-payload.json> --started <original-started.txt> \
  --out <new-or-owned-proof-directory>
```

Substitute `head` or `gate` and a distinct owned directory for subsequent stages.
Use `--wait-seconds <bound>` to wait for another owner without interfering.
`--keep-running` skips power-down between sequential stages but still releases and
verifies the owned lease. Omit it for the final stage; verify final power state.
A newly acquired lease is required before any later stage.
Preserve every journal, controller log and fetched tree. A nonzero benchmark exit,
missing result or missed precision target is not acceptance. The aggregate's
structural checks are run by the repository's local full test suite; moving only
its timing half avoids measuring on a busy developer machine.
