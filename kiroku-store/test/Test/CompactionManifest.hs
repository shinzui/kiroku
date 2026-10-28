{-# LANGUAGE OverloadedRecordDot #-}

module Test.CompactionManifest (spec) where

import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Hedgehog hiding (property)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Kiroku.Store.Compaction.Types
import Kiroku.Store.HistoryRetention.Types (HistoryRetentionConflict (..))
import Kiroku.Store.Types (EventId (..), GlobalPosition (..), StoreIdentity (..), StreamName (..), StreamVersion (..))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog, modifyMaxSuccess)

spec :: Spec
spec = describe "compaction manifest" $ do
  describe "validation" $ do
    it "rejects empty and oversized selections" $ do
      mkCompactionManifest (base & #selections .~ []) `shouldBe` Left CompactionManifestEmpty
      mkCompactionManifest (base & #selections .~ replicate (maxCompactionSelections + 1) selection)
        `shouldBe` Left (CompactionManifestTooLarge (maxCompactionSelections + 1))
    it "rejects duplicate event IDs before duplicate positions" $
      mkCompactionManifest (base & #selections .~ [selection, selection]) `shouldBe` Left (CompactionManifestDuplicateEvent selection.eventId)
    it "rejects duplicate global positions" $
      mkCompactionManifest (base & #selections .~ [selection, selection & #eventId .~ eid 2 & #originVersion .~ StreamVersion 4])
        `shouldBe` Left (CompactionManifestDuplicatePosition (GlobalPosition 42))
    it "rejects duplicate originating stream slots" $
      mkCompactionManifest (base & #selections .~ [selection, selection & #eventId .~ eid 2 & #globalPosition .~ GlobalPosition 43])
        `shouldBe` Left (CompactionManifestDuplicateOriginVersion origin (StreamVersion 3))
    it "rejects reserved origin, link and head names" $ do
      mkCompactionManifest (changeSelection (#originStream .~ reserved)) `shouldBe` Left (CompactionManifestReservedStream reserved)
      mkCompactionManifest (changeSelection (#acknowledgedLinks .~ V.singleton (LinkWitness reserved (StreamVersion 1)))) `shouldBe` Left (CompactionManifestReservedStream reserved)
      mkCompactionManifest (base & #streamHeads .~ [StreamHeadWitness reserved (StreamVersion 1)]) `shouldBe` Left (CompactionManifestReservedStream reserved)
    it "measures names and operation labels in UTF-8 bytes" $ do
      let longName = StreamName (T.replicate 257 "ψ")
      mkCompactionManifest (changeSelection (#originStream .~ longName)) `shouldBe` Left (CompactionManifestInvalidStreamName longName 514)
      mkCompactionOperation "" `shouldBe` Left CompactionManifestOperationEmpty
      mkCompactionOperation (T.replicate 513 "x") `shouldBe` Left (CompactionManifestOperationTooLong 513)
    it "rejects nonpositive origin versions, link versions and global positions" $ do
      mkCompactionManifest (changeSelection (#originVersion .~ StreamVersion 0)) `shouldBe` Left (CompactionManifestNonPositiveVersion selection.eventId)
      mkCompactionManifest (changeSelection (#globalPosition .~ GlobalPosition 0)) `shouldBe` Left (CompactionManifestNonPositivePosition selection.eventId)
      mkCompactionManifest (changeSelection (#acknowledgedLinks .~ V.singleton (LinkWitness target (StreamVersion 0)))) `shouldBe` Left (CompactionManifestNonPositiveVersion selection.eventId)
    it "rejects duplicate links and links into the origin" $ do
      let link = LinkWitness target (StreamVersion 1)
      mkCompactionManifest (changeSelection (#acknowledgedLinks .~ V.fromList [link, link])) `shouldBe` Left (CompactionManifestDuplicateLink selection.eventId link)
      mkCompactionManifest (changeSelection (#acknowledgedLinks .~ V.singleton (LinkWitness origin (StreamVersion 1)))) `shouldBe` Left (CompactionManifestLinkIntoOrigin selection.eventId)
    it "requires exactly one head for every touched stream" $ do
      mkCompactionManifest (base & #streamHeads .~ []) `shouldBe` Left (CompactionManifestMissingStreamHead origin)
      mkCompactionManifest (base & #streamHeads .~ [headWitness, headWitness]) `shouldBe` Left (CompactionManifestDuplicateStreamHead origin)
      mkCompactionManifest (base & #streamHeads .~ [headWitness, StreamHeadWitness target (StreamVersion 1)]) `shouldBe` Left (CompactionManifestUnusedStreamHead target)
    it "refuses an expected digest mismatch" $ do
      let computed = compactionManifestDigest (manifest base)
      mkCompactionManifest (base & #expectedDigest .~ Just zeroDigest)
        `shouldBe` Left (CompactionManifestDigestMismatch zeroDigest computed)
    it "bounds ledger queries and validates digest representations" $ do
      forM_ [0, 1001] $ \n -> mkCompactionLedgerLimit n `shouldBe` Left (CompactionLedgerLimitOutOfRange n)
      mkCompactionDigest (BS.replicate 31 0) `shouldBe` Nothing
      parseCompactionDigestHex (T.replicate 63 "0") `shouldBe` Nothing
      parseCompactionDigestHex (T.replicate 64 "z") `shouldBe` Nothing
      parseCompactionDigestHex (T.replicate 64 "Ｆ") `shouldBe` Nothing
      parseCompactionDigestHex (compactionDigestHex zeroDigest) `shouldBe` Just zeroDigest

  describe "canonical encoding" $ do
    it "pins the independent 134-byte worked example" $ do
      let m = manifest base
      BS.length (canonicalCompactionManifestBytes m) `shouldBe` 134
      canonicalCompactionManifestBytes m
        `shouldBe` BS.pack
          ( [107, 105, 114, 111, 107, 117, 45, 99, 111, 109, 112, 97, 99, 116, 105, 111, 110, 45, 109, 97, 110, 105, 102, 101, 115, 116, 47, 49, 10]
              <> [0, 0, 0, 0, 0, 0, 112, 0, 128, 0, 0, 0, 0, 0, 0, 1]
              <> [0, 0, 0, 7, 99, 111, 109, 112, 97, 99, 116, 0, 0, 0, 0, 0, 1]
              <> [0, 0, 0, 8, 111, 114, 100, 101, 114, 115, 45, 49, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 1]
              <> [0, 0, 0, 0, 0, 0, 112, 0, 128, 0, 0, 0, 0, 0, 0, 170]
              <> [0, 0, 0, 8, 111, 114, 100, 101, 114, 115, 45, 49, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 0]
          )
      compactionDigestHex (compactionManifestDigest m) `shouldBe` "965e364734a98abdc509ceb0b4f082ab7a2dbd66713d56ce77d2071e55589d08"
    it "requires format and digest on JSON input" $ do
      let Aeson.Object object = Aeson.toJSON (manifest base)
      (Aeson.fromJSON (Aeson.Object (KM.delete "digest" object)) :: Aeson.Result CompactionManifest) `shouldSatisfy` isError
      (Aeson.fromJSON (Aeson.Object (KM.insert "format" (Aeson.String "wrong") object)) :: Aeson.Result CompactionManifest) `shouldSatisfy` isError
    it "rejects a corrupted report digest" $
      (Aeson.eitherDecode (Aeson.encode (reportFor base & #reportDigest .~ zeroDigest)) :: Either String CompactionReport) `shouldSatisfy` isLeft
    it "round-trips every refusal constructor" $ do
      let now = UTCTime (fromGregorian 2026 10 27) 0
          link = LinkWitness target (StreamVersion 1)
          identity = base.storeIdentity
          refusals =
            [ CompactionStoreIdentityMismatch identity identity,
              CompactionHistoryRetentionActive (HistoryRetentionConflict 2 now),
              CompactionStreamMissing origin,
              CompactionStreamSoftDeleted origin,
              CompactionStreamHeadDrift origin (StreamVersion 1) (StreamVersion 2),
              CompactionSelectedEventMissing selection.eventId,
              CompactionWitnessMismatch selection.eventId (WitnessMismatch origin (StreamVersion 1) Nothing),
              CompactionUnexpectedLink selection.eventId link,
              CompactionAcknowledgedLinkMissing selection.eventId link,
              CompactionDeadLettersPresent selection.eventId 2,
              CompactionCausationDependentsPresent selection.eventId 3,
              CompactionLedgerConflict (CompactionId UUID.nil) 4
            ]
      forM_ refusals $ \r -> Aeson.eitherDecode (Aeson.encode r) `shouldBe` Right r

  modifyMaxSuccess (const 200) $ describe "properties" $ do
    it "is deterministic and insensitive to enumeration order" $ hedgehog $ do
      input <- forAll genInput
      shuffledSelections <- forAll (Gen.shuffle input.selections)
      shuffledHeads <- forAll (Gen.shuffle input.streamHeads)
      shuffledLinks <- traverse (\s -> do ls <- forAll (Gen.shuffle (V.toList s.acknowledgedLinks)); pure (s & #acknowledgedLinks .~ V.fromList ls)) shuffledSelections
      let first = manifest input
          second = manifest (input & #selections .~ shuffledLinks & #streamHeads .~ shuffledHeads)
      compactionManifestDigest first === compactionManifestDigest (manifest input)
      canonicalCompactionManifestBytes first === canonicalCompactionManifestBytes second
    it "changes its digest for every witnessed input field" $ hedgehog $ do
      input <- forAll genInput
      let m = manifest input
          s : ss = input.selections
          h : hs = input.streamHeads
          swapped = StreamName "changed-origin"
          variants =
            [ input & #operation .~ operation "changed",
              input & #deadLetterPolicy .~ RemoveDeadLetters,
              input & #causationPolicy .~ AllowDanglingCausation,
              input & #storeIdentity .~ StoreIdentity UUID.nil,
              input & #streamHeads .~ ((h & #headVersion .~ StreamVersion 9000000) : hs),
              input & #selections .~ ((s & #originVersion .~ StreamVersion 9000000) : ss),
              input & #selections .~ ((s & #globalPosition .~ GlobalPosition 9000000) : ss),
              input & #selections .~ ((s & #eventId .~ eid 9000000) : ss),
              input
                & #selections .~ ((s & #originStream .~ swapped) : ss)
                & #streamHeads .~ (StreamHeadWitness swapped (StreamVersion 1) : filter (\headValue -> headValue.stream /= s.originStream) input.streamHeads),
              input
                & #selections .~ ((s & #acknowledgedLinks .~ V.filter (\l -> l.stream /= target) s.acknowledgedLinks) : ss)
                & #streamHeads .~ filter (\headValue -> headValue.stream /= target) input.streamHeads
            ]
      forM_ variants $ \variant -> assert (compactionManifestDigest (manifest variant) /= compactionManifestDigest m)
    it "round-trips manifests, reports and ledger records through JSON" $ hedgehog $ do
      input <- forAll genInput
      let m = manifest input
          r = reportFor input
          record = CompactionRecord (CompactionId UUID.nil) r (UTCTime (fromGregorian 2026 10 27) 0) "operator"
      Aeson.eitherDecode (Aeson.encode m) === Right m
      Aeson.eitherDecode (Aeson.encode r) === Right r
      Aeson.eitherDecode (Aeson.encode record) === Right record
    it "detects digest corruption on decoding" $ hedgehog $ do
      input <- forAll genInput
      let Aeson.Object object = Aeson.toJSON (manifest input)
          damaged = Aeson.Object (KM.insert "digest" (Aeson.toJSON zeroDigest) object)
      assert (isError (Aeson.fromJSON damaged :: Aeson.Result CompactionManifest))

origin, target, reserved :: StreamName
origin = StreamName "orders-1"
target = StreamName "audit-2026"
reserved = StreamName "$all"

eid :: (Integral a) => a -> EventId
eid n = EventId (UUID.fromWords64 0 (fromIntegral n))

operation :: Text -> CompactionOperation
operation = either (error . show) id . mkCompactionOperation

zeroDigest :: CompactionDigest
zeroDigest = fromJust (mkCompactionDigest (BS.replicate 32 0))

selection :: CompactionSelection
selection = CompactionSelection (EventId (fromJust (UUID.fromText "00000000-0000-7000-8000-0000000000aa"))) origin (StreamVersion 3) (GlobalPosition 42) V.empty

headWitness :: StreamHeadWitness
headWitness = StreamHeadWitness origin (StreamVersion 7)

base :: CompactionManifestInput
base = CompactionManifestInput (StoreIdentity (fromJust (UUID.fromText "00000000-0000-7000-8000-000000000001"))) (operation "compact") RefuseDeadLetters RefuseCausationDependents [headWitness] [selection] Nothing

manifest :: CompactionManifestInput -> CompactionManifest
manifest = either (error . show) id . mkCompactionManifest

changeSelection :: (CompactionSelection -> CompactionSelection) -> CompactionManifestInput
changeSelection f = base & #selections .~ [f selection]

isError :: Aeson.Result a -> Bool
isError (Aeson.Error _) = True
isError _ = False

reportFor :: CompactionManifestInput -> CompactionReport
reportFor input =
  sealCompactionReport
    ( CompactionReport
        (compactionManifestDigest m)
        (manifestStoreIdentity m)
        (manifestOperation m)
        (manifestDeadLetterPolicy m)
        (manifestCausationPolicy m)
        count
        count
        count
        links
        0
        0
        (V.head sels).globalPosition
        (V.last sels).globalPosition
        (manifestStreamHeads m)
        zeroDigest
    )
  where
    m = manifest input
    sels = manifestSelections m
    count = fromIntegral (V.length sels)
    links = fromIntegral (sum (map (V.length . (\s -> s.acknowledgedLinks)) (V.toList sels)))

genInput :: Gen CompactionManifestInput
genInput = do
  size <- Gen.int (Range.linear 1 15)
  seed <- Gen.word64 (Range.linear 100 100000)
  let names = [StreamName ("ψ-" <> T.pack (show n)) | n <- [1 .. size]]
      sels =
        [ CompactionSelection
            (eid (seed + fromIntegral n))
            name
            (StreamVersion 1)
            (GlobalPosition (fromIntegral n))
            (if n == 1 then V.fromList [LinkWitness target (StreamVersion 1), LinkWitness (StreamName "audit-2027") (StreamVersion 2)] else V.empty)
        | (n, name) <- zip [1 :: Int ..] names
        ]
  pure (base & #selections .~ sels & #streamHeads .~ (StreamHeadWitness target (StreamVersion 1) : StreamHeadWitness (StreamName "audit-2027") (StreamVersion 2) : map (\name -> StreamHeadWitness name (StreamVersion 1)) names))
