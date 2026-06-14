module Test.NotifyGuard (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar)
import Control.Exception (bracket, throwIO)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Conn
import Hasql.Notifications qualified as Notifications
import Kiroku.Store
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import System.IO.Error (userError)
import Test.Helpers (makeEvent)
import Test.Hspec

spec :: Spec
spec =
    describe "NOTIFY trigger guard" $
        around withNotifyStore $
            it "emits one unchanged append payload and no lifecycle or $all payloads" $ \(store, listenerConn) -> do
                payloads <- newTVarIO []

                Notifications.listen listenerConn (Notifications.toPgIdentifier "kiroku.events")
                Async.withAsync
                    (Notifications.waitForNotifications (\_ payload -> atomically (modifyTVar' payloads (<> [payload]))) listenerConn)
                    $ \_listener -> do
                        let firstStream = StreamName "notify-guard-1"
                            secondStream = StreamName "notify-guard-2"

                        Right first <-
                            runStoreIO store $
                                appendToStream firstStream NoStream [makeEvent "NotifyGuardFirst" (Aeson.object [])]
                        waitForPayload payloads (expectedPayload firstStream first)

                        Right _ <- runStoreIO store $ softDeleteStream firstStream
                        Right _ <- runStoreIO store $ undeleteStream firstStream

                        Right second <-
                            runStoreIO store $
                                appendToStream secondStream NoStream [makeEvent "NotifyGuardSecond" (Aeson.object [])]
                        waitForPayload payloads (expectedPayload secondStream second)

                        actual <- atomically (readTVar payloads)
                        actual
                            `shouldBe` [ expectedPayload firstStream first
                                       , expectedPayload secondStream second
                                       ]
                        map payloadFieldCount actual `shouldBe` [3, 3]
                        actual `shouldSatisfy` all (not . BS.isPrefixOf "$all,")

withNotifyStore :: ((KirokuStore, Connection.Connection) -> IO ()) -> IO ()
withNotifyStore action =
    withMigratedTestDatabase $ \connStr ->
        withStore (defaultConnectionSettings connStr) $ \store ->
            withConnection connStr $ \listenerConn ->
                action (store, listenerConn)

withConnection :: T.Text -> (Connection.Connection -> IO a) -> IO a
withConnection connStr =
    bracket acquire Connection.release
  where
    acquire = do
        result <- Connection.acquire (Conn.connectionString connStr)
        case result of
            Left err -> throwIO (userError ("failed to acquire LISTEN connection: " <> show err))
            Right conn -> pure conn

expectedPayload :: StreamName -> AppendResult -> ByteString
expectedPayload (StreamName name) result =
    let StreamId sid = result ^. #streamId
        StreamVersion version = result ^. #streamVersion
     in T.encodeUtf8 $
            T.intercalate
                ","
                [ name
                , T.pack (show sid)
                , T.pack (show version)
                ]

payloadFieldCount :: ByteString -> Int
payloadFieldCount = length . BS.split 44

waitForPayload :: TVar [ByteString] -> ByteString -> IO ()
waitForPayload payloads expected = do
    result <-
        Async.race
            (threadDelay 5_000_000)
            ( atomically $ do
                seen <- readTVar payloads
                check (expected `elem` seen)
            )
    case result of
        Left () -> do
            seen <- atomically (readTVar payloads)
            expectationFailure ("timed out waiting for notification " <> show expected <> "; saw " <> show seen)
        Right () -> pure ()
