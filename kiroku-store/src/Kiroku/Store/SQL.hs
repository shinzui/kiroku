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
) where

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
    (fst >$< appendParamsEncoder)
        <> (snd >$< E.param (E.nonNullable E.int8))

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
    ((\(a, _, _) -> a) >$< E.param (E.nonNullable E.text))
        <> ((\(_, b, _) -> b) >$< E.param (E.nonNullable E.int8))
        <> ((\(_, _, c) -> c) >$< E.param (E.nonNullable E.int4))

-- | Encoder for $all read params: (start_position, limit).
readAllEncoder :: E.Params (Int64, Int32)
readAllEncoder =
    (fst >$< E.param (E.nonNullable E.int8))
        <> (snd >$< E.param (E.nonNullable E.int4))

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

-- | Get stream metadata by name.
getStreamStmt :: Statement Text (Maybe StreamInfo)
getStreamStmt =
    preparable
        getStreamSQL
        (E.param (E.nonNullable E.text))
        (D.rowMaybe streamInfoRow)

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
    WHERE se.stream_id = (SELECT stream_id FROM streams WHERE stream_name = $1)
      AND se.stream_version > $2
    ORDER BY se.stream_version ASC
    LIMIT $3
    """

-- | Read from a named stream in backward order.
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
    WHERE se.stream_id = (SELECT stream_id FROM streams WHERE stream_name = $1)
      AND se.stream_version > $2
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

-- | Read from the global $all stream in backward order.
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
      AND se.stream_version > $1
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
-- Link Statements
-- ---------------------------------------------------------------------------

-- | Link existing events into a target stream (upsert semantics).
linkToStreamStmt :: Statement (Vector UUID, Text) LinkResult
linkToStreamStmt =
    preparable
        linkToStreamSQL
        linkEncoder
        linkResultDecoder

linkEncoder :: E.Params (Vector UUID, Text)
linkEncoder =
    (fst >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        <> (snd >$< E.param (E.nonNullable E.text))

linkResultDecoder :: D.Result LinkResult
linkResultDecoder =
    D.singleRow $
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
        RETURNING stream_id, stream_version - (SELECT count(*) FROM event_list) AS initial_version
      ),
      link_inserts AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT el.event_id, su.stream_id, su.initial_version + el.idx,
               orig.original_stream_id, orig.original_stream_version
        FROM event_list el
        CROSS JOIN stream_upsert su
        JOIN LATERAL (
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
    ((\(a, _, _) -> a) >$< E.param (E.nonNullable E.int8))
        <> ((\(_, b, _) -> b) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, c) -> c) >$< E.param (E.nonNullable E.int4))

readCategoryForwardSQL :: Text
readCategoryForwardSQL =
    """
    SELECT e.event_id, e.event_type,
           se.stream_version, se.stream_version AS global_position,
           se.original_stream_id, se.original_stream_version,
           e.data, e.metadata, e.causation_id, e.correlation_id,
           e.created_at
    FROM stream_events se
    JOIN events e ON e.event_id = se.event_id
    JOIN streams s ON s.stream_id = se.original_stream_id
    WHERE se.stream_id = 0
      AND se.stream_version > $1
      AND s.category = $2
    ORDER BY se.stream_version ASC
    LIMIT $3
    """
