# kiroku-store-migrations v0.7.0.0

Hackage: https://hackage.haskell.org/package/kiroku-store-migrations-0.7.0.0

### Breaking Changes

* Migration 0014 adds checked, unindexed subscription target-binding columns and
  removes the unused `stream_name` column. Stop subscription workers before
  applying the cohort's migrations and restart with kiroku-store 0.10.0.0.
  Constant defaults do not rewrite legacy rows.

### New Features

* Migration 0013 derives persisted consumer-group size from existing member rows.
  Incomplete legacy groups refuse on next startup until explicitly resized to
  the intended topology. Both migrations are included in the embedded manifest.
