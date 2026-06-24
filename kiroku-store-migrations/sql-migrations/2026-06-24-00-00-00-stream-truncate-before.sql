-- Logical truncate-before marker for close-the-book compaction
-- (ExecPlan docs/plans/65). Per-stream cursor: ordered stream reads return
-- only events whose stream_version >= truncate_before. Default 0 keeps all
-- events (per-stream versions are 1-based). Reversible; the global $all log
-- is never affected. UPDATE on streams is already permitted (soft-delete
-- uses it), so no trigger/GUC changes are needed.
ALTER TABLE kiroku.streams
    ADD COLUMN IF NOT EXISTS truncate_before BIGINT NOT NULL DEFAULT 0;
