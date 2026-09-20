module Shibuya.Adapter.Kiroku.Internal (
    acquireAllAndTransfer,
) where

import Control.Exception (SomeException)
import Data.Int (Int32)
import Effectful (Eff, IOE, (:>))
import Effectful.Exception qualified as Exception

{- | Acquire a fixed set of resources and atomically transfer their ownership.

The acquisition itself is restored to the caller's masking state because it may
perform interruptible startup work. As soon as an acquisition returns, the new
resource is added to the masked ownership ledger before the next interruptible
operation can run. If acquisition or transfer fails, every owned resource is
given one release attempt in reverse acquisition order and the original
exception is rethrown even when a release also fails.

The post-acquire hook runs while the new resource is already in the ledger. It
exists so tests can stop at the exact cancellation boundary without adding a
hook to the public adapter API; production callers pass a no-op.
-}
acquireAllAndTransfer ::
    (IOE :> es) =>
    Int32 ->
    (Int32 -> Eff es resource) ->
    (resource -> Eff es ()) ->
    (Int32 -> resource -> Eff es ()) ->
    ([resource] -> Eff es result) ->
    Eff es result
acquireAllAndTransfer count acquire release afterAcquire transfer =
    Exception.mask $ \restore -> go restore [] 0
  where
    go restore owned member
        | member >= count = do
            outcome <- tryAny (transfer (reverse owned))
            either (`cleanupAndRethrow` owned) pure outcome
        | otherwise = do
            acquisition <- tryAny (restore (acquire member))
            case acquisition of
                Left primary -> cleanupAndRethrow primary owned
                Right resource -> do
                    let owned' = resource : owned
                    handoff <- tryAny (afterAcquire member resource)
                    case handoff of
                        Left primary -> cleanupAndRethrow primary owned'
                        Right () -> go restore owned' (member + 1)

    cleanupAndRethrow primary owned = do
        mapM_ releaseIgnoringFailure owned
        Exception.throwIO primary

    releaseIgnoringFailure resource = do
        _ <- tryAny (release resource)
        pure ()

tryAny :: Eff es a -> Eff es (Either SomeException a)
tryAny = Exception.try
