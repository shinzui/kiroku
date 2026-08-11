{-# LANGUAGE NumericUnderscores #-}

module Test.SubscriptionCheckpointReset (spec) where

import Contravariant.Extras (contrazip2)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable, unpreparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "subscription checkpoint reset" $ do
    it "commits every persisted member and reports sorted affected and missing names exactly" $
        withTestStore $ \store -> do
            appendEvents store "reset-commit-events" 10
            initializeRows store [("zeta", 1), ("alpha", 2), ("alpha", 0)]
            createSentinelTable store

            result <- runStoreIO store $ runTransaction $ do
                Tx.statement (1, "committed") insertSentinelStmt
                resetSubscriptionCheckpointsTx
                    ( SubscriptionName "zeta"
                        :| [ SubscriptionName "missing"
                           , SubscriptionName "alpha"
                           , SubscriptionName "alpha"
                           ]
                    )
                    (GlobalPosition 7)

            result
                `shouldBe` Right
                    SubscriptionCheckpointResetReport
                        { resetCheckpointKeys =
                            Vector.fromList
                                [ SubscriptionCheckpointKey (SubscriptionName "alpha") 0
                                , SubscriptionCheckpointKey (SubscriptionName "alpha") 2
                                , SubscriptionCheckpointKey (SubscriptionName "zeta") 1
                                ]
                        , missingSubscriptionNames = Vector.singleton (SubscriptionName "missing")
                        }
            countSentinels store `shouldReturn` 1
            inventoryKeys <$> inventory store
                `shouldReturn` [ ("alpha", 0, 7)
                               , ("alpha", 2, 7)
                               , ("zeta", 1, 7)
                               ]

    it "rolls back the reset and an application-table write when the transaction is condemned" $
        withTestStore $ \store -> do
            appendEvents store "reset-rollback-events" 10
            initializeRows store [("rollback", 0)]
            reset store (SubscriptionName "rollback" :| []) (GlobalPosition 9)
            createSentinelTable store

            result <- runStoreIO store $ runTransaction $ do
                Tx.statement (2, "rolled back") insertSentinelStmt
                report <-
                    resetSubscriptionCheckpointsTx
                        (SubscriptionName "rollback" :| [])
                        (GlobalPosition 3)
                Tx.condemn
                pure report

            result
                `shouldBe` Right
                    SubscriptionCheckpointResetReport
                        { resetCheckpointKeys =
                            Vector.singleton
                                (SubscriptionCheckpointKey (SubscriptionName "rollback") 0)
                        , missingSubscriptionNames = Vector.empty
                        }
            countSentinels store `shouldReturn` 0
            inventoryKeys <$> inventory store `shouldReturn` [("rollback", 0, 9)]

    it "can rewind while later ordinary saves remain monotonic" $
        withTestStore $ \store -> do
            appendEvents store "reset-rewind-events" 10
            initializeRows store [("rewind", 0)]
            reset store (SubscriptionName "rewind" :| []) (GlobalPosition 8)
            reset store (SubscriptionName "rewind" :| []) (GlobalPosition 4)
            inventoryKeys <$> inventory store `shouldReturn` [("rewind", 0, 4)]

            saveCheckpoint store "rewind" 0 2
            inventoryKeys <$> inventory store `shouldReturn` [("rewind", 0, 4)]
            saveCheckpoint store "rewind" 0 6
            inventoryKeys <$> inventory store `shouldReturn` [("rewind", 0, 6)]

    it "reports missing names without manufacturing checkpoint rows" $
        withTestStore $ \store -> do
            result <-
                reset
                    store
                    (SubscriptionName "absent-b" :| [SubscriptionName "absent-a"])
                    (GlobalPosition 5)
            result
                `shouldBe` SubscriptionCheckpointResetReport
                    { resetCheckpointKeys = Vector.empty
                    , missingSubscriptionNames =
                        Vector.fromList
                            [SubscriptionName "absent-a", SubscriptionName "absent-b"]
                    }
            inventoryKeys <$> inventory store `shouldReturn` []

initializeRows :: KirokuStore -> [(Text, Int32)] -> IO ()
initializeRows store rows =
    mapM_ initialize rows
  where
    initialize (name, member) = do
        result <-
            runStoreIO store $
                initializeSubscriptionCheckpoint
                    (SubscriptionName name)
                    member
                    FromBeginning
        case result of
            Right (Right _) -> pure ()
            other -> expectationFailure ("checkpoint initialization failed: " <> show other)

reset ::
    KirokuStore ->
    NonEmpty SubscriptionName ->
    GlobalPosition ->
    IO SubscriptionCheckpointResetReport
reset store names position = do
    result <- runStoreIO store $ runTransaction $ resetSubscriptionCheckpointsTx names position
    case result of
        Left err -> expectationFailure ("checkpoint reset failed: " <> show err) >> error "unreachable"
        Right report -> pure report

inventory :: KirokuStore -> IO SubscriptionCheckpointInventory
inventory store = do
    result <- runStoreIO store subscriptionCheckpointInventory
    case result of
        Left err -> expectationFailure ("checkpoint inventory failed: " <> show err) >> error "unreachable"
        Right rows -> pure rows

inventoryKeys :: SubscriptionCheckpointInventory -> [(Text, Int32, Int64)]
inventoryKeys (SubscriptionCheckpointInventory _ rows) =
    [ (name, member, position)
    | SubscriptionCheckpoint (SubscriptionName name) member (GlobalPosition position) _ <-
        Vector.toList rows
    ]

appendEvents :: KirokuStore -> Text -> Int -> IO ()
appendEvents store stream count = do
    let events =
            [makeEvent ("Reset" <> Text.pack (show i)) (Aeson.object []) | i <- [1 .. count]]
    result <- runStoreIO store $ appendToStream (StreamName stream) NoStream events
    case result of
        Left err -> expectationFailure ("append failed: " <> show err)
        Right _ -> pure ()

saveCheckpoint :: KirokuStore -> Text -> Int32 -> Int64 -> IO ()
saveCheckpoint store name member position = do
    result <-
        Pool.use (store ^. #pool) $
            Session.statement (name, member, position) SQL.saveCheckpointMemberStmt
    case result of
        Left err -> expectationFailure ("ordinary checkpoint save failed: " <> show err)
        Right () -> pure ()

createSentinelTable :: KirokuStore -> IO ()
createSentinelTable store = do
    result <- Pool.use (store ^. #pool) (Session.statement () createSentinelTableStmt)
    case result of
        Left err -> expectationFailure ("sentinel table creation failed: " <> show err)
        Right () -> pure ()

countSentinels :: KirokuStore -> IO Int64
countSentinels store = do
    result <- Pool.use (store ^. #pool) (Session.statement () countSentinelsStmt)
    case result of
        Left err -> expectationFailure ("sentinel count failed: " <> show err) >> error "unreachable"
        Right count -> pure count

createSentinelTableStmt :: Statement () ()
createSentinelTableStmt =
    unpreparable
        "CREATE TABLE public.checkpoint_reset_sentinel \
        \(id BIGINT PRIMARY KEY, value TEXT NOT NULL)"
        E.noParams
        D.noResult

insertSentinelStmt :: Statement (Int64, Text) ()
insertSentinelStmt =
    preparable
        "INSERT INTO public.checkpoint_reset_sentinel (id, value) VALUES ($1, $2)"
        ( contrazip2
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

countSentinelsStmt :: Statement () Int64
countSentinelsStmt =
    preparable
        "SELECT COUNT(*) FROM public.checkpoint_reset_sentinel"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.int8)))
