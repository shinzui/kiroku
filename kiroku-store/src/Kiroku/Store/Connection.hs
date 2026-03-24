module Kiroku.Store.Connection (
    KirokuStore (..),
    ConnectionSettings (..),
    defaultConnectionSettings,
    withStore,
) where

import Control.Exception (bracket)
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Hasql.Connection.Settings qualified as Conn
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Pool.Observation (Observation)
import Hasql.Session qualified as Session
import Kiroku.Store.Schema (initializeSchema)

-- | Connection settings for the store.
data ConnectionSettings = ConnectionSettings
    { connString :: !Text
    -- ^ PostgreSQL connection string (libpq URI or key=value format)
    , poolSize :: !Int
    -- ^ Connection pool size (default: 10)
    , schema :: !Text
    -- ^ Schema name for multi-tenant isolation (default: "public")
    , idleInTransactionTimeout :: !Int
    -- ^ idle_in_transaction_session_timeout in seconds (default: 30)
    , observationHandler :: !(Maybe (Observation -> IO ()))
    -- ^ Optional callback for pool connection lifecycle events
    }
    deriving stock (Generic)

-- | Default connection settings.
defaultConnectionSettings :: Text -> ConnectionSettings
defaultConnectionSettings cs =
    ConnectionSettings
        { connString = cs
        , poolSize = 10
        , schema = "public"
        , idleInTransactionTimeout = 30
        , observationHandler = Nothing
        }

-- | The store handle. Holds a connection pool and schema name.
data KirokuStore = KirokuStore
    { pool :: !Pool
    , schema :: !Text
    }
    deriving stock (Generic)

-- | Bracket-style store lifecycle.
withStore :: ConnectionSettings -> (KirokuStore -> IO a) -> IO a
withStore settings = bracket acquire release
  where
    poolConfig :: Pool.Config.Config
    poolConfig =
        Pool.Config.settings $
            [ Pool.Config.staticConnectionSettings (Conn.connectionString (settings ^. #connString))
            , Pool.Config.size (settings ^. #poolSize)
            , Pool.Config.initSession $
                Session.script ("SET idle_in_transaction_session_timeout = '" <> T.pack (show (settings ^. #idleInTransactionTimeout)) <> "s'")
            ]
                ++ maybe [] (\h -> [Pool.Config.observationHandler h]) (settings ^. #observationHandler)

    acquire = do
        p <- Pool.acquire poolConfig
        let s = settings ^. #schema
        initializeSchema p s
        pure
            KirokuStore
                { pool = p
                , schema = s
                }

    release store =
        Pool.release (store ^. #pool)
