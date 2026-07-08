module Codd.Extras.ExpectedSchema (
    withMaterializedExpectedSchema,
)
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)

withMaterializedExpectedSchema :: String -> [(FilePath, ByteString)] -> (FilePath -> IO a) -> IO a
withMaterializedExpectedSchema label files action =
    withSystemTempDirectory label $ \dir -> do
        traverse_ (writeEmbeddedFile dir) files
        action dir

writeEmbeddedFile :: FilePath -> (FilePath, ByteString) -> IO ()
writeEmbeddedFile dir (path, bytes) = do
    let target = dir </> path
    createDirectoryIfMissing True (takeDirectory target)
    BS.writeFile target bytes
