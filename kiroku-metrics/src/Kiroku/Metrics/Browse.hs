{- | Bounded inspection reads. Stream names use stable UTF-8 byte order;
category enumeration retains the database's category collation. Cursors are
exclusive and describe live pages rather than a cross-request snapshot.
-}
module Kiroku.Metrics.Browse (
    StoreBrowser (..),
    storeBrowser,
    storeBrowserWith,
    BrowseLimits,
    BrowseLimitsError (..),
    mkBrowseLimits,
    defaultLimit,
    maxLimit,
    defaultBrowseLimits,
    ReadDirection (..),
    browseApp,
    browseNotConfiguredApp,
    streamInfoToJSON,
) where

import Data.Aeson (Value, encode, object, toJSON, (.=))
import Data.ByteString qualified as BS
import Data.Int (Int32, Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.Vector (Vector)
import Data.Vector qualified as V
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Kiroku.Metrics.JSON (errorResponse, jsonResponse, storeErrorResponse)
import Kiroku.Metrics.WebSocket (recordedEventToJSONResolved)
import Kiroku.Store
import Network.HTTP.Types (Status, status200, status400, status404, status405)
import Network.Wai (Application, Request, Response, mapResponseHeaders, pathInfo, queryString, requestMethod, responseHeaders, responseLBS, responseStatus)
import Text.Read (readMaybe)

data StoreBrowser = StoreBrowser
    { runStoreRead :: forall a. Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)
    , limits :: !BrowseLimits
    }

data BrowseLimits = BrowseLimits {defaultLimit :: !Int, maxLimit :: !Int}
    deriving stock (Eq, Show)
data BrowseLimitsError = InvalidBrowseLimits !Int !Int deriving stock (Eq, Show)
mkBrowseLimits :: Int -> Int -> Either BrowseLimitsError BrowseLimits
mkBrowseLimits def cap
    | 1 <= def && def <= cap && cap <= 1000 = Right (BrowseLimits def cap)
    | otherwise = Left (InvalidBrowseLimits def cap)
defaultBrowseLimits :: BrowseLimits
defaultBrowseLimits = BrowseLimits 100 1000
storeBrowser :: KirokuStore -> StoreBrowser
storeBrowser = storeBrowserWith defaultBrowseLimits
storeBrowserWith :: BrowseLimits -> KirokuStore -> StoreBrowser
storeBrowserWith lims store = StoreBrowser (runStoreIO store) lims

data ReadDirection = ReadForward | ReadBackward deriving stock (Eq, Show)
type ReadProgram a = Eff '[Store, Error StoreError, IOE] a
type Failure = (Status, Text, Text, Maybe Value)

-- | Preserve GET status/headers for HEAD. Other methods never run a read.
readMethods :: (Request -> IO Response) -> Application
readMethods action req respond
    | requestMethod req == "GET" = action req >>= respond
    | requestMethod req == "HEAD" = do
        response <- action req
        respond (responseLBS (responseStatus response) (responseHeaders response) "")
    | otherwise =
        respond $
            mapResponseHeaders (("Allow", "GET, HEAD") :) $
                errorResponse status405 "method_not_allowed" "Only GET and HEAD are supported." Nothing

browseNotConfiguredApp :: Application
browseNotConfiguredApp = readMethods $ \_ -> pure (errorResponse status404 "store_browsing_not_configured" "Store browsing is not configured." Nothing)

browseApp :: StoreBrowser -> Application
browseApp browser = readMethods $ \req -> case route browser req of
    Left (status, code, message, details) -> pure (errorResponse status code message details)
    Right program ->
        runStoreRead browser program >>= \case
            Left err -> pure (storeErrorResponse "store_unavailable" err)
            Right (Left (status, code, message, details)) -> pure (errorResponse status code message details)
            Right (Right value) -> pure (jsonResponse status200 (encode value))

