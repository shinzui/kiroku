-- | Read-only subscription dead-letter inspection with exclusive keyset pages.
module Kiroku.Metrics.DeadLetters (
    DeadLetterProvider,
    storeDeadLetters,
    DeadLetterItem (..),
    DeadLetterPageResponse (..),
    deadLetterPageResponse,
    renderDeadLetterCursor,
    parseDeadLetterCursor,
    DeadLetterRequest (..),
    parseDeadLetterRequest,
    deadLettersApp,
    deadLettersNotConfiguredApp,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, encode, object, withObject, (.:), (.:?), (.=))
import Data.ByteString qualified as BS
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import Data.Vector qualified as V
import Kiroku.Metrics.JSON (errorResponse, jsonResponse, storeErrorResponse)
import Kiroku.Store qualified as Store
import Network.HTTP.Types (Query, Status, status200, status400, status404, status405)
import Network.Wai (Application, Response, mapResponseHeaders, pathInfo, queryString, requestMethod, responseHeaders, responseLBS, responseStatus)
import Text.Read (readMaybe)

type DeadLetterProvider = Store.SubscriptionDeadLetterQuery -> IO (Either Store.StoreError Store.SubscriptionDeadLetterPage)
storeDeadLetters :: Store.KirokuStore -> DeadLetterProvider
storeDeadLetters store = Store.runStoreIO store . Store.subscriptionDeadLetters

data DeadLetterItem = DeadLetterItem
    { deadLetterId :: !Int64
    , subscription :: !Text
    , member :: !Int32
    , globalPosition :: !Int64
    , eventId :: !UUID
    , reason :: !Value
    , reasonSummary :: !Text
    , attemptCount :: !Int32
    , createdAt :: !UTCTime
    }
    deriving stock (Eq, Show)
data DeadLetterPageResponse = DeadLetterPageResponse
    { items :: ![DeadLetterItem]
    , nextCursor :: !(Maybe Text)
    }
    deriving stock (Eq, Show)
instance ToJSON DeadLetterItem where
    toJSON row = object ["dead_letter_id" .= row.deadLetterId, "subscription" .= row.subscription, "member" .= row.member, "global_position" .= row.globalPosition, "event_id" .= row.eventId, "reason" .= row.reason, "reason_summary" .= row.reasonSummary, "attempt_count" .= row.attemptCount, "created_at" .= row.createdAt]
instance FromJSON DeadLetterItem where
    parseJSON = withObject "DeadLetterItem" $ \o -> DeadLetterItem <$> o .: "dead_letter_id" <*> o .: "subscription" <*> o .: "member" <*> o .: "global_position" <*> o .: "event_id" <*> o .: "reason" <*> o .: "reason_summary" <*> o .: "attempt_count" <*> o .: "created_at"
instance ToJSON DeadLetterPageResponse where
    toJSON page = object (["items" .= page.items] <> maybe [] (\cursor -> ["next_cursor" .= cursor]) page.nextCursor)
instance FromJSON DeadLetterPageResponse where
    parseJSON = withObject "DeadLetterPageResponse" $ \o -> DeadLetterPageResponse <$> o .: "items" <*> o .:? "next_cursor"
deadLetterPageResponse :: Store.SubscriptionDeadLetterPage -> DeadLetterPageResponse
deadLetterPageResponse (Store.SubscriptionDeadLetterPage rows cursor) = DeadLetterPageResponse (map item (V.toList rows)) (renderDeadLetterCursor <$> cursor)
  where
    item (Store.SubscriptionDeadLetter ident (Store.SubscriptionName name) member (Store.GlobalPosition position) (Store.EventId eid) reason summary attempts date) = DeadLetterItem ident name member position eid reason summary attempts date

renderDeadLetterCursor :: Store.SubscriptionDeadLetterCursor -> Text
renderDeadLetterCursor (Store.SubscriptionDeadLetterCursor (Store.GlobalPosition position) ident) = T.pack (show position) <> ":" <> T.pack (show ident)
parseDeadLetterCursor :: Text -> Maybe Store.SubscriptionDeadLetterCursor
parseDeadLetterCursor raw = case T.splitOn ":" raw of
    [p, i] -> Store.SubscriptionDeadLetterCursor . Store.GlobalPosition <$> unsigned p <*> unsigned i
    _ -> Nothing
