{-# LANGUAGE MultilineStrings #-}

-- | Package-internal SQL for subscription checkpoint lifecycle operations.
module Kiroku.Store.Subscription.Checkpoint.SQL (
    initializeSubscriptionCheckpointSession,
) where

import Contravariant.Extras (contrazip2, contrazip3)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store.Subscription.Types (
    CheckpointInitialization (..),
    MissingCheckpointPolicy (..),
    SubscriptionCheckpointKey (..),
    SubscriptionCheckpointMissing (..),
    SubscriptionName (..),
 )
import Kiroku.Store.Types (GlobalPosition (..))

{- | Resolve one checkpoint key in a Hasql session.

The first statement inserts the policy-selected position with @ON CONFLICT DO
NOTHING@ and then reads the winning row. PostgreSQL can report no row to that
final read when another transaction committed the conflicting insert after the
statement snapshot was taken. For an initializing policy, a second statement
therefore reads the now-committed winner on a fresh snapshot. 'FailIfMissing'
does not retry because it never attempts an insert.
-}
initializeSubscriptionCheckpointSession ::
    SubscriptionName ->
    Int32 ->
    MissingCheckpointPolicy ->
    Session.Session (Either SubscriptionCheckpointMissing CheckpointInitialization)
initializeSubscriptionCheckpointSession subscriptionName@(SubscriptionName name) member policy = do
    first <- Session.statement (name, member, policyCode policy) initializeSubscriptionCheckpointStmt
    case first of
        Just result -> pure (Right (decodeResult result))
        Nothing -> case policy of
            FailIfMissing -> pure (Left missing)
            _ -> do
                -- The insert lost a concurrent unique-key race after this
                -- statement's snapshot. A fresh statement snapshot observes
                -- the committed winner; singleRow turns a violated invariant
                -- into a structured Hasql session error.
                position <- Session.statement (name, member) readInitializedCheckpointStmt
                pure (Right (ExistingCheckpoint key (GlobalPosition position)))
  where
    key = SubscriptionCheckpointKey subscriptionName member
    missing = SubscriptionCheckpointMissing key
    decodeResult (position, inserted)
        | inserted = InitializedCheckpoint policy key (GlobalPosition position)
        | otherwise = ExistingCheckpoint key (GlobalPosition position)

policyCode :: MissingCheckpointPolicy -> Text
policyCode = \case
    FromBeginning -> "from_beginning"
    FromCurrentHead -> "from_current_head"
    FailIfMissing -> "fail_if_missing"

initializeSubscriptionCheckpointStmt :: Statement (Text, Int32, Text) (Maybe (Int64, Bool))
initializeSubscriptionCheckpointStmt =
    preparable
        """
        WITH desired AS (
          SELECT CASE $3
                   WHEN 'from_beginning' THEN 0::bigint
                   WHEN 'from_current_head' THEN (
                     SELECT stream_version FROM streams WHERE stream_id = 0
                   )
                   ELSE NULL::bigint
                 END AS last_seen
        ),
        inserted AS (
          INSERT INTO subscriptions
            (subscription_name, consumer_group_member, last_seen, updated_at)
          SELECT $1, $2, desired.last_seen, now()
          FROM desired
          WHERE desired.last_seen IS NOT NULL
          ON CONFLICT (subscription_name, consumer_group_member) DO NOTHING
          RETURNING last_seen
        )
        SELECT inserted.last_seen, TRUE AS initialized
        FROM inserted
        UNION ALL
        SELECT subscriptions.last_seen, FALSE AS initialized
        FROM subscriptions
        WHERE subscription_name = $1
          AND consumer_group_member = $2
        LIMIT 1
        """
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
            (E.param (E.nonNullable E.text))
        )
        ( D.rowMaybe $
            (,)
                <$> D.column (D.nonNullable D.int8)
                <*> D.column (D.nonNullable D.bool)
        )

readInitializedCheckpointStmt :: Statement (Text, Int32) Int64
readInitializedCheckpointStmt =
    preparable
        """
        SELECT last_seen
        FROM subscriptions
        WHERE subscription_name = $1
          AND consumer_group_member = $2
        """
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
        )
        (D.singleRow (D.column (D.nonNullable D.int8)))
