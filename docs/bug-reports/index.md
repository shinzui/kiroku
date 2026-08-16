---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [Migration 0010 cannot apply to an already-bootstrapped PostgreSQL 17 database](migration-0010-unqualified-uuidv7-fails-on-postgresql-17.md) - Migration 0010 defaults history_retention_leases.lease_id to an unqualified uuidv7() while pinning no search_path, so on PostgreSQL 17 it parses only when an earlier migration in the same session happened to leave search_path pointing at the kiroku schema.

