module Test.AsyncCancellation (spec, publisherSpec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (ThreadKilled, UserInterrupt), Exception (..), SomeException, asyncExceptionFromException, asyncExceptionToException, bracket, finally, throwIO, throwTo, try)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_, void)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Text (Text)
import Kiroku.Store
import Kiroku.Store.Notification qualified as N
import Kiroku.Store.Observability (emitOrDrop)
import Kiroku.Store.Subscription.EventPublisher qualified as P
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import System.Timeout (timeout)
import Test.Helpers (listenerCount, makeEvent, withTestStoreSettings)
import Test.Hspec

-- The payload ensures rethrowing preserves a consumer-defined exception too.
data PayloadCancellation = PayloadCancellation Int deriving stock (Eq, Show)

instance Exception PayloadCancellation where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

data SyncFailure = SyncFailure deriving stock (Eq, Show)

instance Exception SyncFailure

cases :: [(String, SomeException, SomeException -> Bool)]
cases =
  [ ("AsyncCancelled", toException Async.AsyncCancelled, matches Async.AsyncCancelled),
    ("ThreadKilled", toException ThreadKilled, matches ThreadKilled),
    ("UserInterrupt", toException UserInterrupt, matches UserInterrupt),
    ("custom payload", toException (PayloadCancellation 73), matches (PayloadCancellation 73))
  ]
  where
    matches :: (Exception e, Eq e) => e -> SomeException -> Bool
    matches expected e = fromException e == Just expected

bounded :: IO a -> IO a
bounded action = timeout 10_000_000 action >>= maybe (fail "asynchronous boundary timed out") pure

expectException :: (SomeException -> Bool) -> Either SomeException a -> Expectation
expectException matches = \case
  Left e -> e `shouldSatisfy` matches
  Right _ -> expectationFailure "expected asynchronous exception; action returned normally"

emit :: IO () -> IO ()
emit action = emitOrDrop (Just (const action)) KirokuEventNotifierReconnected

-- Release the blocked action before the scoped async finalizer on every exit.
-- This also makes the original, cancellation-swallowing implementation safe to test.
crossThread :: (IO () -> IO ()) -> (Async.Async () -> IO ()) -> (SomeException -> Bool) -> IO ()
crossThread boundary send matches = do
  entered <- newEmptyMVar
  release <- newEmptyMVar
  Async.withAsync (boundary (putMVar entered () >> takeMVar release)) $ \target ->
    ( do
        bounded (takeMVar entered)
        bounded (send target)
        bounded (Async.waitCatch target) >>= expectException matches
    )
      `finally` void (tryPutMVar release ())

awaitNoListeners :: Text -> Int64 -> IO ()
awaitNoListeners conn baseline = bounded loop
  where
    loop = do
      n <- listenerCount conn
      if n == baseline then pure () else threadDelay 1_000 >> loop

