{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Exception (AsyncException (ThreadKilled, UserInterrupt), Exception, SomeAsyncException, SomeException, asyncExceptionFromException, fromException, throwIO, toException, try)
import Kiroku.Store.Observability (KirokuEvent (KirokuEventNotifierReconnected), emitOrDrop)

main :: IO ()
main = do
  print (asyncExceptionFromException (toException AsyncCancelled) :: Maybe SomeAsyncException)
  print (fromException (toException AsyncCancelled) :: Maybe SomeAsyncException)
  probe AsyncCancelled
  probe ThreadKilled
  probe UserInterrupt
  result <- try @SomeException (emitOrDrop (Just (const (fail "synchronous callback failure"))) KirokuEventNotifierReconnected)
  print result

probe :: (Exception failure) => failure -> IO ()
probe failure = do
  result <- try @SomeException (emitOrDrop (Just (const (throwIO failure))) KirokuEventNotifierReconnected)
  print result
