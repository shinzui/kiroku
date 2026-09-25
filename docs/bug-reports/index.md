---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [Migration 0010 cannot apply to an already-bootstrapped PostgreSQL 17 database](migration-0010-unqualified-uuidv7-fails-on-postgresql-17.md) - Migration 0010 defaults history_retention_leases.lease_id to an unqualified uuidv7() while pinning no search_path, so on PostgreSQL 17 it parses only when an earlier migration in the same session happened to leave search_path pointing at the kiroku schema.
- [Partitioned category reads visit every stream in the category on every poll](partitioned-category-read-scans-every-stream-in-the-category.md) - readCategoryForwardConsumerGroupSQL starts from every stream of the category and probes stream_events for each, so a poll that returns one event, or none, costs work proportional to the number of streams ever written in the category. In a consumer with one stream per entity it becomes most of the database's time and keeps growing with every entity created.
- [Publisher position thunk retains append results without all-stream subscribers](publisher-position-thunk-retains-append-results-without-all-subscribers.md) - The empty-subscriber publisher path stores an unevaluated max in its position TVar, retaining a chain of Hasql results and large objects as events are appended.
