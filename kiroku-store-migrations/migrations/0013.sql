-- Derive consumer-group topology from existing member checkpoints.
-- Stop all subscription workers before applying this migration.
-- An incomplete legacy row set derives an underestimate: startup refuses the
-- configured topology until the operator explicitly equalizes it with resize.
UPDATE kiroku.subscriptions AS s
SET consumer_group_size = derived.size
FROM (
    SELECT subscription_name, max(consumer_group_member) + 1 AS size
    FROM kiroku.subscriptions
    GROUP BY subscription_name
) AS derived
WHERE s.subscription_name = derived.subscription_name
  AND s.consumer_group_size <> derived.size;
