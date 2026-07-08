module Codd.Extras.Lock (
    migrationAdvisoryLockKey,
    withMigrationLock,
)
where

import Codd.Types (ConnectionString, libpqConnString)
import Control.Exception (bracket)
import Data.Int (Int64)
import Data.Time (DiffTime)
import Database.PostgreSQL.Simple qualified as DB

migrationAdvisoryLockKey :: Int64
migrationAdvisoryLockKey = 0x6B69726F6B754D67

withMigrationLock :: ConnectionString -> DiffTime -> IO a -> IO a
withMigrationLock connString _connectTimeout action =
    bracket acquire DB.close (const action)
  where
    acquire = do
        conn <- DB.connectPostgreSQL (libpqConnString connString)
        _ <- DB.query conn "SELECT pg_advisory_lock(?)" (DB.Only migrationAdvisoryLockKey) :: IO [DB.Only ()]
        pure conn
