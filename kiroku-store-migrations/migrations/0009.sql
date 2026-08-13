-- Publish the frozen, owner-rights, structurally read-only v1 checkpoint relation.
CREATE VIEW kiroku.subscription_checkpoints_v1
    (subscription_name,
     consumer_group_member,
     checkpoint_position,
     checkpoint_updated_at)
WITH (security_invoker = false)
AS
WITH checkpoint_rows AS NOT MATERIALIZED (
    SELECT subscription_name,
           consumer_group_member,
           last_seen AS checkpoint_position,
           updated_at AS checkpoint_updated_at
    FROM kiroku.subscriptions
)
SELECT subscription_name,
       consumer_group_member,
       checkpoint_position,
       checkpoint_updated_at
FROM checkpoint_rows;

COMMENT ON VIEW kiroku.subscription_checkpoints_v1 IS
  'Stable read-only v1 relation of exact persisted subscription-member checkpoints; its columns and order are frozen, and its rows are unordered unless the caller supplies ORDER BY.';

COMMENT ON COLUMN kiroku.subscription_checkpoints_v1.subscription_name IS
  'Persisted subscription name; member zero does not distinguish a non-group subscription from member zero of a consumer group.';

COMMENT ON COLUMN kiroku.subscription_checkpoints_v1.consumer_group_member IS
  'Persisted consumer-group member key; member zero carries no topology classification.';

COMMENT ON COLUMN kiroku.subscription_checkpoints_v1.checkpoint_position IS
  'Exact persisted global position for this subscription member; an explicit reset may move it backward or forward.';

COMMENT ON COLUMN kiroku.subscription_checkpoints_v1.checkpoint_updated_at IS
  'Time of the latest checkpoint-row upsert; it does not imply position advancement or worker liveness.';
