module Kiroku.Cli.Subscription.Status (
    SubscriptionStatusRow (..),
    renderSubscriptionStatusRows,
    subscriptionStatusRows,
) where

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
import Kiroku.Cli.Command (OutputFormat (..))
import Kiroku.Store.Subscription (SubscriptionStateView (..))
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (GlobalPosition (..))

data SubscriptionStatusRow = SubscriptionStatusRow
    { subscription :: !Text
    , member :: !Int32
    , phase :: !Text
    , globalPosition :: !Int64
    }
    deriving stock (Generic, Eq, Show)

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
        . fmap rowJson
  where
    rowJson row =
        Aeson.object
            [ "subscription" Aeson..= (row ^. #subscription)
            , "member" Aeson..= (row ^. #member)
            , "phase" Aeson..= (row ^. #phase)
            , "global_position" Aeson..= (row ^. #globalPosition)
            ]
