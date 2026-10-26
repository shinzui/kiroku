# Plan 54 Kenshou comparison

Matched payloads adapt the existing inspection producer and separate observer to
Kenshou's run contract and measurement recorder. The original control is
`364ffa82136fcfc83d39ead1234abffaf500844b`; the candidate runtime source is
`94c2839f4b9a51bff2bfead57b8e587389a7875f` (runtime identical to `c5ca341`).
Both arms use the same toolchain, producer, exact-category worker and observer.
Only the candidate constructs `CategoryNamespace "ns"` in the active case.
One percent of producer iterations creates namespace streams; other iterations
alternate existing-stream appends and fresh names. Namespace delivery is checked
against an ordered SQL oracle. Durable append counts and observer delivery are
checked independently. Original-control polling retains its expected 404 contract.

The narrow operator uses the current source of
mori://shinzui/keiro-runtime-kenshou at
`2129bb917da811ef1e90198d91db873cc8d05b7b`. It registers this scenario alongside
Kenshou's non-runtime commands and selftests, without compiling unrelated suites.
The CLI source overlay removes the unused Shibuya bundle; execution, publication,
leases, verification and comparison use Kenshou unchanged. Both payload arms
pin strict-mutable-base 1.1.0.0, within Effectful 2.6.1.0's published `<2` bound.
The upstream package source and release tag were checked before pinning.

The local archive referenced by the lock is an exact `git archive` of the
candidate commit. Reconstruct that archive or override the `kiroku` input with an
immutable checkout of the same commit before building elsewhere.

Build `kenshou-head.operator` locally and both `packages.x86_64-linux` payloads.
Run the controller inside the infrastructure development shell for `socat` and
`zstd`. The controller reads the existing experiment deadline from
`kiroku-store/bench/results/ep54-kenshou/budget.json`; it never renews that budget.
Prepare publishes both payloads, runs the environment proof, verifies collection
and release, then stops the owned instances. Measure runs five interleaved pairs
for each declared case with no replacement trials and the existing zero-slowdown
policy. A stopped or failed session retains its journal for explicit recovery.