route :: StoreBrowser -> Request -> Either Failure (ReadProgram (Either Failure Value))
route browser req = case pathInfo req of
    ["streams"] -> do
        limit <- pageLimit
        category <- fmap CategoryName <$> textParam "category"
        prefix <- textParam "prefix"
        cursor <- fmap StreamName <$> textParam "from"
        size <- browseSize limit
        pure $ do
            rows <- listStreams category prefix cursor size
            pure $ Right $ pageJSON limit streamInfoToJSON (\row -> let StreamName name = row.name in AesonText name) rows
    ["streams", name] -> do
        stream <- validStream name
        pure $ getStream stream >>= pure . maybe (Left (missing "stream_not_found" "Stream not found.")) (Right . streamInfoToJSON)
    ["streams", name, "events"] -> do
        stream <- validStream name
        limit <- pageLimit
        cursor <- position
        direction <- readDirection
        pure $
            getStream stream >>= \case
                Nothing -> pure (Left (missing "stream_not_found" "Stream not found."))
                Just _ ->
                    Right
                        <$> eventPage
                            limit
                            (\event -> let StreamVersion v = event.streamVersion in AesonNumber v)
                            (case direction of ReadForward -> readStreamForward stream (StreamVersion cursor) (overfetch limit); ReadBackward -> readStreamBackward stream (StreamVersion cursor) (overfetch limit))
    ["categories"] -> do
        limit <- pageLimit
        cursor <- fmap CategoryName <$> textParam "from"
        size <- browseSize limit
        pure $ do
            rows <- listCategories cursor size
            pure $ Right $ pageJSON limit (\(CategoryName name) -> object ["name" .= name]) (\(CategoryName name) -> AesonText name) rows
    ["categories", name, "events"] -> do
        validText "category" name
        limit <- pageLimit
        cursor <- position
        -- Category reads have one supported direction; do not silently ignore it.
        direction <- readDirection
        if direction == ReadBackward
            then Left (invalid "direction" "backward" "Category events support forward reads.")
            else
                pure $ Right <$> eventPage limit globalCursor (readCategory (CategoryName name) (GlobalPosition cursor) (overfetch limit))
    ["events"] -> do
        limit <- pageLimit
        cursor <- position
        direction <- readDirection
        pure $
            Right
                <$> eventPage
                    limit
                    globalCursor
                    (case direction of ReadForward -> readAllForward (GlobalPosition cursor) (overfetch limit); ReadBackward -> readAllBackward (GlobalPosition cursor) (overfetch limit))
    ["events", rawId] -> case UUID.fromText rawId of
        Nothing -> Left (status400, "invalid_event_id", "The event id must be a UUID.", Nothing)
        Just uuid ->
            pure $
                getEvent (EventId uuid) >>= \case
                    Nothing -> pure (Left (missing "event_not_found" "Event not found."))
                    Just event -> do
                        mapping <- lookupStreamNames [event.originalStreamId]
                        pure (Right (recordedEventToJSONResolved mapping event))
    _ -> Left (missing "not_found" "Not found.")
  where
    pageLimit = do
        value <- rawParam req "limit"
        case value of
            Nothing -> Right browser.limits.defaultLimit
            Just raw -> case decimal raw of
                Just n | 1 <= n && n <= toInteger browser.limits.maxLimit -> Right (fromInteger n)
                _ -> Left (invalid "limit" raw "Expected a decimal integer within the configured page limit.")
    textParam key = do
        value <- rawParam req key
        mapM_ (validText key) value
        pure value
    position = do
        value <- rawParam req "from"
        case value of
            Nothing -> Right 0
            Just raw -> case decimal raw of
                Just n | n <= toInteger (maxBound :: Int64) -> Right (fromInteger n)
                _ -> Left (invalid "from" raw "Expected a non-negative Int64 decimal integer.")
    readDirection =
        rawParam req "direction" >>= \case
            Nothing -> Right ReadForward
            Just "forward" -> Right ReadForward
            Just "backward" -> Right ReadBackward
            Just raw -> Left (invalid "direction" raw "Expected forward or backward.")

