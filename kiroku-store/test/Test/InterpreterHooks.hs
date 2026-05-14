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

import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Vector qualified as V
import Kiroku.Store
import Test.Helpers (makeEvent, waitForPublisher, waitWithTimeout, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = describe "InterpreterHooks" $ do
    describe "enrichEvent" appendHookFiresSpec
    describe "decodeHook" readHookFiresSpec

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

-- ---------------------------------------------------------------------------
-- decodeHook
-- ---------------------------------------------------------------------------

readHookFiresSpec :: Spec
readHookFiresSpec = do
    it "applies decodeHook to readAllForward results" $ do
        let marker = Aeson.object [("decoded", Aeson.String "yes")]
            inject re = pure $ re & #metadata .~ Just marker
            tweak cs =
                cs
                    & #storeSettings
                        .~ defaultStoreSettings{decodeHook = Just inject}
        withTestStoreSettings tweak $ \store -> do
            Right _ <-
                runStoreIO store $
                    appendToStream
                        (StreamName "hook-decode-1")
                        NoStream
                        [ makeEvent "E1" (Aeson.object [])
                        , makeEvent "E2" (Aeson.object [])
                        , makeEvent "E3" (Aeson.object [])
                        ]
            Right v <-
                runStoreIO store $
                    readAllForward (GlobalPosition 0) 10
            V.length v `shouldBe` 3
            for_ (V.toList v) $ \re ->
                (re ^. #metadata) `shouldBe` Just marker

    it "applies decodeHook to subscription handlers across catch-up and live phases" $ do
        let marker = Aeson.object [("sub", Aeson.String "tagged")]
            inject re = pure $ re & #metadata .~ Just marker
            subName = SubscriptionName "hook-sub-1"
            tweak cs =
                cs
                    & #storeSettings
                        .~ defaultStoreSettings{decodeHook = Just inject}
        withTestStoreSettings tweak $ \store -> do
            -- Pre-append one event so the worker's catch-up path runs
            -- before live mode kicks in.
            Right warm <-
                runStoreIO store $
                    appendToStream
                        (StreamName "hook-sub-stream-1")
                        NoStream
                        [makeEvent "warm" (Aeson.object [])]
            waitForPublisher store (warm ^. #globalPosition)

            seen <- newIORef ([] :: [Maybe Aeson.Value])
            done <- newEmptyMVar
            let handlerFn re = do
                    modifyIORef' seen ((re ^. #metadata) :)
                    n <- length <$> readIORef seen
                    if n >= 2
                        then Stop <$ tryPutMVar done ()
                        else pure Continue
                config = defaultSubscriptionConfig subName AllStreams handlerFn
            sub <- subscribe store config
            -- Append a second event to land in live mode.
            Right _ <-
                runStoreIO store $
                    appendToStream
                        (StreamName "hook-sub-stream-2")
                        NoStream
                        [makeEvent "live" (Aeson.object [])]
            takeMVar done
            res <- waitWithTimeout 2_000_000 sub
            case res of
                Right (Right ()) -> pure ()
                other -> expectationFailure ("subscription did not finish cleanly: " <> show other)
            metas <- reverse <$> readIORef seen
            metas `shouldBe` [Just marker, Just marker]
