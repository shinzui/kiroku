{- | Tests for the logical truncate-before marker (close-the-book
compaction, ExecPlan docs/plans/65).

The marker is a per-stream cursor that hides a prefix from the /ordered
per-stream/ reads ('readStreamForward' / 'readStreamBackward' and the paged
'readStreamForwardStream') while leaving the global @$all@ log, category
reads, and the physical row count untouched. The distinguishing property —
and the single most important assertion here — is that after a truncate the
@$all@ log and 'readCategory' still return the full history and
'countEvents' is unchanged: nothing is deleted, only hidden, and the
operation is fully reversible.
-}
module Test.TruncateBefore (spec) where

import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Vector qualified as V
import Kiroku.Store
import Streamly.Data.Stream qualified as Stream
import Test.Helpers (countEvents, makeEvent, withTestStore)
import Test.Hspec

-- | Append @n@ events @E1 .. En@ to a fresh stream and return its name.
seedStream :: KirokuStore -> StreamName -> Int -> IO ()
seedStream store name n = do
    let events = [makeEvent (T.pack ("E" <> show i)) (Aeson.object []) | i <- [1 .. n]]
    Right _ <- runStoreIO store $ appendToStream name NoStream events
    pure ()

-- | The per-stream versions returned by a forward read, in order.
forwardVersions :: KirokuStore -> StreamName -> IO [StreamVersion]
forwardVersions store name = do
    Right v <- runStoreIO store $ readStreamForward name (StreamVersion 0) 100
    pure (map (^. #streamVersion) (V.toList v))

spec :: Spec
spec = describe "TruncateBefore" $
    around withTestStore $ do
        it "bounds per-stream reads to the kept suffix" $ \store -> do
            let name = StreamName "preference-abc"
            seedStream store name 6 -- versions 1..6; treat v6 as the snapshot
            Right (Just _) <- runStoreIO store $ setStreamTruncateBefore name (StreamVersion 6)

            forwardVersions store name `shouldReturn` [StreamVersion 6]

            Right back <- runStoreIO store $ readStreamBackward name (StreamVersion 0) 100
            map (^. #streamVersion) (V.toList back) `shouldBe` [StreamVersion 6]

        it "leaves the $all global log and category reads intact" $ \store -> do
            let name = StreamName "preference-abc"
            seedStream store name 6
            before <- countEvents store
            Right (Just _) <- runStoreIO store $ setStreamTruncateBefore name (StreamVersion 6)

            -- \$all global log still returns the full history.
            Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 1000
            length (V.toList allEvents) `shouldBe` 6

            -- Category read still returns the full history.
            Right catEvents <- runStoreIO store $ readCategory (CategoryName "preference") (GlobalPosition 0) 1000
            length (V.toList catEvents) `shouldBe` 6

            -- Nothing was physically deleted.
            after <- countEvents store
            after `shouldBe` before

        it "is reversible via clearStreamTruncateBefore" $ \store -> do
            let name = StreamName "preference-abc"
            seedStream store name 6
            Right (Just _) <- runStoreIO store $ setStreamTruncateBefore name (StreamVersion 6)
            forwardVersions store name `shouldReturn` [StreamVersion 6]

            Right (Just _) <- runStoreIO store $ clearStreamTruncateBefore name
            forwardVersions store name
                `shouldReturn` map StreamVersion [1 .. 6]

        it "is idempotent" $ \store -> do
            let name = StreamName "preference-abc"
            seedStream store name 6
            Right (Just _) <- runStoreIO store $ setStreamTruncateBefore name (StreamVersion 4)
            first <- forwardVersions store name
            Right (Just _) <- runStoreIO store $ setStreamTruncateBefore name (StreamVersion 4)
            second <- forwardVersions store name
            first `shouldBe` [StreamVersion 4, StreamVersion 5, StreamVersion 6]
            second `shouldBe` first

        it "applies across paged reads" $ \store -> do
            let name = StreamName "preference-abc"
            seedStream store name 6
            Right (Just _) <- runStoreIO store $ setStreamTruncateBefore name (StreamVersion 4)
            -- Page size 2 forces multiple pages across the kept suffix.
            Right streamed <-
                runStoreIO store $
                    Stream.toList $
                        fmap (^. #streamVersion) (readStreamForwardStream name (StreamVersion 0) 2)
            streamed `shouldBe` [StreamVersion 4, StreamVersion 5, StreamVersion 6]

        it "reflects the marker in getStream" $ \store -> do
            let name = StreamName "preference-abc"
            seedStream store name 6
            Right (Just info0) <- runStoreIO store $ getStream name
            (info0 ^. #truncateBefore) `shouldBe` StreamVersion 0
            Right (Just _) <- runStoreIO store $ setStreamTruncateBefore name (StreamVersion 3)
            Right (Just info1) <- runStoreIO store $ getStream name
            (info1 ^. #truncateBefore) `shouldBe` StreamVersion 3

        it "returns Nothing for missing or soft-deleted streams" $ \store -> do
            Right missing <- runStoreIO store $ setStreamTruncateBefore (StreamName "does-not-exist") (StreamVersion 1)
            missing `shouldBe` Nothing

            let name = StreamName "preference-abc"
            seedStream store name 3
            Right (Just _) <- runStoreIO store $ softDeleteStream name
            Right deleted <- runStoreIO store $ setStreamTruncateBefore name (StreamVersion 1)
            deleted `shouldBe` Nothing

        it "rejects $all with ReservedStreamName" $ \store -> do
            result <- runStoreIO store $ setStreamTruncateBefore (StreamName "$all") (StreamVersion 1)
            case result of
                Left (ReservedStreamName (StreamName "$all")) -> pure ()
                other ->
                    expectationFailure
                        ("Expected Left (ReservedStreamName \"$all\"), got: " <> show other)