unsigned :: forall a. (Integral a, Bounded a) => Text -> Maybe a
unsigned raw
    | T.null raw || T.length raw > 20 || not (T.all (\c -> c >= '0' && c <= '9') raw) = Nothing
    | otherwise = do
        value <- readMaybe (T.unpack raw) :: Maybe Integer
        if value <= toInteger (maxBound @a) then Just (fromInteger value) else Nothing

data DeadLetterRequest = DeadLetterRequest
    { requestMember :: !(Maybe Int32)
    , requestAfter :: !(Maybe Store.SubscriptionDeadLetterCursor)
    , requestLimit :: !Store.SubscriptionDeadLetterLimit
    }
    deriving stock (Eq, Show)
type Failure = (Status, Text, Text, Maybe Value)
invalid :: Text -> Text -> Text -> Failure
invalid parameter value reason = (status400, "invalid_query_parameter", "Invalid query parameter.", Just (object ["parameter" .= parameter, "value" .= value, "reason" .= reason]))
parseDeadLetterRequest :: Query -> Either Failure DeadLetterRequest
parseDeadLetterRequest query = do
    member <- parameter "member" unsigned "Expected a non-negative Int32 decimal integer."
    cursor <- parameter "from" parseDeadLetterCursor "Expected an opaque position:id cursor with non-negative Int64 components."
    size <- parameter "limit" validLimit "Expected a decimal page size from 1 through 1000."
    pure (DeadLetterRequest member cursor (maybe Store.defaultSubscriptionDeadLetterLimit id size))
  where
    validLimit raw = unsigned raw >>= either (const Nothing) Just . Store.mkSubscriptionDeadLetterLimit
    parameter :: Text -> (Text -> Maybe a) -> Text -> Either Failure (Maybe a)
    parameter key parser reason = case [v | (k, v) <- query, k == TE.encodeUtf8 key] of
        [] -> Right Nothing
        [Just bytes] -> case TE.decodeUtf8' bytes of
            Left _ -> Left (invalid key "<invalid UTF-8>" "Expected valid UTF-8.")
            Right raw -> maybe (Left (invalid key raw reason)) (Right . Just) (parser raw)
        [Nothing] -> Left (invalid key "" reason)
        _ -> Left (invalid key "<duplicate>" "Parameter must occur at most once.")

-- | Applies GET/HEAD/405 at WAI level, including when mounted without Warp.
readMethods :: IO Response -> Application
readMethods action req respond
    | requestMethod req == "GET" = action >>= respond
    | requestMethod req == "HEAD" = action >>= \response -> respond (responseLBS (responseStatus response) (responseHeaders response) "")
    | otherwise = respond $ mapResponseHeaders (("Allow", "GET, HEAD") :) $ errorResponse status405 "method_not_allowed" "Only GET and HEAD are supported." Nothing

deadLettersNotConfiguredApp :: Application
deadLettersNotConfiguredApp req = readMethods (pure (errorResponse status404 "dead_letters_not_configured" "Dead letters are not configured." Nothing)) req

deadLettersApp :: DeadLetterProvider -> Application
deadLettersApp provider req = readMethods action req
  where
    action = case pathInfo req of
        ["subscriptions", name, "dead-letters"]
            | T.any (== '\0') name || BS.length (TE.encodeUtf8 name) > 512 -> pure $ failure (invalid "subscription" name "Expected at most 512 UTF-8 bytes without NUL.")
            | otherwise -> case parseDeadLetterRequest (queryString req) of
                Left err -> pure (failure err)
                Right (DeadLetterRequest member cursor size) ->
                    provider (Store.SubscriptionDeadLetterQuery (Store.SubscriptionName name) member cursor size) >>= \case
                        Left err -> pure (storeErrorResponse "dead_letters_unavailable" err)
                        Right page -> pure (jsonResponse status200 (encode (deadLetterPageResponse page)))
        _ -> pure (errorResponse status404 "not_found" "Not found" Nothing)
    failure (status, code, message, details) = errorResponse status code message details
