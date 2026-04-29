module Kiroku.Store.Notification (
    Notifier (..),
    startNotifier,
    stopNotifier,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TChan, TVar, atomically, newBroadcastTChanIO, newTVarIO, readTVarIO, writeTChan, writeTVar)
import Control.Exception (SomeException, asyncExceptionFromException, bracketOnError, catch)
import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import Hasql.Connection (Connection)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Conn
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Notifications (PgIdentifier, toPgIdentifier, waitForNotifications)
import Hasql.Notifications qualified as Notifications
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, unpreparable)

{- | A Notifier manages a dedicated PostgreSQL connection for LISTEN/NOTIFY.
It writes a @()@ tick to a broadcast 'TChan' on every notification,
allowing subscribers to wake without polling.

The current connection is held in a 'TVar' so that
'Kiroku.Store.Notification.stopNotifier' releases whichever connection
the listener loop most recently acquired (rather than the original one,
which may have been replaced by reconnection).
-}
data Notifier = Notifier
    { tickChan :: !(TChan ())
    -- ^ Broadcast channel; consumers must use 'dupTChan' to get a personal copy
    , listenerThread :: !(Async ())
    -- ^ The async thread running the LISTEN loop
    , listenerConnRef :: !(TVar Connection)
    {- ^ The /current/ dedicated listener connection. Updated by the loop on
    each successful reconnection so 'stopNotifier' always releases the
    live socket.
    -}
    }

{- | Start a Notifier. Acquires a dedicated connection, sets
@application_name@ to @kiroku-listener@ for operator visibility, issues
LISTEN on the @\<schema\>.events@ channel, and spawns a thread that
writes @()@ to the broadcast TChan on every notification.

On connection failure during the loop, releases the dead connection,
waits 1 second, acquires a replacement, re-LISTENs, and resumes. The
replacement is published into 'listenerConnRef' so 'stopNotifier'
releases it on shutdown.

On 'Async.AsyncCancelled' (from cancellation), exits cleanly.
-}
startNotifier :: (MonadIO m) => Text -> Text -> m Notifier
startNotifier connString schema = liftIO $ do
    chan <- newBroadcastTChanIO
    conn <- acquireOrFail connString
    let channel = toPgIdentifier (schema <> ".events")
    Notifications.listen conn channel
    connRef <- newTVarIO conn
    thread <- Async.async (listenerLoop chan connRef channel connString)
    pure
        Notifier
            { tickChan = chan
            , listenerThread = thread
            , listenerConnRef = connRef
            }

{- | Stop the Notifier. Cancels the listener thread, waits for it to
finish, and releases whichever connection the loop is currently holding.
-}
stopNotifier :: (MonadIO m) => Notifier -> m ()
stopNotifier notifier = liftIO $ do
    Async.cancel (listenerThread notifier)
    void $ Async.waitCatch (listenerThread notifier)
    conn <- readTVarIO (listenerConnRef notifier)
    Connection.release conn

-- Internal: the listener loop. Calls 'waitForNotifications' on the current
-- connection; that call blocks indefinitely under normal operation. If it
-- returns (because the underlying 'Hasql.Connection.use' swallowed a session
-- error and produced a 'Left') or throws (because the panic propagated),
-- the loop releases the dead connection and reconnects. On async exceptions
-- it exits without releasing — 'stopNotifier' owns the final release via
-- 'listenerConnRef'.
listenerLoop :: TChan () -> TVar Connection -> PgIdentifier -> Text -> IO ()
listenerLoop chan connRef channel connStr = go
  where
    go =
        ( do
            currentConn <- readTVarIO connRef
            waitForNotifications (\_ _ -> atomically (writeTChan chan ())) currentConn
            -- waitForNotifications returns only if the underlying connection
            -- went bad and Hasql converted the error into a Left result; in
            -- that case we must reconnect rather than spin re-invoking the
            -- same dead conn.
            reconnect
        )
            `catch` \(e :: SomeException) ->
                case asyncExceptionFromException e of
                    Just (_ :: Async.AsyncCancelled) -> pure ()
                    Nothing -> reconnect

    reconnect = do
        oldConn <- readTVarIO connRef
        Connection.release oldConn
        threadDelay 1_000_000
        -- bracketOnError releases the freshly acquired connection if an
        -- async exception lands between acquire and the TVar write — without
        -- it the new connection would be unreachable from stopNotifier and
        -- would leak.
        bracketOnError
            (acquireOrFail connStr)
            Connection.release
            $ \newConn -> do
                Notifications.listen newConn channel
                atomically (writeTVar connRef newConn)
        go

-- Internal: acquire a connection, set its application_name, or throw on failure.
acquireOrFail :: Text -> IO Connection
acquireOrFail connStr = do
    result <- Connection.acquire (Conn.connectionString connStr)
    case result of
        Left err -> fail ("Notifier: failed to acquire connection: " <> show err)
        Right conn -> do
            -- Tag the connection so operators can identify the listener in
            -- pg_stat_activity. Failures here are non-fatal — fall back to the
            -- default application_name silently rather than aborting startup.
            _ <- Connection.use conn (Session.statement () setAppNameStmt)
            pure conn

setAppNameStmt :: Statement () ()
setAppNameStmt =
    unpreparable "SET application_name = 'kiroku-listener'" E.noParams D.noResult
