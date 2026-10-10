module Test.UniqueViolationMapping (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import Data.UUID qualified as UUID
import Hasql.Errors qualified as Errors
import Hasql.Pool (UsageError (..))
import Kiroku.Store.Error
import Kiroku.Store.Types
import Test.Hspec

spec :: Spec
spec = describe "unique violation mapping" $ do
    let eid = EventId (UUID.fromWords 0x01234567 0x89ab7def 0x80123456 0x7890abcd)
        scalar = "Key (event_id)=(01234567-89ab-7def-8012-34567890abcd) already exists."
        composite = "Key (event_id, stream_id)=(01234567-89ab-7def-8012-34567890abcd, 42) already exists."
        fallback = WrongExpectedVersion (StreamName "orders-1") AnyVersion (StreamVersion 0)
        mapAppend = mapUsageError "orders-1" AnyVersion
        cases =
            [ ("events_pkey", scalar, DuplicateEvent (Just eid))
            , ("stream_events_pkey", composite, DuplicateEvent (Just eid))
            , ("ix_streams_stream_name", "Key (stream_name)=(orders-1) already exists.", StreamAlreadyExists (StreamName "orders-1"))
            , ("ux_stream_events_stream_version", "Key (stream_id, stream_version)=(42, 1) already exists.", UnexpectedServerError "23505" "detail-only error")
            , ("unknown_constraint", scalar, fallback)
            ]
    forM_ cases $ \(name, detail, expected) -> do
        it ("classifies the exact message constraint " <> show name) $ do
            let message = constraintMessage name
                outcome = case expected of
                    UnexpectedServerError code _ -> UnexpectedServerError code message
                    other -> other
            mapAppend (serverUsage message (Just detail)) `shouldBe` outcome
        it ("classifies a detail-only constraint " <> show name) $
            mapAppend (serverUsage "detail-only error" (Just ("constraint: " <> name <> "; " <> detail)))
                `shouldBe` expected

    it "does not match stream_events_pkey as events_pkey" $
        mapAppend (serverUsage (constraintMessage "stream_events_pkey") (Just composite))
            `shouldBe` DuplicateEvent (Just eid)
    forM_ ["events_pkey", "stream_events_pkey", "ix_streams_stream_name", "ux_stream_events_stream_version"] $ \name ->
        forM_ ["prefix_" <> name, name <> "_suffix", name <> "$suffix"] $ \other -> do
            it ("rejects the message lookalike " <> show other) $
                mapAppend (serverUsage (constraintMessage other) (Just scalar)) `shouldBe` fallback
            it ("rejects the detail lookalike " <> show other) $
                mapAppend (serverUsage "detail-only error" (Just (other <> "; " <> scalar))) `shouldBe` fallback

    it "uses the message constraint ahead of misleading detail tokens" $
        mapAppend (serverUsage (constraintMessage "ux_stream_events_stream_version") (Just ("events_pkey " <> scalar)))
            `shouldBe` UnexpectedServerError "23505" (constraintMessage "ux_stream_events_stream_version")
    it "retains an unknown message constraint even when detail names a known constraint" $
        mapAppend (serverUsage (constraintMessage "unknown_constraint") (Just ("events_pkey " <> scalar)))
            `shouldBe` fallback
    forM_ ["events_pkey", "stream_events_pkey"] $ \name ->
        forM_ [Nothing, Just "unparseable localized detail"] $ \detail ->
            it ("does not fabricate an event id for " <> show (name, detail)) $
                mapAppend (serverUsage (constraintMessage name) detail) `shouldBe` DuplicateEvent Nothing
    it "maps a composite duplicate inside a transaction with its event id" $
        mapTransactionUsageError (serverUsage (constraintMessage "stream_events_pkey") (Just composite))
            `shouldBe` DuplicateEvent (Just eid)
    it "preserves the link-specific duplicate classification" $
        mapLinkUsageError (StreamName "orders-1") (serverUsage (constraintMessage "stream_events_pkey") (Just composite))
            `shouldBe` EventAlreadyLinked (StreamName "orders-1") (Just eid)
    it "accepts a quoted constraint in legacy detail" $
        mapAppend (serverUsage "detail-only error" (Just (constraintMessage "stream_events_pkey" <> "; " <> composite)))
            `shouldBe` DuplicateEvent (Just eid)
    it "keeps an unnamed unique violation on the conservative fallback" $
        mapAppend (serverUsage "localized message" Nothing) `shouldBe` fallback
    it "does not classify a transaction constraint lookalike as a duplicate" $
        mapTransactionUsageError (serverUsage (constraintMessage "other_events_pkey") (Just scalar))
            `shouldBe` UnexpectedServerError "23505" (constraintMessage "other_events_pkey")
    it "does not classify a link constraint lookalike as already linked" $
        mapLinkUsageError (StreamName "orders-1") (serverUsage (constraintMessage "stream_events_pkey_backup") (Just composite))
            `shouldBe` UnexpectedServerError "23505" (constraintMessage "stream_events_pkey_backup")
    it "attributes a multi-stream name violation to the named operation" $
        attributeMultiStreamError
            [(StreamName "orders-1", AnyVersion), (StreamName "orders-2", NoStream)]
            (serverUsage (constraintMessage "ix_streams_stream_name") (Just "Key (stream_name)=(orders-2) already exists."))
            `shouldBe` StreamAlreadyExists (StreamName "orders-2")
    it "does not attribute a multi-stream constraint lookalike to a later operation" $
        attributeMultiStreamError
            [(StreamName "orders-1", AnyVersion), (StreamName "orders-2", NoStream)]
            (serverUsage (constraintMessage "ix_streams_stream_name_backup") (Just "Key (stream_name)=(orders-2) already exists."))
            `shouldBe` fallback

constraintMessage :: Text -> Text
constraintMessage name = "duplicate key value violates unique constraint \"" <> name <> "\""

serverUsage :: Text -> Maybe Text -> UsageError
serverUsage message detail =
    SessionUsageError $
        Errors.StatementSessionError 1 0 "" [] True $
            Errors.ServerStatementError $
                Errors.ServerError "23505" message detail Nothing Nothing
