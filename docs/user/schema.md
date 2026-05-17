# Database Schema

Kiroku stores events in PostgreSQL using three core tables:

- `streams` stores stream identities and their current versions.
- `events` stores immutable event payloads.
- `stream_events` links events into streams, including the global `$all`
  stream and any link streams.

The `subscriptions` table stores durable subscription checkpoints.

The canonical schema lives in
`kiroku-store/sql/schema.sql`. Production deployments should normally apply it
through the `kiroku-store-migrations` package; see
[Schema Migrations](schema-migrations.md).

## Ordering Model

Kiroku reserves `streams.stream_id = 0` for the `$all` stream. Every appended
event receives at least two `stream_events` rows:

- one row for the source stream, where `stream_version` is the event's
  one-based position in that stream;
- one row for `$all`, where `stream_version` is the event's global position.

Global positions are contiguous and gap-free for successful appends. The
`streams.stream_version` value on `$all` is the current global counter.

Linking an event to another stream adds another `stream_events` row for the
target stream. It does not duplicate the `events` row and does not advance the
`$all` counter. Linked events keep their original source stream and original
source version in `original_stream_id` and `original_stream_version`.

## `streams`

`streams` contains one row per stream, including the internal `$all` stream.

| Column | Type | Meaning |
| --- | --- | --- |
| `stream_id` | `BIGSERIAL PRIMARY KEY` | Surrogate stream id. The `$all` stream is always `0`; application streams receive generated ids. |
| `stream_name` | `TEXT NOT NULL UNIQUE` | Human-readable stream name, such as `orders-123`. The exact name `$all` is reserved for the global stream. |
| `category` | `TEXT GENERATED ALWAYS AS (...) STORED` | Generated prefix before the first `-` in `stream_name`. For `orders-123`, the category is `orders`. Used by category reads and category subscriptions. |
| `stream_version` | `BIGINT NOT NULL DEFAULT 0` | Current event count for the stream. After `N` appended or linked events, the version is `N`; the first event has version `1`. On `$all`, this is the latest global position. |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | Timestamp when the stream row was created. |
| `deleted_at` | `TIMESTAMPTZ` | `NULL` for live streams. Set by soft delete. Soft-deleted streams are hidden from direct stream reads and appends, but their events remain visible in `$all` and category reads. |

## `events`

`events` contains the immutable event payload. Stream membership is not stored
here; it is stored in `stream_events`.

| Column | Type | Meaning |
| --- | --- | --- |
| `event_id` | `UUID PRIMARY KEY DEFAULT uuidv7()` | Stable event id. Kiroku uses UUIDv7 by default. PostgreSQL 18 provides `pg_catalog.uuidv7()`; PostgreSQL 17 uses Kiroku's schema-managed fallback function. Callers may also provide ids for idempotent retries. |
| `event_type` | `TEXT NOT NULL` | Application-level event discriminator, such as `OrderCreated`. Kiroku stores and indexes it but does not interpret it. |
| `causation_id` | `UUID` | Optional id of the event that directly caused this event. Used for causation-chain queries. |
| `correlation_id` | `UUID` | Optional id shared by events in the same workflow, request, saga, or transaction. Used for correlation queries. |
| `data` | `JSONB NOT NULL` | Event payload. |
| `metadata` | `JSONB` | Optional event metadata, commonly used for tenant ids, tracing context, request metadata, or application-specific annotations. |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | Event creation timestamp recorded at append time. |