-- Closed bounds make over-fetch safe before conversion to the store's Int32.
overfetch :: Int -> Int32
overfetch limit = fromIntegral (limit + 1)
browseSize :: Int -> Either Failure BrowsePageSize
browseSize limit = case mkBrowsePageSize (limit + 1) of
    Right size -> Right size
    Left _ -> Left (invalid "limit" (T.pack (show limit)) "Invalid page limit.")

data Cursor = AesonText Text | AesonNumber Int64
cursorJSON :: Cursor -> Value
cursorJSON (AesonText text) = toJSON text
cursorJSON (AesonNumber n) = toJSON n

pageJSON :: Int -> (a -> Value) -> (a -> Cursor) -> Vector a -> Value
pageJSON limit encodeItem cursor rows =
    object $ ["items" .= V.map encodeItem items] <> ["next_cursor" .= cursorJSON (cursor (V.last items)) | V.length rows > limit && not (V.null items)]
  where
    items = V.take limit rows

eventPage :: Int -> (RecordedEvent -> Cursor) -> ReadProgram (Vector RecordedEvent) -> ReadProgram Value
eventPage limit cursor readPage = do
    rows <- readPage
    mapping <- resolveNames (V.take limit rows)
    pure (pageJSON limit (recordedEventToJSONResolved mapping) cursor rows)
resolveNames :: Vector RecordedEvent -> ReadProgram (Map StreamId StreamName)
resolveNames rows
    | V.null rows = pure Map.empty
    | otherwise = lookupStreamNames (Set.toList (Set.fromList (map (\event -> event.originalStreamId) (V.toList rows))))
globalCursor :: RecordedEvent -> Cursor
globalCursor event = let GlobalPosition n = event.globalPosition in AesonNumber n

streamInfoToJSON :: StreamInfo -> Value
streamInfoToJSON stream =
    object
        [ "stream_id" .= (let StreamId n = stream.id in n)
        , "name" .= (let StreamName name = stream.name in name)
        , "category" .= (let CategoryName category = categoryName stream.name in category)
        , "version" .= (let StreamVersion n = stream.version in n)
        , "created_at" .= stream.createdAt
        , "deleted_at" .= stream.deletedAt
        , "truncate_before" .= (let StreamVersion n = stream.truncateBefore in n)
        ]

missing :: Text -> Text -> Failure
missing code message = (status404, code, message, Nothing)
invalid :: Text -> Text -> Text -> Failure
invalid key raw reason = (status400, "invalid_query_parameter", "Invalid query parameter.", Just (object ["parameter" .= key, "value" .= raw, "reason" .= reason]))
rawParam :: Request -> BS.ByteString -> Either Failure (Maybe Text)
rawParam req key = case lookup key (queryString req) of
    Nothing -> Right Nothing
    Just Nothing -> Right (Just "")
    Just (Just bytes) -> case TE.decodeUtf8' bytes of
        Right value -> Right (Just value)
        Left _ -> Left (invalid (TE.decodeUtf8 key) "<invalid UTF-8>" "Expected valid UTF-8.")
validText :: BS.ByteString -> Text -> Either Failure ()
validText key value
    | T.any (== '\0') value || BS.length (TE.encodeUtf8 value) > 512 = Left (invalid (TE.decodeUtf8 key) value "Expected at most 512 UTF-8 bytes without NUL.")
    | otherwise = Right ()
validStream :: Text -> Either Failure StreamName
validStream value = case validateStreamName (StreamName value) of
    Right () | not (T.any (== '\0') value) -> Right (StreamName value)
    _ -> Left (status400, "invalid_stream_name", "Invalid stream name.", Just (object ["stream_name" .= value]))
decimal :: Text -> Maybe Integer
decimal value
    | T.null value || not (T.all (\c -> '0' <= c && c <= '9') value) = Nothing
    | T.length value > 20 = Nothing
    | otherwise = readMaybe (T.unpack value)
