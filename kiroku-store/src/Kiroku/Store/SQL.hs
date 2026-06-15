{-# LANGUAGE MultilineStrings #-}

module Kiroku.Store.SQL (
    -- * Append statements
    AppendParams (..),
    appendExpectedVersion,
    appendStreamExists,
    appendNoStream,
    appendAnyVersion,

    -- * Link statements
    linkToStreamStmt,

    -- * Read statements
    readStreamForwardStmt,
    readStreamBackwardStmt,
    readAllForwardStmt,
    readAllBackwardStmt,
    readCategoryForwardStmt,
    getStreamStmt,
    eventExistsInStreamStmt,
    lookupStreamNamesStmt,
    currentGlobalPositionStmt,

    -- * Consumer-group read statements
    readCategoryForwardConsumerGroupStmt,
    readAllForwardConsumerGroupStmt,

    -- * Causation / correlation statements
    findByCorrelationStmt,
    findCausationDescendantsStmt,
    findCausationAncestorsStmt,

    -- * Lifecycle statements
    softDeleteStreamStmt,
    undeleteStreamStmt,

    -- * Hard-delete statements (used in sequence inside one transaction)
    findStreamIdStmt,
    deleteAllRowsForOriginStmt,
    deleteJunctionsByEventIdsStmt,
    deleteStreamOwnJunctionsStmt,
    deleteDeadLettersForOrphanedEventsStmt,
    deleteOrphanedEventsStmt,
    deleteStreamRowStmt,

    -- * Multi-stream pre-lock (avoids row-lock deadlocks)
    lockStreamsForMultiStmt,

    -- * Checkpoint statements
    getCheckpointStmt,
    saveCheckpointStmt,
    getCheckpointMemberStmt,
    saveCheckpointMemberStmt,

    -- * Dead-letter statements
    DeadLetterParams (..),
    DeadLetterRecord (..),
    insertDeadLetterAndCheckpointStmt,
    readDeadLettersStmt,
) where

import Contravariant.Extras (contrazip2, contrazip3, contrazip4, contrazip5)
import Control.Lens ((^.))
import Data.Aeson (Value)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Data.Vector (Vector)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Kiroku.Store.Types

-- | Parameters for append CTE variants (the 7 parallel arrays + stream name).
data AppendParams = AppendParams
    { eventIds :: !(Vector UUID)
    , eventTypes :: !(Vector Text)
    , causationIds :: !(Vector (Maybe UUID))
    , correlationIds :: !(Vector (Maybe UUID))
    , payloads :: !(Vector Value)
    , metadatas :: !(Vector (Maybe Value))
    , createdAts :: !(Vector UTCTime)
    , streamName :: !Text
    }
    deriving stock (Show, Generic)

-- | Encoder for the common 8 parameters shared by all append variants.
appendParamsEncoder :: E.Params AppendParams
appendParamsEncoder =
    ((^. #eventIds) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        <> ((^. #eventTypes) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        <> ((^. #causationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((^. #correlationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((^. #payloads) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.jsonb))))
        <> ((^. #metadatas) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.jsonb))))
        <> ((^. #createdAts) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.timestamptz))))
        <> ((^. #streamName) >$< E.param (E.nonNullable E.text))

-- | Encoder for append_expected_version: base params + expected version (Int64).
appendExpectedEncoder :: E.Params (AppendParams, Int64)
appendExpectedEncoder =
    contrazip2 appendParamsEncoder (E.param (E.nonNullable E.int8))

{- | Decoder for append results: stream_id, stream_version, global_position.
Returns Nothing if the CTE produced 0 rows (version conflict / stream not found).
-}
appendResultDecoder :: D.Result (Maybe AppendResult)
appendResultDecoder =
    D.rowMaybe $
        AppendResult
            <$> (StreamId <$> D.column (D.nonNullable D.int8))
            <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
            <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))

{- | Append with exact expected version (optimistic concurrency).
Returns Nothing if the stream doesn't exist or version doesn't match.
-}
appendExpectedVersion :: Statement (AppendParams, Int64) (Maybe AppendResult)
appendExpectedVersion =
    preparable
        appendExpectedVersionSQL
        appendExpectedEncoder
        appendResultDecoder

{- | Append to an existing stream at any version.
Returns Nothing if the stream doesn't exist.
-}
appendStreamExists :: Statement AppendParams (Maybe AppendResult)
appendStreamExists =
    preparable
        appendStreamExistsSQL
        appendParamsEncoder
        appendResultDecoder

{- | Append to a new stream (must not already exist).
Returns Nothing if the stream already exists.
-}
appendNoStream :: Statement AppendParams (Maybe AppendResult)
appendNoStream =
    preparable
        appendNoStreamSQL
        appendParamsEncoder
        appendResultDecoder

{- | Append to a stream, creating it if it doesn't exist.
Should always return Just (unless duplicate event ID constraint violation).
-}
appendAnyVersion :: Statement AppendParams (Maybe AppendResult)
appendAnyVersion =
    preparable
        appendAnyVersionSQL
        appendParamsEncoder
        appendResultDecoder

-- ---------------------------------------------------------------------------
-- SQL Templates
-- ---------------------------------------------------------------------------

-- | CTE with exact version check: UPDATE streams WHERE stream_version = $9.
appendExpectedVersionSQL :: Text
appendExpectedVersionSQL =
    """
    WITH
      new_events AS (
        SELECT *
        FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
        WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
      ),
      stream_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_name = $8
          AND stream_version = $9
          AND deleted_at IS NULL
        RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
      ),
      inserted_events AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
        FROM new_events
        WHERE EXISTS (SELECT 1 FROM stream_update)
        ORDER BY idx
      ),
      source_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN stream_update su
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_id = 0
          AND EXISTS (SELECT 1 FROM stream_update)
        RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
      ),
      all_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN all_update au
        CROSS JOIN stream_update su
      )
    SELECT su.stream_id,
           su.initial_version + (SELECT count(*) FROM new_events),
           au.initial_global_version + (SELECT count(*) FROM new_events)
    FROM stream_update su
    CROSS JOIN all_update au
    """

-- | CTE without version check: UPDATE streams WHERE stream_name = $8 (no $9).
appendStreamExistsSQL :: Text
appendStreamExistsSQL =
    """
    WITH
      new_events AS (
        SELECT *
        FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
        WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
      ),
      stream_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_name = $8
          AND deleted_at IS NULL
        RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
      ),
      inserted_events AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
        FROM new_events
        WHERE EXISTS (SELECT 1 FROM stream_update)
        ORDER BY idx
      ),
      source_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN stream_update su
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_id = 0
          AND EXISTS (SELECT 1 FROM stream_update)
        RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
      ),
      all_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN all_update au
        CROSS JOIN stream_update su
      )
    SELECT su.stream_id,
           su.initial_version + (SELECT count(*) FROM new_events),
           au.initial_global_version + (SELECT count(*) FROM new_events)
    FROM stream_update su
    CROSS JOIN all_update au
    """

-- | CTE for new stream creation: INSERT INTO streams ... ON CONFLICT DO NOTHING.
appendNoStreamSQL :: Text
appendNoStreamSQL =
    """
    WITH
      new_events AS (
        SELECT *
        FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
        WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
      ),
      stream_insert AS (
        INSERT INTO streams (stream_name, stream_version)
        VALUES ($8, (SELECT count(*) FROM new_events))
        ON CONFLICT (stream_name) DO NOTHING
        RETURNING stream_id, 0::bigint AS initial_version
      ),
      inserted_events AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
        FROM new_events
        WHERE EXISTS (SELECT 1 FROM stream_insert)
        ORDER BY idx
      ),
      source_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, si.stream_id, si.initial_version + ne.idx, si.stream_id, si.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN stream_insert si
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_id = 0
          AND EXISTS (SELECT 1 FROM stream_insert)
        RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
      ),
      all_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, 0, au.initial_global_version + ne.idx, si.stream_id, si.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN all_update au
        CROSS JOIN stream_insert si
      )
    SELECT si.stream_id,
           si.initial_version + (SELECT count(*) FROM new_events),
           au.initial_global_version + (SELECT count(*) FROM new_events)
    FROM stream_insert si
    CROSS JOIN all_update au
    """

{- | CTE for create-or-append using INSERT ... ON CONFLICT DO UPDATE (upsert).
A plain INSERT + separate UPDATE in the same CTE won't work because
data-modifying CTEs cannot see each other's changes. Instead, we use
a single upsert that both creates the stream and bumps its version atomically.
-}
appendAnyVersionSQL :: Text
appendAnyVersionSQL =
    """
    WITH
      new_events AS (
        SELECT *
        FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
        WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
      ),
      stream_upsert AS (
        INSERT INTO streams (stream_name, stream_version)
        VALUES ($8, (SELECT count(*) FROM new_events))
        ON CONFLICT (stream_name)
        DO UPDATE SET stream_version = streams.stream_version + (SELECT count(*) FROM new_events)
          WHERE streams.deleted_at IS NULL
        RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
      ),
      inserted_events AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
        FROM new_events
        WHERE EXISTS (SELECT 1 FROM stream_upsert)
        ORDER BY idx
      ),
      source_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN stream_upsert su
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_id = 0
          AND EXISTS (SELECT 1 FROM stream_upsert)
        RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
      ),
      all_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN all_update au
        CROSS JOIN stream_upsert su
      )
    SELECT su.stream_id,
           su.initial_version + (SELECT count(*) FROM new_events),
           au.initial_global_version + (SELECT count(*) FROM new_events)
    FROM stream_upsert su
    CROSS JOIN all_update au
    """

-- ---------------------------------------------------------------------------
-- Read Statements
-- ---------------------------------------------------------------------------

-- | Shared decoder for a RecordedEvent row (11 columns).
recordedEventRow :: D.Row RecordedEvent
recordedEventRow =
    RecordedEvent
        <$> (EventId <$> D.column (D.nonNullable D.uuid))
        <*> (EventType <$> D.column (D.nonNullable D.text))
        <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
        <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
        <*> (StreamId <$> D.column (D.nonNullable D.int8))
        <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
        <*> D.column (D.nonNullable D.jsonb)
        <*> D.column (D.nullable D.jsonb)
        <*> D.column (D.nullable D.uuid)
        <*> D.column (D.nullable D.uuid)
        <*> D.column (D.nonNullable D.timestamptz)

-- | Shared decoder for a StreamInfo row (5 columns).
streamInfoRow :: D.Row StreamInfo
streamInfoRow =
    StreamInfo
        <$> (StreamId <$> D.column (D.nonNullable D.int8))
        <*> (StreamName <$> D.column (D.nonNullable D.text))
        <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
        <*> D.column (D.nonNullable D.timestamptz)
        <*> D.column (D.nullable D.timestamptz)

-- | Encoder for stream read params: (stream_name, start_version, limit).
readStreamEncoder :: E.Params (Text, Int64, Int32)
readStreamEncoder =
    contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int4))

-- | Encoder for $all read params: (start_position, limit).
readAllEncoder :: E.Params (Int64, Int32)
readAllEncoder =
    contrazip2
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int4))

-- | Read events from a named stream in forward order.
readStreamForwardStmt :: Statement (Text, Int64, Int32) (Vector RecordedEvent)
readStreamForwardStmt =
    preparable
        readStreamForwardSQL
        readStreamEncoder
        (D.rowVector recordedEventRow)

-- | Read events from a named stream in backward order.
readStreamBackwardStmt :: Statement (Text, Int64, Int32) (Vector RecordedEvent)
readStreamBackwardStmt =
    preparable
        readStreamBackwardSQL
        readStreamEncoder
        (D.rowVector recordedEventRow)

-- | Read events from the global $all stream in forward order.
readAllForwardStmt :: Statement (Int64, Int32) (Vector RecordedEvent)
readAllForwardStmt =
    preparable
        readAllForwardSQL
        readAllEncoder
        (D.rowVector recordedEventRow)

-- | Read events from the global $all stream in backward order.
readAllBackwardStmt :: Statement (Int64, Int32) (Vector RecordedEvent)
readAllBackwardStmt =
    preparable
        readAllBackwardSQL
        readAllEncoder
        (D.rowVector recordedEventRow)

-- | Read the current tail of the global $all stream.
currentGlobalPositionStmt :: Statement () Int64
currentGlobalPositionStmt =
    preparable
        "SELECT stream_version FROM streams WHERE stream_id = 0"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.int8)))

