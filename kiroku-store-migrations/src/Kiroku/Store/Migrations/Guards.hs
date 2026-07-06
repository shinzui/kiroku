module Kiroku.Store.Migrations.Guards (
    LintConfig (..),
    checksumViolations,
    duplicateTimestampViolations,
    handAssignedTimestamp,
    isTimestampShaped,
    lintViolations,
    parseChecksumManifest,
    renderChecksumManifest,
    sentinelViolations,
    sha256Hex,
    timestampFields,
    timestampWidth,
) where

import Crypto.Hash (Digest, SHA256 (..), hashWith)
import Data.ByteString (ByteString)
import Data.Char (isDigit)
import Data.Function (on)
import Data.List (group, groupBy, sort, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)

-- | Width of the @YYYY-MM-DD-HH-MM-SS@ timestamp prefix on a migration filename.
timestampWidth :: Int
timestampWidth = 19

{- | True when a filename's timestamp looks hand-assigned rather than sampled
from the wall clock: a malformed prefix, a @00@ seconds field, or exactly UTC
midnight (@HH-MM == 00-00@).
-}
handAssignedTimestamp :: FilePath -> Bool
handAssignedTimestamp name =
    case timestampFields name of
        Nothing -> True
        Just (hh, mm, ss) -> ss == "00" || (hh == "00" && mm == "00")

-- | Extract @(HH, MM, SS)@ from a well-formed @YYYY-MM-DD-HH-MM-SS-...@ filename.
timestampFields :: FilePath -> Maybe (String, String, String)
timestampFields name
    | isTimestampShaped stamp =
        Just (take 2 (drop 11 stamp), take 2 (drop 14 stamp), take 2 (drop 17 stamp))
    | otherwise = Nothing
  where
    stamp = take timestampWidth name

-- | Does the string match the fixed-width @dddd-dd-dd-dd-dd-dd@ shape?
isTimestampShaped :: String -> Bool
isTimestampShaped s =
    length s == timestampWidth && and (zipWith matches "dddd-dd-dd-dd-dd-dd" s)
  where
    matches 'd' c = isDigit c
    matches _ c = c == '-'

sentinelViolations :: [FilePath] -> [Text]
sentinelViolations files =
    [ "migration filename uses a hand-assigned sentinel timestamp: " <> T.pack file
    | file <- sort files
    , handAssignedTimestamp file
    ]

duplicateTimestampViolations :: [FilePath] -> [Text]
duplicateTimestampViolations files =
    [ "migration timestamp is duplicated by " <> T.intercalate ", " (map T.pack groupFiles)
    | groupFiles <- grouped
    , length groupFiles > 1
    ]
  where
    grouped =
        groupBy ((==) `on` take timestampWidth)
            . sortOn (take timestampWidth)
            $ sort files

data LintConfig = LintConfig
    { requiredQualifier :: Text
    , exemptFiles :: [FilePath]
    }
    deriving stock (Eq, Show)

{- | Lint migration bodies with intentionally simple SQL heuristics. The checks
operate on comment-stripped statements and are meant to catch future authoring
mistakes, not to parse every valid PostgreSQL construct.
-}
lintViolations :: LintConfig -> [(FilePath, ByteString)] -> [Text]
lintViolations config sources =
    concatMap lintOne (sortOn fst sources)
  where
    lintOne (file, bytes)
        | file `elem` exemptFiles config = []
        | otherwise =
            searchPathViolation file body
                <> concurrentlyViolation file body
                <> concatMap (statementViolations file) statements
      where
        body = TE.decodeUtf8With lenientDecode bytes
        statements = map T.strip . T.splitOn ";" $ stripCommentLines body

    requiredLower = T.toCaseFold (requiredQualifier config)

    searchPathViolation file body =
        [ "migration body mentions search_path: " <> T.pack file
        | "search_path" `T.isInfixOf` T.toCaseFold (stripCommentLines body)
        ]

    concurrentlyViolation file body =
        [ "migration uses CONCURRENTLY without -- codd: no-txn: " <> T.pack file
        | let lowered = T.toCaseFold body
        , "concurrently" `T.isInfixOf` lowered
        , not ("-- codd: no-txn" `T.isInfixOf` lowered)
        ]

    statementViolations file statement =
        case statementTarget statement of
            Nothing -> []
            Just target
                | requiredLower `T.isPrefixOf` T.toCaseFold (cleanTarget target) -> []
                | otherwise ->
                    [ "migration DDL target is not qualified with "
                        <> requiredQualifier config
                        <> " in "
                        <> T.pack file
                        <> ": "
                        <> T.take 120 (oneLine statement)
                    ]

