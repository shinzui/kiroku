{- | Tests for the interpreter-level event-data hooks installed via
'Kiroku.Store.Settings.StoreSettings'.

Three concerns are covered (added across the plan's milestones):

  * @enrichEvent@ fires on the append path before encoding, so an
    appended event surfaces with the hook's mutation visible.
  * @decodeHook@ fires on the read and subscription paths after
    decoding, so both 'readAllForward' and a live 'subscribe' handler
    see the hook's mutation.
  * With both hooks 'Nothing' (the default), a round-trip is
    byte-identical to the input — the no-op fast path introduces no
    'pure'-wrapping artefact.
-}
module Test.InterpreterHooks (spec) where

import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Vector qualified as V
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = describe "InterpreterHooks" $ do
    describe "enrichEvent" appendHookFiresSpec

-- ---------------------------------------------------------------------------
-- enrichEvent
-- ---------------------------------------------------------------------------

appendHookFiresSpec :: Spec
appendHookFiresSpec = do
    it "applies enrichEvent to appended events surfaced through readStreamForward" $ do
        let marker = Aeson.object [("hook", Aeson.String "applied")]
            inject ed = pure $ ed & #metadata .~ Just marker
            tweak cs =
                cs
                    & #storeSettings
                        .~ defaultStoreSettings{enrichEvent = Just inject}
        withTestStoreSettings tweak $ \store -> do
            Right _ <-
                runStoreIO store $
                    appendToStream
                        (StreamName "hook-append-1")
                        NoStream
                        [makeEvent "X" (Aeson.object [("seed", Aeson.Number 1)])]
            evs <-
                runStoreIO store $
                    readStreamForward (StreamName "hook-append-1") (StreamVersion 0) 10
            case evs of
                Right v
                    | V.length v == 1 ->
                        (V.head v ^. #metadata) `shouldBe` Just marker
                other -> expectationFailure ("unexpected read result: " <> show other)

    it "applies enrichEvent across appendMultiStream per-stream batches" $ do
        countRef <- newIORef (0 :: Int)
        let inject ed = do
                modifyIORef' countRef (+ 1)
                pure $ ed & #metadata .~ Just (Aeson.object [("multi", Aeson.Bool True)])
            tweak cs =
                cs
                    & #storeSettings
                        .~ defaultStoreSettings{enrichEvent = Just inject}
        withTestStoreSettings tweak $ \store -> do
            let ops =
                    [ (StreamName "hook-multi-A", NoStream, [makeEvent "A1" (Aeson.object []), makeEvent "A2" (Aeson.object [])])
                    , (StreamName "hook-multi-B", NoStream, [makeEvent "B1" (Aeson.object [])])
                    ]
            Right _ <- runStoreIO store $ appendMultiStream ops
            n <- readIORef countRef
            n `shouldBe` 3
            Right vA <- runStoreIO store $ readStreamForward (StreamName "hook-multi-A") (StreamVersion 0) 10
            Right vB <- runStoreIO store $ readStreamForward (StreamName "hook-multi-B") (StreamVersion 0) 10
            for_ (V.toList vA <> V.toList vB) $ \re ->
                (re ^. #metadata) `shouldBe` Just (Aeson.object [("multi", Aeson.Bool True)])