-- | Get stream metadata by name.
getStreamStmt :: Statement Text (Maybe StreamInfo)
getStreamStmt =
    preparable
        getStreamSQL
        (E.param (E.nonNullable E.text))
        (D.rowMaybe streamInfoRow)

-- | Point probe for whether an event exists in a live stream.
eventExistsInStreamStmt :: Statement (Text, UUID) Bool
eventExistsInStreamStmt =
    preparable
        """
        SELECT EXISTS (
          SELECT 1
          FROM stream_events se
          WHERE se.event_id = $2
            AND se.stream_id = (
              SELECT stream_id
              FROM streams
              WHERE stream_name = $1
                AND deleted_at IS NULL
            )
        )
        """
        (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.uuid)))
        (D.singleRow (D.column (D.nonNullable D.bool)))

-- ---------------------------------------------------------------------------
-- Read SQL Templates
-- ---------------------------------------------------------------------------

{- | Read from a named stream in forward order.
Resolves stream name to ID via subquery, joins stream_events with events,
filters on stream_version > start_version, orders ascending, limits.
For stream reads, global_position is set to 0 (not available without $all join).
-}
readStreamForwardSQL :: Text
readStreamForwardSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, 0::bigint AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM stream_events se
    JOIN events e ON e.event_id = se.event_id
    WHERE se.stream_id = (SELECT stream_id FROM streams WHERE stream_name = $1 AND deleted_at IS NULL)
      AND se.stream_version > $2
    ORDER BY se.stream_version ASC
    LIMIT $3
    """

{- | Read from a named stream in backward order.
The start version is an exclusive upper bound. The interpreter maps
caller cursor 0 to 'maxBound' so "from latest" stays a Haskell API
sentinel and the SQL keeps a plain range predicate.
-}
readStreamBackwardSQL :: Text
readStreamBackwardSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, 0::bigint AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM stream_events se
    JOIN events e ON e.event_id = se.event_id
    WHERE se.stream_id = (SELECT stream_id FROM streams WHERE stream_name = $1 AND deleted_at IS NULL)
      AND se.stream_version < $2
    ORDER BY se.stream_version DESC
    LIMIT $3
    """