statementTarget :: Text -> Maybe Text
statementTarget statement
    | T.null trimmed = Nothing
    | lower `startsWithWords` ["create", "table"] =
        targetAfter ["create", "table"] wordsOriginal
    | lower `startsWithWords` ["alter", "table"] =
        targetAfter ["alter", "table"] wordsOriginal
    | lower `startsWithWords` ["drop", "index"] =
        targetAfter ["drop", "index"] wordsOriginal
    | lower `startsWithWords` ["create", "index"] =
        targetAfterToken "on" wordsOriginal
    | lower `startsWithWords` ["create", "unique", "index"] =
        targetAfterToken "on" wordsOriginal
    | lower `startsWithWords` ["create", "function"] =
        targetAfter ["create", "function"] wordsOriginal
    | lower `startsWithWords` ["create", "or", "replace", "function"] =
        targetAfter ["create", "or", "replace", "function"] wordsOriginal
    | lower `startsWithWords` ["create", "trigger"] =
        targetAfterToken "on" wordsOriginal
    | otherwise = Nothing
  where
    trimmed = T.strip statement
    lower = T.toCaseFold trimmed
    wordsOriginal = T.words trimmed

startsWithWords :: Text -> [Text] -> Bool
startsWithWords statement wordsExpected =
    wordsExpected == take (length wordsExpected) (T.words statement)

targetAfter :: [Text] -> [Text] -> Maybe Text
targetAfter prefix wordsOriginal =
    skipIfNotExists (drop (length prefix) wordsOriginal)

targetAfterToken :: Text -> [Text] -> Maybe Text
targetAfterToken token wordsOriginal =
    skipIfNotExists . drop 1 $ dropWhile ((/= token) . T.toCaseFold) wordsOriginal

skipIfNotExists :: [Text] -> Maybe Text
skipIfNotExists (first : second : third : target : _)
    | map T.toCaseFold [first, second, third] == ["if", "not", "exists"] = Just target
skipIfNotExists (first : second : target : _)
    | map T.toCaseFold [first, second] == ["if", "exists"] = Just target
skipIfNotExists (target : _) = Just target
skipIfNotExists [] = Nothing

stripCommentLines :: Text -> Text
stripCommentLines =
    T.unlines . filter (not . T.isPrefixOf "--" . T.strip) . T.lines

cleanTarget :: Text -> Text
cleanTarget =
    T.dropAround (`elem` ("\"(),;" :: String))

oneLine :: Text -> Text
oneLine =
    T.unwords . T.words

renderChecksumManifest :: [(FilePath, ByteString)] -> Text
renderChecksumManifest sources =
    T.concat
        [ sha256Hex bytes <> "  " <> T.pack file <> "\n"
        | (file, bytes) <- sortOn fst sources
        ]

parseChecksumManifest :: Text -> Either Text [(FilePath, Text)]
parseChecksumManifest text =
    traverse parseLine (zip [(1 :: Int) ..] (T.lines text))
  where
    parseLine (lineNumber, line) =
        case T.breakOn "  " line of
            (hashText, rest)
                | T.length hashText == 64
                , T.all isHexText hashText
                , Just file <- T.stripPrefix "  " rest
                , not (T.null file) ->
                    Right (T.unpack file, hashText)
                | otherwise ->
                    Left ("invalid migrations.lock line " <> T.pack (show lineNumber) <> ": " <> line)

    isHexText c =
        ('0' <= c && c <= '9') || ('a' <= c && c <= 'f')

checksumViolations :: [(FilePath, Text)] -> [(FilePath, ByteString)] -> [Text]
checksumViolations manifest sources =
    duplicateManifestViolations
        <> missingViolations
        <> mismatchViolations
        <> extraViolations
  where
    manifestSorted = sortOn fst manifest
    sourceSorted = sortOn fst sources
    manifestNames = map fst manifestSorted
    sourceNames = map fst sourceSorted

    duplicateManifestViolations =
        [ "migrations.lock contains duplicate entries for " <> T.pack file
        | names@(file : _) <- group (sort manifestNames)
        , length names > 1
        ]

    missingViolations =
        [ "migrations.lock is missing " <> T.pack file
        | file <- sourceNames
        , file `notElem` manifestNames
        ]

    mismatchViolations =
        [ "migrations.lock checksum mismatch for " <> T.pack file
        | (file, bytes) <- sourceSorted
        , Just expected <- [lookup file manifestSorted]
        , sha256Hex bytes /= expected
        ]

    extraViolations =
        [ "migrations.lock contains extra entry " <> T.pack file
        | file <- manifestNames
        , file `notElem` sourceNames
        ]

sha256Hex :: ByteString -> Text
sha256Hex bytes =
    T.pack (show (hashWith SHA256 bytes :: Digest SHA256))
