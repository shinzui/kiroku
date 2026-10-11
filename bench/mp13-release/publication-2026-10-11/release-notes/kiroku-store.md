Hackage: https://hackage.haskell.org/package/kiroku-store-0.11.0.0

### Breaking Changes

- The closed `Store` effect gains `GetStreamWithHead`; exhaustive custom interpreters
  must handle it. `StreamInfo` construction is unchanged.

- `Subscriber` gains `subDropped :: TVar Word64`, counting batches discarded only under `DropOldest`; complete record constructors must supply it.

- The closed `Store` effect gains `ListSubscriptionDeadLetters`; exhaustive custom interpreters must handle it.

- The closed `Store` effect gains `ListStreams`, `ListCategories` and `GetEvent`.
  Custom interpreters must handle them. Catalog limits use validated `BrowsePageSize`.

### New Features

- Opt-in `getStreamWithHead` captures metadata and the newest surviving originated
  global position in one statement. Links and `$all` do not originate a head;
  missing streams and existing streams without a head remain distinguishable.
  Existing metadata/event reads and writes acquire no extra work.

- `subscribePublisherWith` returns `PublisherSubscription`, including the dropped-batch counter and idempotent deregistration; `subscribePublisher` retains its original triple.

- Public `subscriptionDeadLetters` with validated query limits, exclusive composite cursors, and newest-first pages across historical members or one selected member. Structured reasons are unchanged.

- Byte-ordered stream browsing with exact category, literal prefix and exclusive
  name cursors; paged category enumeration and canonical event lookup by id.
