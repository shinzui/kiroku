{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Package-internal SQL for subscription checkpoint lifecycle operations.
module Kiroku.Store.Subscription.Checkpoint.SQL (
    initializeSubscriptionCheckpointSession,
    initializeWorkerCheckpointSession,
    lockCheckpointNameStmt,
    lockCheckpointRowsStmt,
    resizeCheckpointMembersStmt,
    resetSubscriptionCheckpointsStmt,
    targetColumns,
    rebindCheckpointTargetStmt,
) where

import Contravariant.Extras (contrazip2, contrazip4, contrazip5, contrazip6)
import Data.Int (Int32, Int64)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store.Subscription.Types (
    CheckpointInitialization (..),
    ConsumerGroupSizeMismatch (..),
    MissingCheckpointPolicy (..),
    SomeSubscriptionStartupFailure (..),
    SubscriptionCheckpointKey (..),
    SubscriptionCheckpointMissing (..),
    SubscriptionName (..),
    SubscriptionTarget (..),
    SubscriptionTargetMismatch (..),
    TargetBindingPolicy (..),
 )
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..))

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
initializeSubscriptionCheckpointSession name member policy =
    initializeCheckpointWith Session.statement name member 1 Nothing policy

{- | Startup-only validation and insertion share one checkout and one transaction.
The name lock serializes competing topologies, including an initially absent
row set. It is never acquired by ordinary checkpoint saves or event appends.
-}
initializeWorkerCheckpointSession ::
    SubscriptionName ->
    Int32 ->
    Int32 ->
    SubscriptionTarget ->
    TargetBindingPolicy ->
    MissingCheckpointPolicy ->
    Session.Session (Either SomeSubscriptionStartupFailure (CheckpointInitialization, Bool))
initializeWorkerCheckpointSession subscriptionName@(SubscriptionName name) member configured target bindingPolicy policy =
    TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write $ do
        Tx.statement name lockCheckpointNameStmt
        rows <- Tx.statement name readCheckpointRowsStmt
        let sizes = Vector.fromList . sort . nub . fmap (\(_, n, _, _) -> n) $ Vector.toList rows
            bindings = Vector.fromList . nub $ [binding | (_, _, _, binding) <- Vector.toList rows]
            unbound = not (Vector.null rows) && bindings == Vector.singleton Nothing
            matches = Vector.all (== Just target) bindings
        if Vector.any (/= configured) sizes
            then pure (Left (SomeSubscriptionStartupFailure (ConsumerGroupSizeMismatch subscriptionName configured sizes)))
            else
                if not matches && not (unbound && bindingPolicy == AdoptUnbound)
                    then pure (Left (SomeSubscriptionStartupFailure (SubscriptionTargetMismatch subscriptionName target bindings)))
                    else do
                        -- Check exact-key absence before adoption so a refused startup never
                        -- mutates sibling bindings. Both operations share the name lock.
                        resolution <- initializeCheckpointWith Tx.statement subscriptionName member configured (Just target) policy
                        case resolution of
                            Left missing -> pure (Left (SomeSubscriptionStartupFailure missing))
                            Right initialized -> do
                                if unbound then Tx.statement (name, targetColumns (Just target)) adoptCheckpointTargetStmt else pure ()
                                pure (Right (initialized, unbound))

initializeCheckpointWith ::
    (Monad m) =>
    (forall a b. a -> Statement a b -> m b) ->
    SubscriptionName ->
    Int32 ->
    Int32 ->
    Maybe SubscriptionTarget ->
    MissingCheckpointPolicy ->
    m (Either SubscriptionCheckpointMissing CheckpointInitialization)
initializeCheckpointWith statement subscriptionName@(SubscriptionName name) member groupSize binding policy = do
    first <- statement (name, member, policyCode policy, groupSize, fst (targetColumns binding), snd (targetColumns binding)) initializeSubscriptionCheckpointStmt
    case first of
        Just result -> pure (Right (decodeResult result))
        Nothing -> case policy of
            FailIfMissing -> pure (Left missing)
            _ -> do
                -- The insert lost a concurrent unique-key race after this
                -- statement's snapshot. A fresh statement snapshot observes
                -- the committed winner; singleRow turns a violated invariant
                -- into a structured Hasql session error.
                position <- statement (name, member) readInitializedCheckpointStmt
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