{- | Read from the global $all stream in forward order.
stream_id = 0 is the $all stream. stream_version on $all is the global position.
-}
readAllForwardSQL :: Text
readAllForwardSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM stream_events se
    JOIN events e ON e.event_id = se.event_id
    WHERE se.stream_id = 0
      AND se.stream_version > $1
    ORDER BY se.stream_version ASC
    LIMIT $2
    """

{- | Read from the global $all stream in backward order.
The start position is an exclusive upper bound. The interpreter maps
caller cursor 0 to 'maxBound' so "from latest" stays a Haskell API
sentinel and the SQL keeps a plain range predicate.
-}
readAllBackwardSQL :: Text
readAllBackwardSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM stream_events se
    JOIN events e ON e.event_id = se.event_id
    WHERE se.stream_id = 0
      AND se.stream_version < $1
    ORDER BY se.stream_version DESC
    LIMIT $2
    """

-- | Get stream metadata by name.
getStreamSQL :: Text
getStreamSQL =
    """
    SELECT stream_id, stream_name, stream_version, created_at, deleted_at
    FROM streams
    WHERE stream_name = $1
    """

-- ---------------------------------------------------------------------------
-- Causation / Correlation Statements
-- ---------------------------------------------------------------------------

{- | Return every event whose @correlation_id@ equals the input, in ascending
@global_position@ order. Uses the @ix_events_correlation_id@ partial index.

The @stream_events se ON se.stream_id = 0@ join resolves each event to its
single row in the global @$all@ stream, which is also where the global
position is materialized as @stream_version@.
-}
findByCorrelationStmt :: Statement UUID (Vector RecordedEvent)
findByCorrelationStmt =
    preparable
        findByCorrelationSQL
        (E.param (E.nonNullable E.uuid))
        (D.rowVector recordedEventRow)

