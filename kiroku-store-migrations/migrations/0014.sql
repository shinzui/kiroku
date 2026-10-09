-- bind subscription checkpoints to their targets


-- Stop subscription workers before applying this catalog change and CHECK scan.
-- Constant defaults preserve legacy rows without a heap rewrite.
ALTER TABLE kiroku.subscriptions
    ADD COLUMN target_kind TEXT NOT NULL DEFAULT 'unbound'
        CHECK (target_kind IN ('unbound', 'all', 'category')),
    ADD COLUMN target_category TEXT
        CHECK ((target_kind = 'category') = (target_category IS NOT NULL)),
    DROP COLUMN stream_name;
