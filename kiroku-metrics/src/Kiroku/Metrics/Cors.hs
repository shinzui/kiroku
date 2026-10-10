{-# LANGUAGE BangPatterns #-}

-- | Default-off browser access for HTTP and WebSocket inspection surfaces.
module Kiroku.Metrics.Cors (
    AllowedOrigin,
    OriginError (..),
    allowedOrigin,
    renderAllowedOrigin,
    CorsPolicy (..),
    corsDisabled,
    corsAllowOrigins,
    corsEnabled,
    corsAllowedMethods,
    originAllowed,
    isPreflight,
    corsMiddleware,
) where

import Control.Monad (guard)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.Char (digitToInt, isAscii, isAsciiLower, isAsciiUpper, isHexDigit, ord, toLower)
import Data.List (nubBy)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types (HeaderName, RequestHeaders, ResponseHeaders, hOrigin, hVary, methodOptions, status204, status400, status403)
import Network.Wai (Middleware, Request, mapResponseHeaders, requestHeaders, requestMethod, responseLBS)
import Network.Wai.Handler.WebSockets (isWebSocketsReq)
import Numeric (showHex)

import Kiroku.Metrics.JSON (errorResponse)

-- | An explicit normalized HTTP(S) origin. Construct with 'allowedOrigin'.
newtype AllowedOrigin = AllowedOrigin Text
    deriving stock (Eq, Ord, Show)

-- | Configuration errors; input is retained only for the host's diagnostic use.
data OriginError
    = WildcardOrigin
    | OpaqueOrigin
    | MissingScheme Text
    | EmptyHost Text
    | HasPathQueryOrFragment Text
    | NotAnOrigin Text
    deriving stock (Eq, Show)

{- | Validate configuration, trimming whitespace and tolerating one final slash.
DNS hosts must be ASCII; use the ASCII form of internationalized names.
-}
allowedOrigin :: Text -> Either OriginError AllowedOrigin
allowedOrigin input = parseOrigin (maybe trimmed id (T.stripSuffix "/" trimmed))
  where
    trimmed = T.strip input

renderAllowedOrigin :: AllowedOrigin -> Text
renderAllowedOrigin (AllowedOrigin value) = value

parseOrigin :: Text -> Either OriginError AllowedOrigin
parseOrigin input
    | input == "*" = Left WildcardOrigin
    | input == "null" = Left OpaqueOrigin
    | T.any (\c -> not (isAscii c) || ord c <= 32 || ord c == 127) input = invalid
    | T.null rest = Left (MissingScheme input)
    | scheme /= "http" && scheme /= "https" = invalid
    | T.null authority = Left (EmptyHost input)
    | T.any (`elem` ("/?#" :: String)) authority = Left (HasPathQueryOrFragment input)
    | otherwise = case normalizeAuthority authority of
        Nothing -> invalid
        Just (host, mPort) ->
            let defaultPort = if scheme == "http" then 80 else 443
                suffix = maybe "" (\p -> if p == defaultPort then "" else ":" <> T.pack (show p)) mPort
             in Right (AllowedOrigin (scheme <> "://" <> host <> suffix))
  where
    (rawScheme, rest) = T.breakOn "://" input
    scheme = T.map toLower rawScheme
    authority = T.drop 3 rest
    invalid = Left (NotAnOrigin input)

normalizeAuthority :: Text -> Maybe (Text, Maybe Int)
normalizeAuthority authority = do
    guard (not (T.any (`elem` ("@%*\\" :: String)) authority))
    if T.isPrefixOf "[" authority
        then do
            let (literal, close) = T.breakOn "]" (T.drop 1 authority)
            guard (not (T.null close))
            host <- ipv6 literal
            p <- portSuffix (T.drop 1 close)
            pure ("[" <> host <> "]", p)
        else do
            let (host, suffix) = T.breakOn ":" authority
            guard (validHost host)
            p <- portSuffix suffix
            pure (T.map toLower host, p)

portSuffix :: Text -> Maybe (Maybe Int)
portSuffix "" = Just Nothing
portSuffix suffix = do
    digits <- T.stripPrefix ":" suffix
    n <- decimal digits
    guard (n <= 65535)
    pure (Just (fromInteger n))

decimal :: Text -> Maybe Integer
decimal digits = do
    guard (not (T.null digits) && T.all (\c -> c >= '0' && c <= '9') digits)
    pure (T.foldl' (\n c -> n * 10 + fromIntegral (ord c - ord '0')) 0 digits)

validHost :: Text -> Bool
validHost host
    | T.null host || T.length host > 253 = False
    | T.all (\c -> c == '.' || (c >= '0' && c <= '9')) host = isJust (ipv4 host)
    | otherwise = all validLabel (T.splitOn "." host)
  where
    validLabel label =
        not (T.null label)
            && T.length label <= 63
            && T.head label /= '-'
            && T.last label /= '-'
            && T.all (\c -> isAsciiLower c || isAsciiUpper c || (c >= '0' && c <= '9') || c == '-') label

ipv4 :: Text -> Maybe [Int]
ipv4 host = do
    let parts = T.splitOn "." host
    guard (length parts == 4)
    traverse octet parts
  where
    octet part = do
        guard (T.length part <= 3 && (T.length part == 1 || not (T.isPrefixOf "0" part)))
        n <- decimal part
        guard (n <= 255)
        pure (fromInteger n)

-- Normalize IPv6 by expanding the groups; compressed and embedded-IPv4 forms
-- compare by address, without DNS lookup or platform-dependent parsing.
ipv6 :: Text -> Maybe Text
ipv6 literal = do
    expanded <- case T.splitOn "::" literal of
        [whole] -> do
            groups <- side whole
            guard (length groups == 8)
            pure groups
        [left, right] -> do
            -- An embedded IPv4 address must occupy the final two groups.
            guard (not (T.any (== '.') left))
            l <- side left
            r <- side right
            guard (length l + length r < 8)
            pure (l <> replicate (8 - length l - length r) 0 <> r)
        _ -> Nothing
    pure (T.intercalate ":" (map (\n -> T.pack (showHex n "")) expanded))
  where
    side "" = Just []
    side value = do
        let parts = T.splitOn ":" value
        case reverse parts of
            final : remaining | T.any (== '.') final -> do
                octets <- ipv4 final
                case octets of
                    [a, b, c, d] -> do
                        preceding <- traverse hexGroup (reverse remaining)
                        pure (preceding <> [a * 256 + b, c * 256 + d])
                    _ -> Nothing
            _ -> traverse hexGroup parts
    hexGroup value = do
        guard (not (T.null value) && T.length value <= 4 && T.all isHexDigit value)
        pure (T.foldl' (\n c -> n * 16 + digitToInt c) 0 value)

-- | Empty origins disable the middleware. Negative max age is treated as absent.
data CorsPolicy = CorsPolicy
    { allowedOrigins :: ![AllowedOrigin]
    , allowCredentials :: !Bool
    , maxAgeSeconds :: !(Maybe Int)
    }
    deriving stock (Eq, Show)

corsDisabled :: CorsPolicy
corsDisabled = CorsPolicy [] False Nothing

corsAllowOrigins :: [AllowedOrigin] -> CorsPolicy
corsAllowOrigins origins = CorsPolicy origins False Nothing

corsEnabled :: CorsPolicy -> Bool
corsEnabled = not . null . (.allowedOrigins)

corsAllowedMethods :: ByteString
corsAllowedMethods = "GET, HEAD, OPTIONS"

originSet :: CorsPolicy -> Set.Set AllowedOrigin
originSet = Set.fromList . (.allowedOrigins)

-- Request parsing deliberately does not trim or strip a configuration slash.
requestOrigin :: ByteString -> Maybe AllowedOrigin
requestOrigin raw = either (const Nothing) (either (const Nothing) Just . parseOrigin) (TE.decodeUtf8' raw)

originAllowed :: CorsPolicy -> ByteString -> Bool
originAllowed policy raw = maybe False (`Set.member` originSet policy) (requestOrigin raw)

headerValues :: HeaderName -> RequestHeaders -> [ByteString]
headerValues name = map snd . filter ((== name) . fst)

isPreflight :: Request -> Bool
isPreflight req =
    requestMethod req == methodOptions
        && not (null (headerValues hOrigin (requestHeaders req)))
        && not (null (headerValues "Access-Control-Request-Method" (requestHeaders req)))

{- | Disabled policy returns the application itself. Enabled policy captures one
normalized set, protects upgrades before dispatch, and varies all HTTP responses.
Raw WebSocket responses are preserved by WAI's 'mapResponseHeaders'.
-}
corsMiddleware :: CorsPolicy -> Middleware
corsMiddleware policy
    | not (corsEnabled policy) = id
    | otherwise =
        let !origins = originSet policy
         in \app req respond ->
                let values = headerValues hOrigin (requestHeaders req)
                    grant = case values of
                        [raw] | maybe False (`Set.member` origins) (requestOrigin raw) -> Just raw
                        _ -> Nothing
                    varyKeys = if isPreflight req then ["Origin", "Access-Control-Request-Method", "Access-Control-Request-Headers"] else ["Origin"]
                    decorate = mapResponseHeaders (decorateHeaders policy grant varyKeys)
                    reply = respond . decorate
                 in if isWebSocketsReq req
                        then case (values, grant) of
                            ([], _) -> app req reply
                            (_, Just _) -> app req reply
                            _ -> reply (errorResponse status403 "origin_not_allowed" "The request origin is not allowed." Nothing)
                        else case (isPreflight req, grant) of
                            (True, Just _) -> case headerValues "Access-Control-Request-Method" (requestHeaders req) of
                                [method] | method == "GET" || method == "HEAD" ->
                                    case requestedHeaders (requestHeaders req) of
                                        Nothing -> reply (errorResponse status400 "invalid_cors_request" "Requested header names must be HTTP tokens." Nothing)
                                        Just headers ->
                                            reply (responseLBS status204 (preflightHeaders policy headers) "")
                                [_] -> reply (errorResponse status403 "cors_method_not_allowed" "The requested method is not allowed." Nothing)
                                _ -> reply (errorResponse status400 "invalid_cors_request" "A single requested method is required." Nothing)
                            _ -> app req reply

requestedHeaders :: RequestHeaders -> Maybe (Maybe ByteString)
requestedHeaders headers = case headerValues "Access-Control-Request-Headers" headers of
    [] -> Just Nothing
    values -> do
        let tokens = map trimOWS (concatMap (BS.split ',') values)
        guard (not (null tokens) && all (\t -> not (BS.null t) && BS.all tokenChar t) tokens)
        pure (Just (BS.intercalate ", " tokens))
  where
    tokenChar c = isAsciiLower c || isAsciiUpper c || (c >= '0' && c <= '9') || c `elem` ("!#$%&'*+-.^_`|~" :: String)

trimOWS :: ByteString -> ByteString
trimOWS = BS.dropWhileEnd space . BS.dropWhile space
  where
    space c = c == ' ' || c == '\t'

preflightHeaders :: CorsPolicy -> Maybe ByteString -> ResponseHeaders
preflightHeaders policy headers =
    [("Access-Control-Allow-Methods", corsAllowedMethods)]
        <> maybe [] (\v -> [("Access-Control-Allow-Headers", v)]) headers
        <> case policy.maxAgeSeconds of
            Just n | n >= 0 -> [("Access-Control-Max-Age", BS.pack (show n))]
            _ -> []

decorateHeaders :: CorsPolicy -> Maybe ByteString -> [ByteString] -> ResponseHeaders -> ResponseHeaders
decorateHeaders policy grant keys headers =
    mergeVary keys (filter (not . isGrant . fst) headers)
        <> maybe [] (\raw -> [("Access-Control-Allow-Origin", raw)] <> [("Access-Control-Allow-Credentials", "true") | policy.allowCredentials]) grant
  where
    isGrant name = name == "Access-Control-Allow-Origin" || name == "Access-Control-Allow-Credentials"

mergeVary :: [ByteString] -> ResponseHeaders -> ResponseHeaders
mergeVary keys headers =
    (hVary, BS.intercalate ", " tokens) : filter ((/= hVary) . fst) headers
  where
    existing = filter (not . BS.null) (map trimOWS (concatMap (BS.split ',' . snd) (filter ((== hVary) . fst) headers)))
    tokens
        | "*" `elem` existing = ["*"]
        | otherwise = nubBy (\a b -> BS.map toLower a == BS.map toLower b) (existing <> keys)