findByCorrelationSQL :: Text
findByCorrelationSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM events e
    JOIN stream_events se
      ON se.event_id = e.event_id AND se.stream_id = 0
    WHERE e.correlation_id = $1
    ORDER BY se.stream_version ASC
    """

{- | Walk the causation graph forward from a seed event, returning the seed
itself and every event whose @causation_id@ chain leads back to it. The
result is ordered by ascending @global_position@.

The recursive CTE follows @causation_id@ links downstream: each child's
@causation_id@ equals a parent's @event_id@. Cost is @O(depth * log n)@
backed by the @ix_events_causation_id@ partial index.
-}
findCausationDescendantsStmt :: Statement UUID (Vector RecordedEvent)
findCausationDescendantsStmt =
    preparable
        findCausationDescendantsSQL
        (E.param (E.nonNullable E.uuid))
        (D.rowVector recordedEventRow)

findCausationDescendantsSQL :: Text
findCausationDescendantsSQL =
    """
    WITH RECURSIVE chain (event_id, depth) AS (
        SELECT event_id, 0
        FROM events
        WHERE event_id = $1
      UNION ALL
        SELECT e.event_id, c.depth + 1
        FROM events e
        JOIN chain c ON e.causation_id = c.event_id
    )
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM chain c
    JOIN events e ON e.event_id = c.event_id
    JOIN stream_events se
      ON se.event_id = e.event_id AND se.stream_id = 0
    ORDER BY se.stream_version ASC
    """

{- | Walk the causation graph backward from a seed event, returning the seed
itself and every ancestor reachable via @causation_id@. Result is ordered
by ascending @depth@ (the seed is depth 0, its immediate cause is depth 1,
etc.).

The recursive CTE follows @causation_id@ links upstream: for each row
@current@ already in the working set, its parent is the row of @events@
whose @event_id@ equals @current.causation_id@.
-}
findCausationAncestorsStmt :: Statement UUID (Vector RecordedEvent)
findCausationAncestorsStmt =
    preparable
        findCausationAncestorsSQL
        (E.param (E.nonNullable E.uuid))
        (D.rowVector recordedEventRow)

findCausationAncestorsSQL :: Text
findCausationAncestorsSQL =
    """
    WITH RECURSIVE chain (event_id, depth) AS (
        SELECT event_id, 0
        FROM events
        WHERE event_id = $1
      UNION ALL
        SELECT parent.event_id, c.depth + 1
        FROM events parent
        JOIN events current ON parent.event_id = current.causation_id
        JOIN chain c ON c.event_id = current.event_id
    )
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM chain c
    JOIN events e ON e.event_id = c.event_id
    JOIN stream_events se
      ON se.event_id = e.event_id AND se.stream_id = 0
    ORDER BY c.depth ASC
    """

-- ---------------------------------------------------------------------------
-- Link Statements
-- ---------------------------------------------------------------------------

{- | Link existing events into a target stream (upsert semantics).
Returns @Nothing@ when the target stream exists and is soft-deleted (the
@DO UPDATE WHERE streams.deleted_at IS NULL@ filter rejects the upsert,
so the stream_upsert CTE produces no rows). The interpreter maps @Nothing@
to @StreamNotFound@ for symmetry with @appendAnyVersion@'s soft-deleted
behavior added in EP-1 F2.
-}
linkToStreamStmt :: Statement (Vector UUID, Text) (Maybe LinkResult)
linkToStreamStmt =
    preparable
        linkToStreamSQL
        linkEncoder
        linkResultDecoder

linkEncoder :: E.Params (Vector UUID, Text)
linkEncoder =
    contrazip2
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        (E.param (E.nonNullable E.text))

linkResultDecoder :: D.Result (Maybe LinkResult)
linkResultDecoder =
    D.rowMaybe $
        LinkResult
            <$> (StreamId <$> D.column (D.nonNullable D.int8))
            <*> (StreamVersion <$> D.column (D.nonNullable D.int8))

linkToStreamSQL :: Text
linkToStreamSQL =
    """
    WITH
      event_list AS (
        SELECT event_id, idx
        FROM unnest($1::uuid[]) WITH ORDINALITY AS t(event_id, idx)
      ),
      stream_upsert AS (
        INSERT INTO streams (stream_name, stream_version)
        VALUES ($2, (SELECT count(*) FROM event_list))
        ON CONFLICT (stream_name)
        DO UPDATE SET stream_version = streams.stream_version + (SELECT count(*) FROM event_list)
          WHERE streams.deleted_at IS NULL
        RETURNING stream_id, stream_version - (SELECT count(*) FROM event_list) AS initial_version
      ),
      link_inserts AS (
        -- LEFT JOIN LATERAL surfaces missing-event rows as NULLs for original_*; the
        -- NOT NULL constraint on stream_events.original_stream_id then aborts the
        -- entire CTE, rolling back the stream_upsert's version bump. Before the F3
        -- fix this was a plain JOIN LATERAL, which silently dropped missing-event
        -- rows while still bumping stream_version → silent gap in the link target.
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT el.event_id, su.stream_id, su.initial_version + el.idx,
               orig.original_stream_id, orig.original_stream_version
        FROM event_list el
        CROSS JOIN stream_upsert su
        LEFT JOIN LATERAL (
          SELECT se.original_stream_id, se.original_stream_version
          FROM stream_events se
          WHERE se.event_id = el.event_id AND se.stream_id <> 0
          LIMIT 1
        ) orig ON true
      )
    SELECT su.stream_id, su.initial_version + (SELECT count(*) FROM event_list)
    FROM stream_upsert su
    """

-- ---------------------------------------------------------------------------
-- Category Read Statements
-- ---------------------------------------------------------------------------

-- | Read events from streams matching a category, in global position order.
readCategoryForwardStmt :: Statement (Int64, Text, Int32) (Vector RecordedEvent)
readCategoryForwardStmt =
    preparable
        readCategoryForwardSQL
        readCategoryEncoder
        (D.rowVector recordedEventRow)

readCategoryEncoder :: E.Params (Int64, Text, Int32)
readCategoryEncoder =
    contrazip3
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))

readCategoryForwardSQL :: Text
readCategoryForwardSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM streams s
    JOIN LATERAL (
      SELECT se.*
      FROM stream_events se
      WHERE se.stream_id = 0
        AND se.original_stream_id = s.stream_id
        AND se.stream_version > $1
      ORDER BY se.stream_version ASC
      LIMIT $3
    ) se ON true
    JOIN events e ON e.event_id = se.event_id
    WHERE s.category = $2
    ORDER BY se.stream_version ASC
    LIMIT $3
    """

