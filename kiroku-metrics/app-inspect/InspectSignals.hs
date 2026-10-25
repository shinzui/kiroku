-- | Shared only by the executable and its subprocess test fixture.
module InspectSignals (withInspectSignals) where

import Control.Exception (bracket)
import Control.Monad (void)
import Data.IORef (atomicModifyIORef', newIORef)
import System.Exit (ExitCode (..))
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (Handler (..), installHandler, sigINT, sigTERM)

-- | The shutdown state persists even after the caller consumes its notification.
-- Nested brackets also restore SIGINT if installing SIGTERM fails.
withInspectSignals :: IO () -> IO a -> IO a
withInspectSignals requestShutdown action = do
  requested <- newIORef False
  let handler = Catch $ do
        alreadyRequested <- atomicModifyIORef' requested (\previous -> (True, previous))
        if alreadyRequested then exitImmediately (ExitFailure 130) else requestShutdown
      withHandler signal = bracket (installHandler signal handler Nothing) (\previous -> void (installHandler signal previous Nothing))
  withHandler sigINT $ \_ -> withHandler sigTERM $ \_ -> action
