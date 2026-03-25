# Changelog

## 0.1.0.0 — 2026-03-24

* Initial release.
* `kirokuAdapter` — create a Shibuya `Adapter es RecordedEvent` from a
  Kiroku store handle and subscription configuration.
* `KirokuAdapterConfig` — subscription name, target, batch size, and
  TBQueue buffer size.
* Ack semantics: AckOk/AckRetry/AckDeadLetter are no-ops (checkpoint
  managed by Kiroku); AckHalt cancels the subscription.
* `Shibuya.Adapter.Kiroku.Convert` — RecordedEvent to Envelope mapping.
