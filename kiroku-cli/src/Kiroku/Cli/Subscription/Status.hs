module Kiroku.Cli.Subscription.Status (
    SubscriptionStatusRow (..),
    renderSubscriptionStatusRows,
    subscriptionStatusRows,
    fetchRemoteSubscriptionStatusRows,
    renderRemoteSubscriptionStatus,
) where

import Control.Exception (SomeException, try)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Generics (Generic)
import Kiroku.Cli.Command (OutputFormat (..), RemoteEndpoint (..))
import Kiroku.Store.Subscription (SubscriptionStateView (..))
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (GlobalPosition (..))
import Network.HTTP.Client (
    Request,
    Response,
    httpLbs,
    newManager,
    parseRequest,
    responseBody,
    responseStatus,
 )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

data SubscriptionStatusRow = SubscriptionStatusRow
    { subscription :: !Text
    , member :: !Int32
    , phase :: !Text
    , globalPosition :: !Int64
    }
    deriving stock (Generic, Eq, Show)

{- | The IP-5 wire contract: a JSON object with keys @subscription@, @member@,
@phase@, @global_position@. This is the single source of truth shared by the
@kiroku-metrics@ @\/subscriptions@ endpoint (which encodes) and the CLI remote
client (which decodes).
-}
instance Aeson.ToJSON SubscriptionStatusRow where
    toJSON row =
        Aeson.object
            [ "subscription" Aeson..= (row ^. #subscription)
            , "member" Aeson..= (row ^. #member)
            , "phase" Aeson..= (row ^. #phase)
            , "global_position" Aeson..= (row ^. #globalPosition)
            ]

instance Aeson.FromJSON SubscriptionStatusRow where
    parseJSON = Aeson.withObject "SubscriptionStatusRow" $ \o ->
        SubscriptionStatusRow
            <$> o Aeson..: "subscription"
            <*> o Aeson..: "member"
            <*> o Aeson..: "phase"
            <*> o Aeson..: "global_position"

subscriptionStatusRows :: Map (SubscriptionName, Int32) SubscriptionStateView -> [SubscriptionStatusRow]
subscriptionStatusRows =
    sortOn (\row -> (row ^. #subscription, row ^. #member))
        . fmap toRow
        . Map.elems
  where
    toRow view =
        let SubscriptionName name = subscriptionName view
            GlobalPosition position = cursor view
         in SubscriptionStatusRow
                { subscription = name
                , member = view ^. #member
                , phase = view ^. #statePhase
                , globalPosition = position
                }

renderSubscriptionStatusRows :: OutputFormat -> [SubscriptionStatusRow] -> Text
renderSubscriptionStatusRows OutputTable = renderTable
renderSubscriptionStatusRows OutputJson = renderJson

renderTable :: [SubscriptionStatusRow] -> Text
renderTable rows =
    T.unlines (header : fmap renderRow rows)
  where
    header =
        pad subWidth "SUBSCRIPTION"
            <> "  "
            <> pad memberWidth "MEMBER"
            <> "  "
            <> pad phaseWidth "PHASE"
            <> "  GLOBAL_POSITION"
    subWidth = columnWidth "SUBSCRIPTION" (fmap (^. #subscription) rows)
    memberWidth = columnWidth "MEMBER" (fmap (T.pack . show . (^. #member)) rows)
    phaseWidth = columnWidth "PHASE" (fmap (^. #phase) rows)
    renderRow row =
        pad subWidth (row ^. #subscription)
            <> "  "
            <> pad memberWidth (T.pack (show (row ^. #member)))
            <> "  "
            <> pad phaseWidth (row ^. #phase)
            <> "  "
            <> T.pack (show (row ^. #globalPosition))

columnWidth :: Text -> [Text] -> Int
columnWidth label values =
    maximum (T.length label : fmap T.length values)

pad :: Int -> Text -> Text
pad width value =
    value <> T.replicate (width - T.length value) " "

renderJson :: [SubscriptionStatusRow] -> Text
renderJson =
    TE.decodeUtf8
        . LBS.toStrict
        . Aeson.encode

{- | Fetch a running worker's @\/subscriptions@ endpoint and decode the rows.
GETs @\<base\>/subscriptions@ (trimming a trailing slash on the base), and on a
2xx response decodes @[SubscriptionStatusRow]@ via the shared 'Aeson.FromJSON'.
Non-2xx responses, connection failures, and decode errors are returned as a
readable 'Left' message rather than thrown.
-}
fetchRemoteSubscriptionStatusRows :: RemoteEndpoint -> IO (Either Text [SubscriptionStatusRow])
fetchRemoteSubscriptionStatusRows (RemoteEndpoint base) = do
    let url = T.unpack (T.dropWhileEnd (== '/') base) <> "/subscriptions"
    reqResult <- try (parseRequest url) :: IO (Either SomeException Request)
    case reqResult of
        Left err -> pure (Left ("kiroku: invalid --remote-url " <> T.pack url <> ": " <> T.pack (show err)))
        Right req -> do
            manager <- newManager tlsManagerSettings
            respResult <- try (httpLbs req manager) :: IO (Either SomeException (Response LBS.ByteString))
            pure $ case respResult of
                Left err -> Left ("kiroku: could not reach " <> T.pack url <> ": " <> T.pack (show err))
                Right resp -> decodeResponse url resp
  where
    decodeResponse :: String -> Response LBS.ByteString -> Either Text [SubscriptionStatusRow]
    decodeResponse url resp =
        let code = statusCode (responseStatus resp)
         in if code >= 200 && code < 300
                then case Aeson.eitherDecode (responseBody resp) of
                    Right rows -> Right rows
                    Left decodeErr ->
                        Left ("kiroku: could not decode response from " <> T.pack url <> ": " <> T.pack decodeErr)
                else
                    Left ("kiroku: " <> T.pack url <> " returned HTTP " <> T.pack (show code))

{- | Fetch and render a remote worker's subscription status, reusing the same
table/JSON renderer the in-process command uses. On error, returns the error text.
-}
renderRemoteSubscriptionStatus :: RemoteEndpoint -> OutputFormat -> IO Text
renderRemoteSubscriptionStatus ep format = do
    result <- fetchRemoteSubscriptionStatusRows ep
    pure $ case result of
        Left err -> err
        Right rows -> renderSubscriptionStatusRows format rows
