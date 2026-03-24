module Kiroku.Store.Notification (
    Notifier (..),
    startNotifier,
    stopNotifier,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TChan, atomically, newBroadcastTChanIO, writeTChan)
import Control.Exception (SomeException, asyncExceptionFromException, catch)
import Control.Monad (forever, void)
import Data.Text (Text)
import Hasql.Connection (Connection)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Conn
import Hasql.Notifications (toPgIdentifier, waitForNotifications)
import Hasql.Notifications qualified as Notifications

{- | A Notifier manages a dedicated PostgreSQL connection for LISTEN/NOTIFY.
It writes a @()@ tick to a broadcast 'TChan' on every notification,
allowing subscribers to wake without polling.
-}
data Notifier = Notifier
    { tickChan :: !(TChan ())
    -- ^ Broadcast channel; consumers must use 'dupTChan' to get a personal copy
    , listenerThread :: !(Async ())
    -- ^ The async thread running the LISTEN loop
    , listenerConn :: !Connection
    -- ^ Dedicated connection held for the store's lifetime
    }

{- | Start a Notifier. Acquires a dedicated connection, issues LISTEN on
the @\<schema\>.events@ channel, and spawns a thread that writes @()@
to the broadcast TChan on every notification.

On connection failure during the loop, waits 1 second and retries.
On 'AsyncException' (from cancellation), exits cleanly.
-}
startNotifier :: Text -> Text -> IO Notifier
startNotifier connString schema = do
    chan <- newBroadcastTChanIO
    conn <- acquireOrFail connString
    let channel = toPgIdentifier (schema <> ".events")
    Notifications.listen conn channel
    thread <- Async.async (listenerLoop chan conn channel connString)
    pure
        Notifier
            { tickChan = chan
            , listenerThread = thread
            , listenerConn = conn
            }

{- | Stop the Notifier. Cancels the listener thread and releases the
dedicated connection.
-}
stopNotifier :: Notifier -> IO ()
stopNotifier notifier = do
    Async.cancel (listenerThread notifier)
    void $ Async.waitCatch (listenerThread notifier)
    Connection.release (listenerConn notifier)

-- Internal: the listener loop. Runs forever, writing ticks on each notification.
-- On connection errors, reconnects after 1 second. On async exceptions, exits.
listenerLoop :: TChan () -> Connection -> Notifications.PgIdentifier -> Text -> IO ()
listenerLoop chan conn channel connStr = go conn
  where
    go currentConn =
        (forever $ waitForNotifications (\_ _ -> atomically (writeTChan chan ())) currentConn)
            `catch` \(e :: SomeException) ->
                case asyncExceptionFromException e of
                    Just (_ :: Async.AsyncCancelled) -> pure ()
                    Nothing -> do
                        -- Connection error: wait, reconnect, re-listen, retry
                        threadDelay 1_000_000
                        newConn <- acquireOrFail connStr
                        Notifications.listen newConn channel
                        go newConn

-- Internal: acquire a connection or throw on failure.
acquireOrFail :: Text -> IO Connection
acquireOrFail connStr = do
    result <- Connection.acquire (Conn.connectionString connStr)
    case result of
        Left err -> fail ("Notifier: failed to acquire connection: " <> show err)
        Right conn -> pure conn
