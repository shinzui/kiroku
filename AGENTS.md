# Performance experiments

- Start with the minimum evidence needed for the actual change: existing valid
  correctness tests, structural invariants and a focused comparison of an affected
  path. Do not turn a small metadata or startup change into a statistical study.
  Increase coverage or precision only to answer a specific unresolved regression
  risk or investigate a consistent adverse signal. A runtime budget is a ceiling,
  not a target to fill. Honor the user's smaller evidence scope.
- Select coverage from the code paths changed and the regression risk. Reuse
  existing benchmark infrastructure and valid evidence. Do not default to a
  full configuration or database-version matrix.
- Before remote runs, report the selected cases, trial count, warmup and
  measurement durations, total runtime estimate, uncertainty target and stop
  conditions. Include calibration, reset/setup overhead and possible escalation;
  do not describe the duration of one trial as the duration of the experiment.
- Use a 60-minute wall-clock budget by default, unless the user has established
  another budget. It covers the whole experiment, including setup, recovery and
  repeats. Pass the remaining budget to subsequent stages; do not reset the
  clock by chaining commands or restarting a controller. If the desired precision
  cannot fit, report the conflict before launching the queue and choose a smaller
  useful experiment or leave acceptance inconclusive. Never silently weaken a gate.
- Prove submission, result verification and lease release with a small run before
  expanding coverage. Reuse an existing verified run for recovery checks when possible.
- Use a persistent, bounded controller with retained logs and journals. A PID,
  heartbeat or cached `running` flag is not proof of progress. Check the current
  remote run's phase, instance power state and verified-trial count. Stop and
  report if progress or wall-clock deadlines expire; do not retry indefinitely.
- Resume the owned journal, start stopped instances and release the owned lease
  on every exit. Preserve completed samples and validate their inputs; never
  replace an interrupted sample with an unreported favorable retry.
- When reporting status, distinguish functional completion, verified trial counts,
  active remote execution, inconclusive evidence and accepted performance results.
