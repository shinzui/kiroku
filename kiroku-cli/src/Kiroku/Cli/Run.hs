module Kiroku.Cli.Run (
    runKirokuCommand,
    runKirokuCommandWithStore,
    renderKirokuCommandWithStore,
) where

import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Kiroku.Cli.Command (KirokuCommand (..), StatusOptions (..), SubscriptionCommand (..))
import Kiroku.Cli.Subscription.Status (
    renderRemoteSubscriptionStatus,
    renderSubscriptionStatusRows,
    subscriptionStatusRows,
 )
import Kiroku.Store (KirokuStore)
import Kiroku.Store.Subscription (subscriptionStates)

runKirokuCommand :: KirokuCommand -> IO ()
runKirokuCommand KirokuNoCommand =
    putStrLn "No Kiroku operator command was selected."
runKirokuCommand (KirokuSubscriptions _) =
    putStrLn "This command needs a live KirokuStore. Use runKirokuCommandWithStore from the embeddable library API."

runKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO ()
runKirokuCommandWithStore store command =
    renderKirokuCommandWithStore store command >>= TIO.putStrLn

renderKirokuCommandWithStore :: KirokuStore -> KirokuCommand -> IO Text
renderKirokuCommandWithStore _ KirokuNoCommand =
    pure "No Kiroku operator command was selected."
renderKirokuCommandWithStore store (KirokuSubscriptions (SubscriptionStatus (StatusOptions format endpoint))) =
    case endpoint of
        -- An optional remote override: a host can point the in-process command at
        -- a sibling worker over HTTP instead of reading its own registry.
        Just ep -> renderRemoteSubscriptionStatus ep format
        Nothing -> do
            snapshot <- subscriptionStates store
            pure (renderSubscriptionStatusRows format (subscriptionStatusRows snapshot))