-- ---------------------------------------------------------------------------
-- Consumer-Group Read Statements
-- ---------------------------------------------------------------------------

{- | Partition-filtered category read for one consumer-group member.

Mirrors 'readCategoryForwardStmt' but returns only events whose originating
stream is assigned to member @$3@ of a group of size @$4@. The assignment rule
(MasterPlan IP-1) hashes the originating stream's surrogate id and folds the
signed result into @[0, size)@:

@member_of(stream_id) = (((hashtextextended(stream_id::text, 0) % size) + size) % size)@

The predicate is applied to @s.stream_id@ in the outer @WHERE@ so whole
unassigned streams are pruned before the lateral join. Params:
@(startPosition, category, member, size, limit)@.
-}
readCategoryForwardConsumerGroupStmt ::
    Statement (Int64, Text, Int32, Int32, Int32) (Vector RecordedEvent)
readCategoryForwardConsumerGroupStmt =
    preparable
        readCategoryForwardConsumerGroupSQL
        readCategoryConsumerGroupEncoder
        (D.rowVector recordedEventRow)

readCategoryConsumerGroupEncoder :: E.Params (Int64, Text, Int32, Int32, Int32)
readCategoryConsumerGroupEncoder =
    contrazip5
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.int4))

readCategoryForwardConsumerGroupSQL :: Text
readCategoryForwardConsumerGroupSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM streams s
    JOIN LATERAL (
      SELECT se.*
      FROM stream_events se
      WHERE se.stream_id = 0
        AND se.original_stream_id = s.stream_id
        AND se.stream_version > $1
      ORDER BY se.stream_version ASC
      LIMIT $5
    ) se ON true
    JOIN events e ON e.event_id = se.event_id
    WHERE s.category = $2
      AND (((hashtextextended(s.stream_id::text, 0) % $4) + $4) % $4) = $3
    ORDER BY se.stream_version ASC
    LIMIT $5
    """

{- | Partition-filtered @$all@ read for one consumer-group member.

Mirrors 'readAllForwardStmt' but returns only events whose originating stream is
assigned to member @$2@ of a group of size @$3@, using the same MasterPlan IP-1
rule as 'readCategoryForwardConsumerGroupStmt'. The predicate is applied to
@se.original_stream_id@ — the real originating stream of each @$all@ junction row
(never the reserved id 0 for normal appends). Params:
@(startPosition, member, size, limit)@.
-}
readAllForwardConsumerGroupStmt ::
    Statement (Int64, Int32, Int32, Int32) (Vector RecordedEvent)
readAllForwardConsumerGroupStmt =
    preparable
        readAllForwardConsumerGroupSQL
        readAllConsumerGroupEncoder
        (D.rowVector recordedEventRow)

readAllConsumerGroupEncoder :: E.Params (Int64, Int32, Int32, Int32)
readAllConsumerGroupEncoder =
    contrazip4
        (E.param (E.nonNullable E.int8))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.int4))
        (E.param (E.nonNullable E.int4))

readAllForwardConsumerGroupSQL :: Text
readAllForwardConsumerGroupSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM stream_events se
    JOIN events e ON e.event_id = se.event_id
    WHERE se.stream_id = 0
      AND se.stream_version > $1
      AND (((hashtextextended(se.original_stream_id::text, 0) % $3) + $3) % $3) = $2
    ORDER BY se.stream_version ASC
    LIMIT $4
    """

