{-# LANGUAGE MultilineStrings #-}

module Kiroku.Store.Subscription.DeadLetter.SQL (
    listSubscriptionDeadLettersSession,
    listSubscriptionDeadLettersStmt,
    listSubscriptionDeadLettersFromStartStmt,
    listSubscriptionMemberDeadLettersStmt,
    listSubscriptionMemberDeadLettersFromStartStmt,
) where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store.Subscription.Types
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))

listSubscriptionDeadLettersFromStartStmt :: Statement (Text, Int32) (Vector SubscriptionDeadLetter)
listSubscriptionDeadLettersFromStartStmt =
    preparable
        """
        WITH RECURSIVE members(member) AS (
            SELECT (SELECT consumer_group_member FROM dead_letters
                    WHERE subscription_name = $1 ORDER BY consumer_group_member LIMIT 1)
            UNION ALL
            SELECT (SELECT consumer_group_member FROM dead_letters
                    WHERE subscription_name = $1 AND consumer_group_member > m.member
                    ORDER BY consumer_group_member LIMIT 1)
            FROM members m WHERE m.member IS NOT NULL
        )
        SELECT d.dead_letter_id, d.subscription_name, d.consumer_group_member, d.global_position, d.event_id, d.reason, d.reason_summary, d.attempt_count, d.created_at
        FROM members m
        CROSS JOIN LATERAL (
        SELECT dead_letter_id, subscription_name, consumer_group_member, global_position, event_id, reason, reason_summary, attempt_count, created_at
        FROM dead_letters
        WHERE subscription_name = $1 AND consumer_group_member = m.member

        ORDER BY global_position DESC, dead_letter_id DESC LIMIT $2
        ) d
        WHERE m.member IS NOT NULL
        ORDER BY d.global_position DESC, d.dead_letter_id DESC LIMIT $2
        """
        (contrazip2 text int4)
        (D.rowVector deadLetterRow)

listSubscriptionDeadLettersStmt :: Statement (Text, Int64, Int64, Int32) (Vector SubscriptionDeadLetter)
listSubscriptionDeadLettersStmt =
    preparable
        """
        WITH RECURSIVE members(member) AS (
            SELECT (SELECT consumer_group_member FROM dead_letters
                    WHERE subscription_name = $1 ORDER BY consumer_group_member LIMIT 1)
            UNION ALL
            SELECT (SELECT consumer_group_member FROM dead_letters
                    WHERE subscription_name = $1 AND consumer_group_member > m.member
                    ORDER BY consumer_group_member LIMIT 1)
            FROM members m WHERE m.member IS NOT NULL
        )
        SELECT d.dead_letter_id, d.subscription_name, d.consumer_group_member, d.global_position, d.event_id, d.reason, d.reason_summary, d.attempt_count, d.created_at
        FROM members m
        CROSS JOIN LATERAL (
        SELECT dead_letter_id, subscription_name, consumer_group_member, global_position, event_id, reason, reason_summary, attempt_count, created_at
        FROM dead_letters
        WHERE subscription_name = $1 AND consumer_group_member = m.member
        AND (global_position, dead_letter_id) < ($2, $3)
        ORDER BY global_position DESC, dead_letter_id DESC LIMIT $4
        ) d
        WHERE m.member IS NOT NULL
        ORDER BY d.global_position DESC, d.dead_letter_id DESC LIMIT $4
        """
        (contrazip4 text int8 int8 int4)
        (D.rowVector deadLetterRow)

listSubscriptionMemberDeadLettersFromStartStmt :: Statement (Text, Int32, Int32) (Vector SubscriptionDeadLetter)
listSubscriptionMemberDeadLettersFromStartStmt =
    preparable
        """
        SELECT dead_letter_id, subscription_name, consumer_group_member, global_position, event_id, reason, reason_summary, attempt_count, created_at
        FROM dead_letters
        WHERE subscription_name = $1 AND consumer_group_member = $2

        ORDER BY global_position DESC, dead_letter_id DESC LIMIT $3
        """
        (contrazip3 text int4 int4)
        (D.rowVector deadLetterRow)

listSubscriptionMemberDeadLettersStmt :: Statement (Text, Int32, Int64, Int64, Int32) (Vector SubscriptionDeadLetter)
listSubscriptionMemberDeadLettersStmt =
    preparable
        """
        SELECT dead_letter_id, subscription_name, consumer_group_member, global_position, event_id, reason, reason_summary, attempt_count, created_at
        FROM dead_letters
        WHERE subscription_name = $1 AND consumer_group_member = $2
        AND (global_position, dead_letter_id) < ($3, $4)
        ORDER BY global_position DESC, dead_letter_id DESC LIMIT $5
        """
        (contrazip5 text int4 int8 int8 int4)
        (D.rowVector deadLetterRow)

text :: E.Params Text
text = E.param (E.nonNullable E.text)
int4 :: E.Params Int32
int4 = E.param (E.nonNullable E.int4)
int8 :: E.Params Int64
int8 = E.param (E.nonNullable E.int8)

deadLetterRow :: D.Row SubscriptionDeadLetter
deadLetterRow =
    SubscriptionDeadLetter
        <$> D.column (D.nonNullable D.int8)
        <*> (SubscriptionName <$> D.column (D.nonNullable D.text))
        <*> D.column (D.nonNullable D.int4)
        <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
        <*> (EventId <$> D.column (D.nonNullable D.uuid))
        <*> D.column (D.nonNullable D.jsonb)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.int4)
        <*> D.column (D.nonNullable D.timestamptz)

listSubscriptionDeadLettersSession :: SubscriptionDeadLetterQuery -> Session SubscriptionDeadLetterPage
listSubscriptionDeadLettersSession query = do
    let SubscriptionName name = query ^. #subscriptionName
        pageSize = subscriptionDeadLetterLimitValue (query ^. #limit)
        fetch = pageSize + 1
    rows <- case (query ^. #consumerGroupMember, query ^. #after) of
        (Nothing, Nothing) -> Session.statement (name, fetch) listSubscriptionDeadLettersFromStartStmt
        (Just selectedMember, Nothing) -> Session.statement (name, selectedMember, fetch) listSubscriptionMemberDeadLettersFromStartStmt
        (Nothing, Just (SubscriptionDeadLetterCursor (GlobalPosition position) ident)) ->
            Session.statement (name, position, ident, fetch) listSubscriptionDeadLettersStmt
        (Just selectedMember, Just (SubscriptionDeadLetterCursor (GlobalPosition position) ident)) ->
            Session.statement (name, selectedMember, position, ident, fetch) listSubscriptionMemberDeadLettersStmt
    let page = V.take (fromIntegral pageSize) rows
        cursor = if V.length rows > fromIntegral pageSize then Just (subscriptionDeadLetterCursor (V.last page)) else Nothing
    pure (SubscriptionDeadLetterPage page cursor)
