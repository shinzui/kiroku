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
import GHC.Generics (Generic)
import Hasql.Connection.Settings qualified as Conn
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config

-- | Connection settings for the store.
data ConnectionSettings = ConnectionSettings
    { connString :: !Text
    -- ^ PostgreSQL connection string (libpq URI or key=value format)
    , poolSize :: !Int
    -- ^ Connection pool size (default: 10)
    , schema :: !Text
    -- ^ Schema name for multi-tenant isolation (default: "public")
    }
    deriving stock (Show, Generic)

-- | Default connection settings.
defaultConnectionSettings :: Text -> ConnectionSettings
defaultConnectionSettings cs =
    ConnectionSettings
        { connString = cs
        , poolSize = 10
        , schema = "public"
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
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString (settings ^. #connString))
            , Pool.Config.size (settings ^. #poolSize)
            ]

    acquire = do
        p <- Pool.acquire poolConfig
        pure
            KirokuStore
                { pool = p
                , schema = settings ^. #schema
                }

    release store =
        Pool.release (store ^. #pool)
