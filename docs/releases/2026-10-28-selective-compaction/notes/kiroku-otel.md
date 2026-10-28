## 0.3.0.1 — 2026-10-28

### Other Changes

* Explicitly ignore apply/already-applied maintenance events in subscription
  telemetry; durable compaction evidence remains in the store ledger.

* Handle compaction preview/refusal events explicitly without changing the
  published subscription tracing or metrics schema.

- Require `kiroku-store ^>=0.13.0.0`; the public telemetry/HTTP schema is unchanged.
