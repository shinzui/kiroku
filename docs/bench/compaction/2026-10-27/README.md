# Selective compaction sizing and unchanged-path gate

The local sizing probe runs the real public apply effect once at each of 10,000,
50,000 and 100,000 selections against a fresh cloned database. Each fixture has
256-byte payload strings, one origin stream, 10% linked memberships in one target
stream and 10% dead letters. Seeding warms the tables; there are no extra warmup
applies. Setup and compilation are excluded from the reported apply duration but
included in the whole-experiment budget.

| Selections | Links / dead letters | Apply wall seconds | Microseconds per selection |
|---:|---:|---:|---:|
| 10,000 | 1,000 / 1,000 | 0.207270 | 20.727 |
| 50,000 | 5,000 / 5,000 | 1.179964 | 23.599 |
| 100,000 | 10,000 / 10,000 | 2.352701 | 23.527 |

Apply wall time includes acquisition, transaction and commit overhead. It is a
conservative upper bound on coordinator hold time, not an instrumented exact
lock duration. Every case checks counts, the stored report digest, ledger equality
and idempotent reapply. These are single sizing observations, with no claimed
statistical uncertainty or deployment latency guarantee. They support retaining
the 100,000-selection ceiling and starting operational chunks at 10,000, grouped
by stream and measured well inside the deployment's lease-renewal margin.

The unchanged `just perf-workload-gate` is recorded separately in `workload.log`
and `workload.csv`; its existing ratio and spread gates remain authoritative.
`budget.json` preserves one 60-minute deadline across stages. `sources.json`
records source hashes and host platform. `sizing.csv` and `sizing.log` preserve all
three measurements. `sizing-build-attempt.log` preserves an initial numeric-type
compile error; it produced no timing sample. No sample was replaced or discarded.

Reproduce from this checkout in its Nix development shell:

```bash
cabal bench kiroku-store:kiroku-compaction-cost --benchmark-options='+RTS -N2 -RTS'
just perf-workload-gate
```

No remote execution or lease was used for this local experiment.

The unchanged workload gate passed all 17 cases; every compared arm met its
20% doubled-standard-deviation spread bound. Reported comparison ratios:

- candidate-append-40x32:                  OK 116  ms ± 1.0 ms, 0.98x
- production-pipeline-4:                   OK 325  μs ± 5.2 μs, 0.84x
- production-pipeline-8:                   OK 575  μs ±  40 μs, 0.84x
- candidate-exhausted-category:            OK 552  μs ±  26 μs, 0.38x
- candidate-page-200-streams-from-0:       OK 5.24 ms ± 445 μs, 0.03x
- candidate-page-20000-streams-from-0:     OK 5.13 ms ± 431 μs, 0.02x
- candidate-plain-caught-up-20000-streams: OK 558  μs ±  55 μs, 0.01x
- candidate-group-caught-up-20000-streams: OK 688  μs ±  58 μs, 0.01x
