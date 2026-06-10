{- | Pure laws for the category accessor and safe stream-name constructor
('Kiroku.Store.Types.categoryName' and 'streamNameInCategory').

These pin the "category = substring before the first @-@" rule — enforced by
the @streams.category GENERATED ALWAYS AS split_part(stream_name,'-',1)@ column
and re-derived in 'Kiroku.Store.Notification' — so the public accessor cannot
drift from it. The round-trip law is the contract keiro's typed @Category@ API
(ExecPlan #66) builds on.

Pure; no database. Runs inside hspec via 'hspec-hedgehog'.
-}
module Test.Category (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hedgehog
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Kiroku.Store.Types (CategoryName (..), StreamName (..), categoryName, streamNameInCategory)
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

{- | A non-empty, dash-free category. Includes @:@ and @$@ to exercise the
sub-namespacing convention (e.g. @"wf:orders"@) without the @-@ boundary.
-}
genCategoryText :: Gen Text
genCategoryText = Gen.text (Range.linear 1 16) (Gen.element categoryChars)
  where
    categoryChars = ['a' .. 'z'] <> ['0' .. '9'] <> [':', '$', '_']

{- | An arbitrary id segment. May contain @-@: the id lives after the first
@-@, so embedded dashes must not change the leading category.
-}
genSegment :: Gen Text
genSegment = Gen.text (Range.linear 0 16) (Gen.element segmentChars)
  where
    segmentChars = ['a' .. 'z'] <> ['0' .. '9'] <> ['-', ':', '_']

-- | An arbitrary stream name (may contain dashes anywhere, or none).
genStreamNameText :: Gen Text
genStreamNameText = Gen.text (Range.linear 0 24) (Gen.element nameChars)
  where
    nameChars = ['a' .. 'z'] <> ['0' .. '9'] <> ['-', ':', '_']

spec :: Spec
spec = describe "Kiroku.Store.Types category rule" $ do
    describe "categoryName" $ do
        it "takes the substring before the first dash" $
            categoryName (StreamName "orders-1") `shouldBe` CategoryName "orders"

        it "treats a dashless name as its own category" $
            categoryName (StreamName "singleton") `shouldBe` CategoryName "singleton"

        it "stops at the first dash even with later dashes" $
            categoryName (StreamName "orders-a-b-c") `shouldBe` CategoryName "orders"

        it "never yields a category containing a dash" $ hedgehog $ do
            name <- forAll genStreamNameText
            let CategoryName cat = categoryName (StreamName name)
            assert (not (T.isInfixOf "-" cat))

    describe "streamNameInCategory" $ do
        it "joins category and segment with a dash" $
            streamNameInCategory (CategoryName "orders") "1" `shouldBe` StreamName "orders-1"

    describe "round-trip" $ do
        it "categoryName . streamNameInCategory == id, for dash-free categories" $ hedgehog $ do
            cat <- forAll genCategoryText
            seg <- forAll genSegment
            categoryName (streamNameInCategory (CategoryName cat) seg) === CategoryName cat
