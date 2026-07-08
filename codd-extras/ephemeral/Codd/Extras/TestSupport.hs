module Codd.Extras.TestSupport (
    withMigratedDatabase,
)
where

import Control.Exception (finally)
import Data.Text (Text)
import EphemeralPg qualified as Pg

withMigratedDatabase ::
    (Text -> IO ()) ->
    (Text -> IO a) ->
    IO a
withMigratedDatabase apply use = do
    started <- Pg.startCached Pg.defaultConfig Pg.defaultCacheConfig
    case started of
        Left err -> fail ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right db ->
            ( do
                let connStr = Pg.connectionString db
                apply connStr
                use connStr
            )
                `finally` Pg.stop db
