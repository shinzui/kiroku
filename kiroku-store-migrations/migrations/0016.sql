-- Allow category namespace subscription targets. Stop workers during cutover.
-- These are the generated constraint names from migration 0014 on PG 17/18.
-- Only subscription metadata changes; no event/stream index or append work.
ALTER TABLE kiroku.subscriptions
    DROP CONSTRAINT subscriptions_target_kind_check,
    DROP CONSTRAINT subscriptions_check,
    ADD CONSTRAINT subscriptions_target_kind_check
        CHECK (target_kind IN ('unbound', 'all', 'category', 'category_namespace')),
    ADD CONSTRAINT subscriptions_check
        CHECK ((target_kind IN ('category', 'category_namespace')) = (target_category IS NOT NULL));

COMMENT ON SCHEMA kiroku IS
    'Managed by pg-migrate component kiroku through 0016';
