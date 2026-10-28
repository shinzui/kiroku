module Test.StoreIdentity (spec) where

import Control.Lens ((^.))
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text (Text)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store
import Test.Helpers (truncateRejected, withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "store identity" $ do
  it "is stable across calls, pooled connections and transaction reads" $
    withTestStore $ \store -> do
      Right first <- runStoreIO store storeIdentity
      runStoreIO store storeIdentity `shouldReturn` Right first
      runStoreIO store (runTransaction storeIdentityTx) `shouldReturn` Right first

  it "is shared by separate databases cloned from the migrated template" $
    withTestStore $ \first -> withTestStore $ \second -> do
      Right identity <- runStoreIO first storeIdentity
      runStoreIO second storeIdentity `shouldReturn` Right identity

  it "rejects identity and ledger mutation without the hard-delete guard" $
    withTestStore $ \store -> do
      rejects store "UPDATE store_identity SET store_id = gen_random_uuid()"
      rejects store "DELETE FROM store_identity"
      truncateRejected store "store_identity" `shouldReturn` True
      seeded <-
        Pool.use (store ^. #pool) $
          Session.script
            "INSERT INTO event_compactions (manifest_digest, report_digest, store_id, operation, dead_letter_policy, causation_policy, selected_events, home_memberships, global_memberships, link_memberships, dead_letters_removed, causation_dependents, lowest_global_position, highest_global_position, affected_streams) VALUES (decode(repeat('ab',32),'hex'), decode(repeat('cd',32),'hex'), gen_random_uuid(), 'trigger-test', 'refuse', 'refuse', 1, 1, 1, 0, 0, 0, 1, 1, '[]'::jsonb)"
      seeded `shouldBe` Right ()
      rejects store "UPDATE event_compactions SET operation = 'changed'"
      rejects store "DELETE FROM event_compactions"
      truncateRejected store "event_compactions" `shouldReturn` True

rejects :: KirokuStore -> Text -> Expectation
rejects store sql = do
  result <- Pool.use (store ^. #pool) (Session.script sql)
  result `shouldSatisfy` isLeft