-- ---------------------------------------------------------------------------
-- Lifecycle Statements
-- ---------------------------------------------------------------------------

-- | Soft-delete a stream by setting deleted_at. Returns Nothing if stream doesn't exist or is already deleted.
softDeleteStreamStmt :: Statement Text (Maybe StreamId)
softDeleteStreamStmt =
    preparable
        softDeleteStreamSQL
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (StreamId <$> D.column (D.nonNullable D.int8)))

-- | Undelete a soft-deleted stream by clearing deleted_at. Returns Nothing if stream doesn't exist or is not deleted.
undeleteStreamStmt :: Statement Text (Maybe StreamId)
undeleteStreamStmt =
    preparable
        undeleteStreamSQL
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (StreamId <$> D.column (D.nonNullable D.int8)))

{- | Look up a stream's id by name. Returns Nothing if the stream does not exist.
Used as the first step in hard-delete; subsequent steps key off the id rather
than the name so a single resolution is reused.
-}
findStreamIdStmt :: Statement Text (Maybe Int64)
findStreamIdStmt =
    preparable
        "SELECT stream_id FROM streams WHERE stream_name = $1"
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (D.column (D.nonNullable D.int8)))

{- | Resolve a batch of surrogate stream ids to their (id, name) pairs in one
round trip. Ids that do not name an existing stream simply produce no row, so
the caller's 'Data.Map.Strict.Map' omits them. Surfaced as
'Kiroku.Store.Read.lookupStreamNames'.
-}
lookupStreamNamesStmt :: Statement [Int64] (Vector (Int64, Text))
lookupStreamNamesStmt =
    preparable
        "SELECT stream_id, stream_name FROM streams WHERE stream_id = ANY($1::bigint[])"
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.int8))))
        ( D.rowVector
            ( (,)
                <$> D.column (D.nonNullable D.int8)
                <*> D.column (D.nonNullable D.text)
            )
        )

{- | Delete the @$all@ junction rows for events that originated in the target
stream, returning exactly those originated event ids.

Served by @ix_stream_events_all_by_origin@, whose partial predicate is
@stream_id = 0@. Every event that originated in a stream has one @$all@ row, so
this indexed delete yields the complete originated-event set without scanning all
of @stream_events@.

The caller then passes the returned ids to 'deleteJunctionsByEventIdsStmt' to
remove the remaining home/link junction rows for those originated events.
-}
deleteAllRowsForOriginStmt :: Statement Int64 (Vector UUID)
deleteAllRowsForOriginStmt =
    preparable
        """
        DELETE FROM stream_events
        WHERE original_stream_id = $1
          AND stream_id = 0
        RETURNING event_id
        """
        (E.param (E.nonNullable E.int8))
        (D.rowVector (D.column (D.nonNullable D.uuid)))

{- | Delete all remaining junction rows for the given event ids.

Served by the @stream_events@ primary key @(event_id, stream_id)@. This removes
the originated events' home rows and any link rows in other streams after
'deleteAllRowsForOriginStmt' has removed their @$all@ rows.
-}
deleteJunctionsByEventIdsStmt :: Statement (Vector UUID) ()
deleteJunctionsByEventIdsStmt =
    preparable
        """
        DELETE FROM stream_events
        WHERE event_id = ANY($1::uuid[])
        """
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        D.noResult

{- | Delete junction rows whose visible stream is the target stream, returning
the affected event ids.

Served by @ix_stream_events_stream_version@ (or the unique replacement
@ux_stream_events_stream_version@ after EP-5 M3) on @(stream_id,
stream_version)@. After 'deleteJunctionsByEventIdsStmt' this matches only
events that originated elsewhere and were linked into the deleted stream. Those
events normally survive; returning them lets the same orphan check make the
decision instead of relying on that assumption.
-}
deleteStreamOwnJunctionsStmt :: Statement Int64 (Vector UUID)
deleteStreamOwnJunctionsStmt =
    preparable
        """
        DELETE FROM stream_events
        WHERE stream_id = $1
        RETURNING event_id
        """
        (E.param (E.nonNullable E.int8))
        (D.rowVector (D.column (D.nonNullable D.uuid)))

{- | Delete dead-letter rows for candidate events that have become orphaned.

Served by @ix_dead_letters_event_id@. The @NOT EXISTS@ predicate mirrors
'deleteOrphanedEventsStmt', so dead letters are purged exactly for events whose
payload rows are about to be removed while dead letters for surviving linked-in
events remain.

Must be called after the junction deletes and before 'deleteOrphanedEventsStmt'
within the same transaction so the @NOT EXISTS@ subquery sees the post-delete
state of @stream_events@ and the @dead_letters.event_id@ foreign key remains
satisfied when orphan event payloads are deleted.
-}
deleteDeadLettersForOrphanedEventsStmt :: Statement (Vector UUID) ()
deleteDeadLettersForOrphanedEventsStmt =
    preparable
        """
        DELETE FROM dead_letters dl
        WHERE dl.event_id = ANY($1::uuid[])
          AND NOT EXISTS (
            SELECT 1 FROM stream_events se
            WHERE se.event_id = dl.event_id
          )
        """
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        D.noResult