`events` is append-only during normal operation. The schema installs a trigger
that rejects updates. Deletes are also blocked unless the session sets the
maintenance GUC described in [Deletes And Truncates](#deletes-and-truncates).

## `stream_events`

`stream_events` is the junction table that places events into streams.

| Column | Type | Meaning |
| --- | --- | --- |
| `event_id` | `UUID NOT NULL REFERENCES events(event_id)` | Event payload referenced by this stream entry. |
| `stream_id` | `BIGINT NOT NULL REFERENCES streams(stream_id)` | Stream containing this entry. `0` means the `$all` stream. |
| `stream_version` | `BIGINT NOT NULL` | Position of the entry within `stream_id`. For `$all`, this is the global position. For link streams, this is the link target's position. |
| `original_stream_id` | `BIGINT NOT NULL` | Source stream where the event was first appended. For source-stream and `$all` rows, this is the source stream id. For link rows, it remains the original source stream id. |
| `original_stream_version` | `BIGINT NOT NULL` | Event's original position in its source stream. For link rows, this differs from the target stream's `stream_version`. |

The primary key is `(event_id, stream_id)`. This means one event can appear at
most once in a given stream, but it can appear in multiple streams through
links.

## `subscriptions`

`subscriptions` stores durable checkpoints for Kiroku subscriptions.

| Column | Type | Meaning |
| --- | --- | --- |
| `subscription_id` | `BIGSERIAL PRIMARY KEY` | Surrogate id for the checkpoint row. |
| `subscription_name` | `TEXT NOT NULL UNIQUE` | Stable subscription name. This is the lookup key used by checkpoint reads and writes. |
| `stream_name` | `TEXT NOT NULL DEFAULT '$all'` | Stored target stream name. The current checkpoint helpers write only `subscription_name` and `last_seen`, so this defaults to `$all`. |
| `last_seen` | `BIGINT NOT NULL DEFAULT 0` | Last processed global position. Checkpoint updates use `GREATEST(existing, new)` so the checkpoint does not move backward. |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | Timestamp when the checkpoint row was first created. |
| `updated_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | Timestamp of the latest checkpoint write. |

Subscriptions use `$all` global positions as their cursor, including category
subscriptions.

## Indexes

| Index | Table | Purpose |
| --- | --- | --- |
| `ix_streams_stream_name` | `streams(stream_name)` | Enforces unique stream names and supports stream lookup. |
| `ix_streams_category` | `streams(category)` | Supports category reads and category subscriptions. |
| `ix_stream_events_stream_version` | `stream_events(stream_id, stream_version)` | Primary ordered read path for a stream. |
| `ix_stream_events_all_by_origin` | `stream_events(original_stream_id, stream_version) WHERE stream_id = 0` | Supports category reads by joining source streams to their `$all` entries in global order. |
| `ix_events_event_type` | `events(event_type)` | Supports event-type filtering. |
| `ix_events_correlation_id` | `events(correlation_id) WHERE correlation_id IS NOT NULL` | Supports correlation lookups. |
| `ix_events_causation_id` | `events(causation_id) WHERE causation_id IS NOT NULL` | Supports causation-chain lookups. |

## Triggers And Functions

The schema installs these database functions and triggers:

- `uuidv7()` fallback: installed only when PostgreSQL does not already expose
  a UUIDv7 function. This keeps `events.event_id DEFAULT uuidv7()` usable on
  PostgreSQL 17.
- `notify_events()` and `stream_events_notify`: sends a PostgreSQL `NOTIFY`
  after `streams` rows are inserted or updated. The notification payload is
  `stream_name,stream_id,stream_version`. Kiroku subscriptions use this to wake
  up when appends advance a stream.
- `prevent_mutation()` with `no_update_events` and `no_update_stream_events`:
  rejects updates to immutable event tables.
- `protect_deletion()` and `protect_truncation()`: reject direct deletes and
  truncates unless hard deletes are explicitly enabled for the transaction.

## Deletes And Truncates

Soft delete sets `streams.deleted_at`. It hides the stream from direct stream
reads and appends, but keeps event history in `$all`.

Hard delete is intended for maintenance or GDPR-style cleanup. Kiroku's
interpreter enables it inside the transaction with:

```sql
SET LOCAL kiroku.enable_hard_deletes = 'on';
```

Without that setting, direct `DELETE` and `TRUNCATE` statements against
`events`, `stream_events`, and `streams` fail. This is an accident-prevention
mechanism, not a role-based security boundary: a database role with delete
privileges can also set the GUC. Production deployments that need stricter
control should withhold `DELETE` privileges from normal application roles and
run hard deletes through a separate privileged path.