initializeSubscriptionCheckpointStmt :: Statement (Text, Int32, Text, Int32, Text, Maybe Text) (Maybe (Int64, Bool))
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
            (subscription_name, consumer_group_member, last_seen, updated_at, consumer_group_size, target_kind, target_category)
          SELECT $1, $2, desired.last_seen, now(), $4, $5, $6
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
        ( contrazip6
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
            (E.param (E.nonNullable E.text))
            (E.param (E.nullable E.text))
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

{- | Reset every persisted member belonging to the requested subscription
names. The input is treated as a set by PostgreSQL. Each returned row contains
either one reset member or a requested name with no persisted rows, and the
result is deterministically ordered by name and member.

This statement deliberately assigns @last_seen@ directly. Ordinary worker
saves retain their separate @GREATEST(...)@ monotonicity contract.
-}
resetSubscriptionCheckpointsStmt ::
    Statement (Vector Text, Int64) (Vector (Text, Maybe Int32))
resetSubscriptionCheckpointsStmt =
    preparable
        """
        WITH requested AS (
          SELECT DISTINCT requested_name AS subscription_name
          FROM unnest($1::text[]) AS requested_name
        ),
        updated AS (
          UPDATE subscriptions AS checkpoint
          SET last_seen = $2, updated_at = now()
          FROM requested
          WHERE checkpoint.subscription_name = requested.subscription_name
          RETURNING checkpoint.subscription_name, checkpoint.consumer_group_member
        )
        SELECT requested.subscription_name, updated.consumer_group_member
        FROM requested
        LEFT JOIN updated USING (subscription_name)
        ORDER BY requested.subscription_name, updated.consumer_group_member
        """
        ( contrazip2
            (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
            (E.param (E.nonNullable E.int8))
        )
        ( D.rowVector $
            (,)
                <$> D.column (D.nonNullable D.text)
                <*> D.column (D.nullable D.int4)
        )

-- | A separate key domain from the optional member guard.
lockCheckpointNameStmt :: Statement Text ()
lockCheckpointNameStmt =
    preparable
        "SELECT pg_advisory_xact_lock(hashtextextended('kiroku:checkpoint-topology:' || $1, 0))"
        (E.param (E.nonNullable E.text))
        D.noResult

readCheckpointRowsStmt :: Statement Text (Vector (Int32, Int32, Int64, Maybe SubscriptionTarget))
readCheckpointRowsStmt = checkpointRowsStmt ""

lockCheckpointRowsStmt :: Statement Text (Vector (Int32, Int32, Int64, Maybe SubscriptionTarget))
lockCheckpointRowsStmt = checkpointRowsStmt " FOR UPDATE"

checkpointRowsStmt :: Text -> Statement Text (Vector (Int32, Int32, Int64, Maybe SubscriptionTarget))
checkpointRowsStmt suffix =
    preparable
        ("SELECT consumer_group_member, consumer_group_size, last_seen, target_kind, target_category FROM subscriptions WHERE subscription_name = $1 ORDER BY consumer_group_member" <> suffix)
        (E.param (E.nonNullable E.text))
        (D.rowVector ((,,,) <$> D.column (D.nonNullable D.int4) <*> D.column (D.nonNullable D.int4) <*> D.column (D.nonNullable D.int8) <*> targetBindingRow))

{- | Keep existing row identities, equalize every new member, remove obsolete
members. Caller already holds the name and row locks; workers must be stopped.
-}
resizeCheckpointMembersStmt :: Statement (Text, Int32, Int64, Text, Maybe Text) ()
resizeCheckpointMembersStmt =
    preparable
        """
        WITH removed AS (
          DELETE FROM subscriptions
          WHERE subscription_name = $1 AND consumer_group_member >= $2
        )
        INSERT INTO subscriptions
          (subscription_name, consumer_group_member, consumer_group_size, last_seen, updated_at, target_kind, target_category)
        SELECT $1, member, $2, $3, now(), $4, $5 FROM generate_series(0, $2 - 1) AS member
        ON CONFLICT (subscription_name, consumer_group_member) DO UPDATE
        SET consumer_group_size = EXCLUDED.consumer_group_size,
            last_seen = EXCLUDED.last_seen, updated_at = now()
        """
        ( contrazip5
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.text))
            (E.param (E.nullable E.text))
        )
        D.noResult

-- | One encoder for every checkpoint target write, including legacy provisioning.
targetColumns :: Maybe SubscriptionTarget -> (Text, Maybe Text)
targetColumns Nothing = ("unbound", Nothing)
targetColumns (Just AllStreams) = ("all", Nothing)
targetColumns (Just (Category (CategoryName category))) = ("category", Just category)

-- The CHECK constraints make this decoder total over valid database rows.
targetBindingRow :: D.Row (Maybe SubscriptionTarget)
targetBindingRow = decode <$> D.column (D.nonNullable D.text) <*> D.column (D.nullable D.text)
  where
    decode "all" Nothing = Just AllStreams
    decode "category" (Just category) = Just (Category (CategoryName category))
    decode _ _ = Nothing

adoptCheckpointTargetStmt :: Statement (Text, (Text, Maybe Text)) ()
adoptCheckpointTargetStmt =
    preparable
        "UPDATE subscriptions SET target_kind = $2, target_category = $3 WHERE subscription_name = $1"
        (contrazip2 (E.param (E.nonNullable E.text)) (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nullable E.text))))
        D.noResult

-- A singleRow decoder refuses an absent name and aborts the surrounding transaction.
rebindCheckpointTargetStmt :: Statement (Text, Text, Maybe Text, Int64) Int64
rebindCheckpointTargetStmt =
    preparable
        """
        WITH rebound AS (
          UPDATE subscriptions
          SET target_kind = $2, target_category = $3, last_seen = $4, updated_at = now()
          WHERE subscription_name = $1
          RETURNING subscription_id
        )
        SELECT count(*) FROM rebound HAVING count(*) > 0
        """
        (contrazip4 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.text)) (E.param (E.nullable E.text)) (E.param (E.nonNullable E.int8)))
        (D.singleRow (D.column (D.nonNullable D.int8)))