{- | Delete event payloads from the @events@ table for the given event ids,
but only those whose junction rows have all been removed. Events that still
have any surviving @stream_events@ row are preserved (they remain visible from
their other homes).

The first implementation tried to inline orphan-event deletion with a
data-modifying CTE, but PostgreSQL §7.8.2 specifies that data-modifying CTEs run
against the same snapshot, so the @NOT EXISTS@ subquery on stream_events saw the
pre-delete state and never deleted any events. Splitting into multiple
statements within the same hasql-transaction lets each statement see previous
statements' effects.

Must be called after 'deleteDeadLettersForOrphanedEventsStmt' within the same
transaction so the @NOT EXISTS@ subquery sees the post-delete state of
@stream_events@ and the @dead_letters.event_id@ foreign key is already clear.
-}
deleteOrphanedEventsStmt :: Statement (Vector UUID) ()
deleteOrphanedEventsStmt =
    preparable
        """
        DELETE FROM events
        WHERE event_id = ANY($1::uuid[])
          AND NOT EXISTS (
            SELECT 1 FROM stream_events
            WHERE stream_events.event_id = events.event_id
          )
        """
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        D.noResult

{- | Delete the @streams@ row for the given stream id. Used as the final step
of hard-delete after junction rows and orphan events are cleared.
-}
deleteStreamRowStmt :: Statement Int64 ()
deleteStreamRowStmt =
    preparable
        "DELETE FROM streams WHERE stream_id = $1"
        (E.param (E.nonNullable E.int8))
        D.noResult

{- | Pre-acquire row locks on the named streams in deterministic (stream_id)
order. Used by AppendMultiStream to avoid row-lock deadlocks between
concurrent multi-stream transactions that touch overlapping streams in
different orders.

Streams that don't yet exist (NoStream variant on a fresh stream) are not
matched by the WHERE clause, so they aren't pre-locked here; concurrent
INSERTs of a fresh stream serialize on the unique index on @stream_name@.
\$all is intentionally NOT included in the pre-lock — its row lock is
acquired by each per-stream CTE inside the transaction, after the source
stream's row lock, so deadlocks between multi-stream and single-stream
transactions are avoided as long as both lock kinds in the same order
(source-first, then $all). See EP-1 F4.
-}
lockStreamsForMultiStmt :: Statement (Vector Text) ()
lockStreamsForMultiStmt =
    preparable
        """
        SELECT 1 FROM streams
        WHERE stream_name = ANY($1::text[])
        ORDER BY stream_id
        FOR UPDATE
        """
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        D.noResult

-- ---------------------------------------------------------------------------
-- Lifecycle SQL Templates
-- ---------------------------------------------------------------------------

softDeleteStreamSQL :: Text
softDeleteStreamSQL =
    """
    UPDATE streams
    SET deleted_at = now()
    WHERE stream_name = $1
      AND deleted_at IS NULL
    RETURNING stream_id
    """

undeleteStreamSQL :: Text
undeleteStreamSQL =
    """
    UPDATE streams
    SET deleted_at = NULL
    WHERE stream_name = $1
      AND deleted_at IS NOT NULL
    RETURNING stream_id
    """

-- ---------------------------------------------------------------------------
-- Checkpoint Statements
-- ---------------------------------------------------------------------------

-- | Read the last-seen global position for a subscription.
getCheckpointStmt :: Statement Text (Maybe Int64)
getCheckpointStmt =
    preparable
        getCheckpointSQL
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (D.column (D.nonNullable D.int8)))

-- | Upsert a checkpoint: insert or update the last-seen position.
saveCheckpointStmt :: Statement (Text, Int64) ()
saveCheckpointStmt =
    preparable
        saveCheckpointSQL
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int8))
        )
        D.noResult

getCheckpointSQL :: Text
getCheckpointSQL =
    """
    SELECT last_seen
    FROM subscriptions
    WHERE subscription_name = $1
    """

saveCheckpointSQL :: Text
saveCheckpointSQL =
    """
    INSERT INTO subscriptions (subscription_name, last_seen, updated_at)
    VALUES ($1, $2, now())
    ON CONFLICT (subscription_name, consumer_group_member)
    DO UPDATE SET last_seen = GREATEST(subscriptions.last_seen, EXCLUDED.last_seen), updated_at = now()
    """

-- | Read the last-seen position for one consumer-group member of a subscription.
getCheckpointMemberStmt :: Statement (Text, Int32) (Maybe Int64)
getCheckpointMemberStmt =
    preparable
        getCheckpointMemberSQL
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
        )
        (D.rowMaybe (D.column (D.nonNullable D.int8)))

{- | Upsert the last-seen position for one consumer-group member, keyed on the
composite @(subscription_name, consumer_group_member)@ unique index. Uses the
same @GREATEST(...)@ monotonicity as 'saveCheckpointStmt' so a save never moves
a member's checkpoint backward.
-}
saveCheckpointMemberStmt :: Statement (Text, Int32, Int64) ()
saveCheckpointMemberStmt =
    preparable
        saveCheckpointMemberSQL
        ( contrazip3
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
            (E.param (E.nonNullable E.int8))
        )
        D.noResult