spec :: Spec
spec = describe "asynchronous cancellation" $ do
  it "allows absent and successful observation callbacks" $ do
    emitOrDrop Nothing KirokuEventNotifierReconnected
    called <- newIORef False
    emit (writeIORef called True)
    readIORef called `shouldReturn` True
  it "suppresses synchronous observation failures" $ emit (throwIO SyncFailure)
  forM_ cases $ \(label, exception, matches) -> do
    it ("preserves observation " <> label) $
      try (emit (throwIO exception)) >>= expectException matches
    it ("preserves notifier startup " <> label <> " and releases its connection") $
      withMigratedTestDatabase $ \conn -> do
        baseline <- listenerCount conn
        baseline `shouldBe` 0
        N.withListenHookForTest
          ( \_ -> do
              listenerCount conn `shouldReturn` (baseline + 1)
              throwIO exception
          )
          $ do
            result <- try (N.startNotifier conn "kiroku" Nothing)
            -- Even an incorrect successful startup must be cleaned up.
            either (const (pure ())) N.stopNotifier result
            expectException matches result
        awaitNoListeners conn baseline
  it "wraps synchronous notifier startup failure with its original cause and releases the connection" $
    withMigratedTestDatabase $ \conn -> do
      baseline <- listenerCount conn
      N.withListenHookForTest (\_ -> throwIO SyncFailure) $ do
        result <- try (N.startNotifier conn "kiroku" Nothing)
        either (const (pure ())) N.stopNotifier result
        case result of
          Left e
            | Just (N.NotifierListenError cause) <- fromException e ->
                fromException cause `shouldBe` Just SyncFailure
          _ -> expectationFailure "expected NotifierListenError with synchronous cause"
      awaitNoListeners conn baseline
  forM_ [False, True] $ \custom -> do
    let send target = if custom then throwTo (Async.asyncThreadId target) (PayloadCancellation 73) else Async.cancel target
        matches e = if custom then fromException e == Just (PayloadCancellation 73) else fromException e == Just Async.AsyncCancelled
    it ("terminates a blocked observation callback, custom=" <> show custom) $
      crossThread emit send matches
    it ("terminates blocked notifier startup and releases its connection, custom=" <> show custom) $
      withMigratedTestDatabase $ \conn -> do
        baseline <- listenerCount conn
        let boundary action =
              N.withListenHookForTest (\_ -> (listenerCount conn `shouldReturn` (baseline + 1)) >> action) $
                bracket (N.startNotifier conn "kiroku" Nothing) N.stopNotifier (const (pure ()))
        crossThread boundary send matches
        awaitNoListeners conn baseline

publisherSpec :: Spec
publisherSpec = describe "asynchronous publisher recovery" $ do
  forM_ [False, True] $ \callback -> do
    forM_ cases $ \(label, exception, matches) ->
      it ("preserves " <> label <> ", callback=" <> show callback) $
        publisherCase callback (throwIO exception) Nothing (pure ()) matches
    forM_ [False, True] $ \custom ->
      it ("terminates blocked action, callback=" <> show callback <> ", custom=" <> show custom) $ do
        entered <- newEmptyMVar
        release <- newEmptyMVar
        let action = putMVar entered () >> takeMVar release
            send target = do
              bounded (takeMVar entered)
              bounded (if custom then throwTo (Async.asyncThreadId target) (PayloadCancellation 73) else Async.cancel target)
            matches e = if custom then fromException e == Just (PayloadCancellation 73) else fromException e == Just Async.AsyncCancelled
        publisherCase callback action (Just send) (void (tryPutMVar release ())) matches

publisherCase :: Bool -> IO () -> Maybe (Async.Async () -> IO ()) -> IO () -> (SomeException -> Bool) -> IO ()
publisherCase callback action sender cleanup matches = do
  loopError <- newEmptyMVar
  let hook event =
        if callback
          then pure (Left (DecodeFailure (event ^. #eventId) "injected decode failure"))
          else action >> pure (Right event)
      observe event = case event of
        KirokuEventPublisherDecodeFailed {} | callback -> action
        KirokuEventPublisherLoopError {} -> void (tryPutMVar loopError ())
        _ -> pure ()
      tweak settings = settings & #storeSettings .~ defaultStoreSettings {decodeHook = Just hook} & #eventHandler .~ Just observe
  withTestStoreSettings tweak $ \store -> do
    let pub = store ^. #publisher
        target = P.publisherThread pub
    ( bracket (atomically (P.subscribePublisher pub 1 PauseAndResume)) (\(_, _, unsubscribe) -> unsubscribe) $ \_ -> do
        Right _ <- runStoreIO store $ appendToStream (StreamName "async-boundary") NoStream [makeEvent "Cancel" (Aeson.object [])]
        forM_ sender ($ target)
        outcome <- bounded $ Async.race (takeMVar loopError) (Async.waitCatch target)
        case outcome of
          Left () -> expectationFailure "asynchronous exception became a publisher loop error"
          Right result -> expectException matches result
        tryReadMVar loopError `shouldReturn` Nothing
        atomically (P.publisherPosition pub) `shouldReturn` GlobalPosition 0
      )
      `finally` cleanup
