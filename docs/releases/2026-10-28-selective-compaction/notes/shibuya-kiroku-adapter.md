## 0.7.0.1 — 2026-10-28

### Other Changes

- Require `kiroku-store ^>=0.13.0.0` for selective compaction and its expanded event/error surface. The adapter runtime API is unchanged.
- Make the existing concurrent adapter test collector atomic so completed callbacks cannot lose evidence.