getCheckpointMemberSQL :: Text
getCheckpointMemberSQL =
    """
    SELECT last_seen
    FROM subscriptions
    WHERE subscription_name = $1
      AND consumer_group_member = $2
    """

saveCheckpointMemberSQL :: Text
saveCheckpointMemberSQL =
    """
    INSERT INTO subscriptions (subscription_name, consumer_group_member, last_seen, updated_at)
    VALUES ($1, $2, $3, now())
    ON CONFLICT (subscription_name, consumer_group_member)
    DO UPDATE SET last_seen = GREATEST(subscriptions.last_seen, EXCLUDED.last_seen), updated_at = now()
    """

-- ---------------------------------------------------------------------------
-- Dead-letter Statements
-- ---------------------------------------------------------------------------

-- | Parameters for 'insertDeadLetterAndCheckpointStmt'.
data DeadLetterParams = DeadLetterParams
    { dlSubscriptionName :: !Text
    , dlMember :: !Int32
    , dlGlobalPosition :: !Int64
    , dlEventId :: !UUID
    , dlReason :: !Value
    -- ^ structured JSONB reason (@reason@ column)
    , dlReasonSummary :: !Text
    -- ^ operator-facing summary (@reason_summary@ column)
    , dlAttemptCount :: !Int32
    }
    deriving stock (Show, Generic)

-- | A row of @kiroku.dead_letters@, returned by 'readDeadLettersStmt'.
data DeadLetterRecord = DeadLetterRecord
    { deadLetterGlobalPosition :: !Int64
    , deadLetterEventId :: !UUID
    , deadLetterReason :: !Value
    , deadLetterReasonSummary :: !Text
    , deadLetterAttemptCount :: !Int32
    , deadLetterCreatedAt :: !UTCTime
    }
    deriving stock (Show, Generic)

deadLetterParamsEncoder :: E.Params DeadLetterParams
deadLetterParamsEncoder =
    ((^. #dlSubscriptionName) >$< E.param (E.nonNullable E.text))
        <> ((^. #dlMember) >$< E.param (E.nonNullable E.int4))
        <> ((^. #dlGlobalPosition) >$< E.param (E.nonNullable E.int8))
        <> ((^. #dlEventId) >$< E.param (E.nonNullable E.uuid))
        <> ((^. #dlReason) >$< E.param (E.nonNullable E.jsonb))
        <> ((^. #dlReasonSummary) >$< E.param (E.nonNullable E.text))
        <> ((^. #dlAttemptCount) >$< E.param (E.nonNullable E.int4))

{- | Atomically record an event in @kiroku.dead_letters@ and advance the
subscription's checkpoint past it, in a single statement.

The dead-letter insert and the checkpoint upsert run in one round trip: a
data-modifying CTE performs the insert (idempotent via @ON CONFLICT DO NOTHING@
on the natural key), and the final statement upserts the checkpoint with the
same @GREATEST(...)@ monotonicity as 'saveCheckpointMemberStmt'. If the insert
fails the whole statement aborts and the checkpoint does not advance, satisfying
the dead-letter atomicity criterion. The checkpoint reuses @$1@/@$2@/@$3@
(name / member / global_position) from the dead-letter params.
-}
insertDeadLetterAndCheckpointStmt :: Statement DeadLetterParams ()
insertDeadLetterAndCheckpointStmt =
    preparable
        insertDeadLetterAndCheckpointSQL
        deadLetterParamsEncoder
        D.noResult

insertDeadLetterAndCheckpointSQL :: Text
insertDeadLetterAndCheckpointSQL =
    """
    WITH dl AS (
      INSERT INTO dead_letters
        (subscription_name, consumer_group_member, global_position, event_id, reason, reason_summary, attempt_count)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      ON CONFLICT (subscription_name, consumer_group_member, global_position, event_id) DO NOTHING
    )
    INSERT INTO subscriptions (subscription_name, consumer_group_member, last_seen, updated_at)
    VALUES ($1, $2, $3, now())
    ON CONFLICT (subscription_name, consumer_group_member)
    DO UPDATE SET last_seen = GREATEST(subscriptions.last_seen, EXCLUDED.last_seen), updated_at = now()
    """

-- | Read the dead letters recorded for one subscription member, newest first.
readDeadLettersStmt :: Statement (Text, Int32) (Vector DeadLetterRecord)
readDeadLettersStmt =
    preparable
        readDeadLettersSQL
        ( contrazip2
            (E.param (E.nonNullable E.text))
            (E.param (E.nonNullable E.int4))
        )
        (D.rowVector deadLetterRecordRow)

deadLetterRecordRow :: D.Row DeadLetterRecord
deadLetterRecordRow =
    DeadLetterRecord
        <$> D.column (D.nonNullable D.int8)
        <*> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.jsonb)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.int4)
        <*> D.column (D.nonNullable D.timestamptz)

readDeadLettersSQL :: Text
readDeadLettersSQL =
    """
    SELECT global_position, event_id, reason, reason_summary, attempt_count, created_at
    FROM dead_letters
    WHERE subscription_name = $1
      AND consumer_group_member = $2
    ORDER BY global_position DESC, dead_letter_id DESC
    """
