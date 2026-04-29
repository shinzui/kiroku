{- | Failure-injection tests for kiroku-store.

Each test deliberately disrupts a runtime dependency (the LISTEN
connection, the connection pool) and asserts the system recovers per its
documented contract.

Currently covers:

  * F14: Listener killed during a window where an event is appended.
    The event is still delivered after the listener reconnects, because
    the publisher re-queries the database from its last position when
    the next NOTIFY arrives — no safety-poll wait needed.

F15 (pool exhaustion → 'PoolAcquisitionTimeout') is deferred until the
'acquisitionTimeout' field is exposed in 'ConnectionSettings'. The
mapping itself ('Kiroku.Store.Error.mapUsageError'
@AcquisitionTimeoutUsageError -> PoolAcquisitionTimeout@) is
straightforward; without a way to set a sub-second acquisition timeout
from the test, the test would either hang (default unbounded timeout)
or require modifying the production type. See the EP-6 plan's M2 notes.
-}
module Test.FailureInjection (spec) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, retry, writeTVar)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Kiroku.Store
import Test.Helpers (
    makeEvent,
    terminateBackend,
    waitForListenerPid,
    waitForListenerPidNotEqual,
    waitWithTimeout,
    withTestStoreSettings,
 )
import Test.Hspec

spec :: Spec
spec = describe "kiroku-store failure injection" $ do
    -- F14 — Listener killed during a window where an event is
    -- appended. The publisher's broadcast loop pulls events directly
    -- from PostgreSQL when the next NOTIFY arrives, so the
    -- down-window event is delivered as soon as a post-reconnect
    -- event triggers a tick. No 30-second safety-poll wait required.
    it "delivers events appended during listener-down window after reconnect (F14)" $ \() -> do
        ref <- newIORef ([] :: [RecordedEvent])
        countVar <- newTVarIO (0 :: Int)
        let handler' evt = do
                modifyIORef' ref (evt :)
                n <- atomically $ do
                    c <- readTVar countVar
                    let c' = c + 1
                    writeTVar countVar c'
                    pure c'
                if n >= 3 then pure Stop else pure Continue
        let cfg =
                SubscriptionConfig
                    { name = SubscriptionName "f14-down-window"
                    , target = AllStreams
                    , handler = handler'
                    , batchSize = 100
                    , queueCapacity = 16
                    , overflowPolicy = DropSubscription
                    }
        withTestStoreSettings (& #eventHandler .~ Nothing) $ \store -> do
            handle <- subscribe store cfg
            -- Pre-event: confirm the subscription is alive and the
            -- listener has reached pg_stat_activity.
            Right _ <- runStoreIO store $ appendToStream (StreamName "f14-pre") NoStream [makeEvent "Pre" (Aeson.object [])]
            atomically $ do
                c <- readTVar countVar
                if c >= 1 then pure () else retry
            -- Find listener pid, terminate it. The listener loop
            -- will reconnect with a fresh pid.
            pid1 <- waitForListenerPid (store ^. #pool) 5_000_000
            terminateBackend (store ^. #pool) pid1
            -- Append the during-down-window event. No NOTIFY reaches
            -- the publisher right now because the listener is
            -- disconnected.
            Right _ <- runStoreIO store $ appendToStream (StreamName "f14-during") NoStream [makeEvent "During" (Aeson.object [])]
            -- Wait for the listener to come back with a fresh pid.
            _ <- waitForListenerPidNotEqual (store ^. #pool) pid1 15_000_000
            -- Append the post-reconnect event. The new NOTIFY
            -- triggers the publisher to fetch from its last position
            -- — which picks up both the during-down event AND this
            -- one.
            Right _ <- runStoreIO store $ appendToStream (StreamName "f14-after") NoStream [makeEvent "After" (Aeson.object [])]
            result <- waitWithTimeout 30_000_000 handle
            case result of
                Left timeout -> expectationFailure timeout
                Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                Right (Right ()) -> pure ()
            collected <- readIORef ref
            length collected `shouldBe` 3
