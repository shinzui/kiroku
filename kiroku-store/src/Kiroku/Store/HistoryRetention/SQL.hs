{-# LANGUAGE MultilineStrings #-}

module Kiroku.Store.HistoryRetention.SQL (
    acquireLeaseStmt,
    lockCoordinatorStmt,
    readLeaseForUpdateStmt,
    renewLeaseStmt,
    releaseLeaseStmt,
    leaseInventoryStmt,
    pruneLeasesStmt,
    activeConflictStmt,
    lockStreamHistoryStmt,
    lockAffectedStreamsForHardDeleteStmt,
) where

import Contravariant.Extras (contrazip2, contrazip3)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Time.Clock (DiffTime, UTCTime)
import Data.UUID (UUID)
import Data.Vector (Vector)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Kiroku.Store.HistoryRetention.Types
import Kiroku.Store.Types (GlobalPosition (..), StreamId (..), StreamInfo (..), StreamName (..), StreamVersion (..))

acquireLeaseStmt :: Statement (Text, Text, DiffTime) HistoryRetentionLease
acquireLeaseStmt =
    preparable
        """
        WITH coordinator AS MATERIALIZED (
          SELECT singleton
          FROM history_retention_coordinator
          WHERE singleton
          FOR UPDATE
        ), snapshot AS MATERIALIZED (
          SELECT streams.stream_version AS protected_through,
                 clock_timestamp() AS database_now
          FROM streams
          CROSS JOIN coordinator
          WHERE streams.stream_id = 0
        ), inserted AS (
          INSERT INTO history_retention_leases
            (owner, reason, protected_through, created_at, renewed_at, expires_at)
          SELECT $1, $2, protected_through, database_now, database_now, database_now + $3
          FROM snapshot
          RETURNING lease_id, owner, reason, protected_through,
                    created_at, renewed_at, expires_at, released_at
        )
        SELECT lease_id, owner, reason, protected_through,
               created_at, renewed_at, expires_at, released_at,
               'active'::text
        FROM inserted
        """
        (contrazip3 textParam textParam intervalParam)
        (D.singleRow leaseRow)

lockCoordinatorStmt :: Statement () Bool
lockCoordinatorStmt =
    preparable
        """
        SELECT singleton
        FROM history_retention_coordinator
        WHERE singleton
        FOR UPDATE
        """
        E.noParams
        (D.singleRow (column D.bool))

readLeaseForUpdateStmt :: Statement UUID (Maybe HistoryRetentionLease)
readLeaseForUpdateStmt =
    preparable
        """
        SELECT lease_id, owner, reason, protected_through,
               created_at, renewed_at, expires_at, released_at,
               CASE
                 WHEN released_at IS NOT NULL THEN 'released'
                 WHEN expires_at <= clock_timestamp() THEN 'expired'
                 ELSE 'active'
               END::text
        FROM history_retention_leases
        WHERE lease_id = $1
        FOR UPDATE
        """
        uuidParam
        (D.rowMaybe leaseRow)

renewLeaseStmt :: Statement (UUID, DiffTime) HistoryRetentionLease
renewLeaseStmt =
    preparable
        """
        WITH renewal_time AS MATERIALIZED (
          SELECT clock_timestamp() AS database_now
        ), renewed AS (
          UPDATE history_retention_leases
          SET renewed_at = renewal_time.database_now,
              expires_at = GREATEST(
                history_retention_leases.expires_at,
                renewal_time.database_now + $2
              )
          FROM renewal_time
          WHERE lease_id = $1
          RETURNING lease_id, owner, reason, protected_through,
                    created_at, renewed_at, expires_at, released_at
        )
        SELECT lease_id, owner, reason, protected_through,
               created_at, renewed_at, expires_at, released_at,
               'active'::text
        FROM renewed
        """
        (contrazip2 uuidParam intervalParam)
        (D.singleRow leaseRow)

releaseLeaseStmt :: Statement UUID HistoryRetentionLease
releaseLeaseStmt =
    preparable
        """
        WITH released AS (
          UPDATE history_retention_leases
          SET released_at = clock_timestamp()
          WHERE lease_id = $1
          RETURNING lease_id, owner, reason, protected_through,
                    created_at, renewed_at, expires_at, released_at
        )
        SELECT lease_id, owner, reason, protected_through,
               created_at, renewed_at, expires_at, released_at,
               'released'::text
        FROM released
        """
        uuidParam
        (D.singleRow leaseRow)

leaseInventoryStmt :: Statement Int32 (Vector HistoryRetentionLease)
leaseInventoryStmt =
    preparable
        """
        WITH inventory_time AS MATERIALIZED (
          SELECT clock_timestamp() AS database_now
        )
        SELECT lease_id, owner, reason, protected_through,
               created_at, renewed_at, expires_at, released_at,
               CASE
                 WHEN released_at IS NOT NULL THEN 'released'
                 WHEN expires_at <= inventory_time.database_now THEN 'expired'
                 ELSE 'active'
               END::text
        FROM history_retention_leases
        CROSS JOIN inventory_time
        ORDER BY created_at, lease_id
        LIMIT $1
        """
        int4Param
        (D.rowVector leaseRow)

pruneLeasesStmt :: Statement UTCTime HistoryRetentionPruneResult
pruneLeasesStmt =
    preparable
        """
        WITH released AS (
          DELETE FROM history_retention_leases
          WHERE released_at IS NOT NULL
            AND released_at < $1
          RETURNING 1
        ), expired AS (
          DELETE FROM history_retention_leases
          WHERE released_at IS NULL
            AND expires_at < $1
          RETURNING 1
        )
        SELECT (SELECT count(*) FROM expired),
               (SELECT count(*) FROM released)
        """
        timestamptzParam
        ( D.singleRow
            ( HistoryRetentionPruneResult
                <$> column D.int8
                <*> column D.int8
            )
        )

activeConflictStmt :: Statement () (Maybe HistoryRetentionConflict)
activeConflictStmt =
    preparable
        """
        SELECT count(*), min(expires_at)
        FROM history_retention_leases
        WHERE released_at IS NULL
          AND expires_at > clock_timestamp()
        HAVING count(*) > 0
        """
        E.noParams
        ( D.rowMaybe
            ( HistoryRetentionConflict
                <$> column D.int8
                <*> column D.timestamptz
            )
        )

lockStreamHistoryStmt :: Statement Text (Maybe StreamInfo)
lockStreamHistoryStmt =
    preparable
        """
        SELECT stream_id, stream_name, stream_version,
               created_at, deleted_at, truncate_before
        FROM streams
        WHERE stream_name = $1
        FOR SHARE
        """
        textParam
        (D.rowMaybe streamInfoRow)

lockAffectedStreamsForHardDeleteStmt :: Statement Int64 (Vector Int64)
lockAffectedStreamsForHardDeleteStmt =
    preparable
        """
        WITH affected_streams AS (
          SELECT $1::bigint AS stream_id
          UNION
          SELECT stream_events.stream_id
          FROM stream_events
          WHERE stream_events.original_stream_id = $1
            AND stream_events.stream_id <> 0
        )
        SELECT streams.stream_id
        FROM streams
        JOIN affected_streams USING (stream_id)
        ORDER BY streams.stream_id
        FOR UPDATE OF streams
        """
        int8Param
        (D.rowVector (column D.int8))

leaseRow :: D.Row HistoryRetentionLease
leaseRow =
    makeLease
        <$> column D.uuid
        <*> column D.text
        <*> column D.text
        <*> column D.int8
        <*> column D.timestamptz
        <*> column D.timestamptz
        <*> column D.timestamptz
        <*> D.column (D.nullable D.timestamptz)
        <*> column D.text

makeLease :: UUID -> Text -> Text -> Int64 -> UTCTime -> UTCTime -> UTCTime -> Maybe UTCTime -> Text -> HistoryRetentionLease
makeLease leaseUuid ownerText reasonText frontier created renewed expires released stateText =
    HistoryRetentionLease
        { leaseId = HistoryRetentionLeaseId leaseUuid
        , owner = requireValidated (mkHistoryRetentionLeaseOwner ownerText)
        , reason = requireValidated (mkHistoryRetentionLeaseReason reasonText)
        , protectedThrough = GlobalPosition frontier
        , createdAt = created
        , renewedAt = renewed
        , expiresAt = expires
        , releasedAt = released
        , state = case stateText of
            "active" -> HistoryRetentionLeaseActive
            "expired" -> HistoryRetentionLeaseExpired
            "released" -> HistoryRetentionLeaseReleased
            unexpected -> error ("unknown history retention lease state from database: " <> show unexpected)
        }

streamInfoRow :: D.Row StreamInfo
streamInfoRow =
    StreamInfo
        <$> (StreamId <$> column D.int8)
        <*> (StreamName <$> column D.text)
        <*> (StreamVersion <$> column D.int8)
        <*> column D.timestamptz
        <*> D.column (D.nullable D.timestamptz)
        <*> (StreamVersion <$> column D.int8)

requireValidated :: Either error value -> value
requireValidated = either (const (error "database returned an invalid history retention lease")) (\value -> value)

column :: D.Value value -> D.Row value
column = D.column . D.nonNullable

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)

uuidParam :: E.Params UUID
uuidParam = E.param (E.nonNullable E.uuid)

int4Param :: E.Params Int32
int4Param = E.param (E.nonNullable E.int4)

int8Param :: E.Params Int64
int8Param = E.param (E.nonNullable E.int8)

intervalParam :: E.Params DiffTime
intervalParam = E.param (E.nonNullable E.interval)

timestamptzParam :: E.Params UTCTime
timestamptzParam = E.param (E.nonNullable E.timestamptz)
