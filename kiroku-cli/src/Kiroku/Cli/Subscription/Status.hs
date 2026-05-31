module Kiroku.Cli.Subscription.Status (
    SubscriptionStatusRow (..),
    renderSubscriptionStatusRows,
    subscriptionStatusRows,
) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int32, Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Kiroku.Cli.Command (OutputFormat (..))
import Kiroku.Store.Subscription (SubscriptionStateView (..))
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (GlobalPosition (..))

data SubscriptionStatusRow = SubscriptionStatusRow
    { rowSubscription :: !Text
    , rowMember :: !Int32
    , rowPhase :: !Text
    , rowGlobalPosition :: !Int64
    }
    deriving stock (Eq, Show)

subscriptionStatusRows :: Map (SubscriptionName, Int32) SubscriptionStateView -> [SubscriptionStatusRow]
subscriptionStatusRows =
    sortOn (\row -> (rowSubscription row, rowMember row))
        . fmap toRow
        . Map.elems
  where
    toRow view =
        let SubscriptionName name = subscriptionName view
            GlobalPosition position = cursor view
         in SubscriptionStatusRow
                { rowSubscription = name
                , rowMember = member view
                , rowPhase = statePhase view
                , rowGlobalPosition = position
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
    subWidth = columnWidth "SUBSCRIPTION" (fmap rowSubscription rows)
    memberWidth = columnWidth "MEMBER" (fmap (T.pack . show . rowMember) rows)
    phaseWidth = columnWidth "PHASE" (fmap rowPhase rows)
    renderRow row =
        pad subWidth (rowSubscription row)
            <> "  "
            <> pad memberWidth (T.pack (show (rowMember row)))
            <> "  "
            <> pad phaseWidth (rowPhase row)
            <> "  "
            <> T.pack (show (rowGlobalPosition row))

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
            [ "subscription" Aeson..= rowSubscription row
            , "member" Aeson..= rowMember row
            , "phase" Aeson..= rowPhase row
            , "global_position" Aeson..= rowGlobalPosition row
            ]
