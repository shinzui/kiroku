module Kiroku.Store.Append (
    appendToStream,
) where

import Control.Lens ((^.))
import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.UUID (UUID)
import Data.UUID.V7 qualified as V7
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Error (AppendError (..), emptyResultError, mapUsageError)
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Types

{- | Append events to a stream with the given expected version.

This is the core write operation of the event store. Each call is a single
SQL round-trip using a CTE that atomically:
  1. Checks/updates the source stream version
  2. Inserts events into the events table
  3. Links events to the source stream
  4. Claims contiguous global positions on $all
  5. Links events to $all

Returns 'Right AppendResult' on success with the new stream version and
global position. Returns 'Left AppendError' on failure.
-}
appendToStream ::
    KirokuStore ->
    StreamName ->
    ExpectedVersion ->
    [EventData] ->
    IO (Either AppendError AppendResult)
appendToStream store (StreamName name) expected events = do
    -- 1. Pre-generate UUIDv7s for events without caller-supplied IDs
    --    and capture the current time for created_at
    now <- getCurrentTime
    prepared <- prepareEvents events

    -- 2. Build the SQL parameters
    let params = buildAppendParams name now prepared

    -- 3. Run the appropriate CTE variant
    result <- Pool.use (store ^. #pool) $ case expected of
        ExactVersion (StreamVersion v) ->
            Session.statement (params, v) SQL.appendExpectedVersion
        StreamExists ->
            Session.statement params SQL.appendStreamExists
        NoStream ->
            Session.statement params SQL.appendNoStream
        AnyVersion ->
            Session.statement params SQL.appendAnyVersion

    -- 4. Map result
    pure $ case result of
        Left usageErr ->
            Left (mapUsageError name expected usageErr)
        Right Nothing ->
            Left (emptyResultError name expected)
        Right (Just r) ->
            Right r

-- | An event with a guaranteed event ID (pre-generated if needed).
data PreparedEvent = PreparedEvent
    { peEventId :: !UUID
    , peEventType :: !EventType
    , pePayload :: !Value
    , peMetadata :: !(Maybe Value)
    , peCausationId :: !(Maybe UUID)
    , peCorrelationId :: !(Maybe UUID)
    }
    deriving stock (Generic)

{- | Prepare events by generating UUIDv7s for any event that doesn't
have a caller-supplied event ID.
-}
prepareEvents :: [EventData] -> IO [PreparedEvent]
prepareEvents events = do
    let needCount = length (filter (\(EventData eid _ _ _ _ _) -> isNothing eid) events)
    newIds <-
        if needCount > 0
            then V7.genUUIDs (fromIntegral needCount)
            else pure []
    pure (assign events newIds)
  where
    assign :: [EventData] -> [UUID] -> [PreparedEvent]
    assign [] _ = []
    assign (EventData mEid eType ePayload eMeta eCaus eCorr : es) ids =
        case mEid of
            Just (EventId uid) ->
                PreparedEvent uid eType ePayload eMeta eCaus eCorr
                    : assign es ids
            Nothing -> case ids of
                (uid : rest) ->
                    PreparedEvent uid eType ePayload eMeta eCaus eCorr
                        : assign es rest
                [] -> error "prepareEvents: ran out of pre-generated UUIDs (bug)"

-- | Build SQL parameters from prepared events.
buildAppendParams :: Text -> UTCTime -> [PreparedEvent] -> SQL.AppendParams
buildAppendParams name now prepared =
    SQL.AppendParams
        { eventIds = V.fromList (map (^. #peEventId) prepared)
        , eventTypes = V.fromList (map (\e -> let EventType t = e ^. #peEventType in t) prepared)
        , causationIds = V.fromList (map (^. #peCausationId) prepared)
        , correlationIds = V.fromList (map (^. #peCorrelationId) prepared)
        , payloads = V.fromList (map (^. #pePayload) prepared)
        , metadatas = V.fromList (map (^. #peMetadata) prepared)
        , createdAts = V.fromList (replicate (length prepared) now)
        , streamName = name
        }
