module Codd.Extras.Settings (
    forceSingleTryPolicy,
    noCheckCoddSettings,
    parseConnString,
    warnRetryPolicyOverride,
)
where

import Codd (CoddSettings (..))
import Codd.Parsing (connStringParser)
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Control.Monad (when)
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Text (Text)

noCheckCoddSettings :: [Text] -> Text -> CoddSettings
noCheckCoddSettings schemas connStr =
    CoddSettings
        { migsConnString = parseConnString connStr
        , sqlMigrations = []
        , onDiskReps = Left ""
        , namespacesToCheck = IncludeSchemas (map SqlSchema schemas)
        , extraRolesToCheck = []
        , retryPolicy = singleTryPolicy
        , txnIsolationLvl = DbDefault
        , schemaAlgoOpts = SchemaAlgo False False False
        }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
    case parseOnly (connStringParser <* endOfInput) connStr of
        Left err -> error ("Could not parse PostgreSQL connection string for codd: " <> err)
        Right parsed -> parsed

forceSingleTryPolicy :: CoddSettings -> CoddSettings
forceSingleTryPolicy settings =
    -- codd retries re-read migration streams, but embedded in-memory streams fail.
    settings{retryPolicy = singleTryPolicy}

warnRetryPolicyOverride :: CoddSettings -> IO ()
warnRetryPolicyOverride settings =
    when (retryPolicy settings /= singleTryPolicy) $
        putStrLn "Ignoring CODD_RETRY_POLICY for embedded migrations; codd cannot retry in-memory migration streams."
