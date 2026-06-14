{- | The @GET /subscriptions@ HTTP endpoint (EP-5 / IP-5).

Serves a worker's __live subscription registry__ as JSON — each running
subscription's name, consumer-group member, current FSM phase, and current global
cursor. The data comes from a caller-supplied 'SubscriptionStatusProvider' closure
(the server stays store-agnostic, exactly as EP-2 keeps 'KirokuStore' out of its
signature). The canonical provider, 'storeSubscriptionStatus', reads the live
registry through the public 'Kiroku.Store.Subscription.subscriptionStates'.

The wire shape is the CLI's 'SubscriptionStatusRow' JSON (a JSON array of
@{subscription, member, phase, global_position}@), reused via a @build-depends@ on
@kiroku-cli@ so the server encoder and the CLI remote-client decoder share one
codec — the IP-5 contract.
-}
module Kiroku.Metrics.Subscriptions (
    SubscriptionStatusProvider,
    storeSubscriptionStatus,
    subscriptionsApp,
) where

import Data.Aeson (encode, object, (.=))
import Data.Text (Text)
import Network.HTTP.Types (status200, status404)
import Network.Wai (Application, pathInfo)

import Kiroku.Cli.Subscription.Status (SubscriptionStatusRow (..), subscriptionStatusRows)
import Kiroku.Metrics.JSON (jsonResponse)
import Kiroku.Store (KirokuStore)
import Kiroku.Store.Subscription (subscriptionStates)

{- | A closure the caller supplies; it reads the live subscription registry on
demand and returns the rows to serve.
-}
type SubscriptionStatusProvider = IO [SubscriptionStatusRow]

{- | The canonical provider, built by a caller who owns the 'KirokuStore':
reads the live registry through 'subscriptionStates' and maps it to rows.
-}
storeSubscriptionStatus :: KirokuStore -> SubscriptionStatusProvider
storeSubscriptionStatus store = subscriptionStatusRows <$> subscriptionStates store

{- | WAI app for the subscription-status endpoint. Routes:

  * @GET /subscriptions@ — 200, JSON array of all rows.
  * @GET /subscriptions/\<name\>@ — 200, JSON array of rows for that name
    (possibly empty).

Any other path returns a 404 with body @{"error":"Not found"}@. This app is mounted by
'Kiroku.Metrics.Server.httpApp' only when a provider is configured.
-}
subscriptionsApp :: SubscriptionStatusProvider -> Application
subscriptionsApp provider req respond =
    case pathInfo req of
        ["subscriptions"] -> do
            rows <- provider
            respond (jsonResponse status200 (encode rows))
        ["subscriptions", name] -> do
            rows <- provider
            let filtered = filter (\row -> row.subscription == name) rows
            respond (jsonResponse status200 (encode filtered))
        _ -> respond (jsonResponse status404 (encode (object ["error" .= ("Not found" :: Text)])))
