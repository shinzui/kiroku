{-# LANGUAGE TypeFamilies #-}

module Kiroku.Store.Effect.Resource (
    -- * The KirokuStoreResource effect
    KirokuStoreResource,

    -- * Operations
    getKirokuStore,

    -- * Bracket-style runner
    withKirokuStore,

    -- * Runner over an existing handle
    runKirokuStoreWith,
) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, UnliftStrategy (..), withEffToIO, (:>))
import Effectful.Dispatch.Static (SideEffects (..), StaticRep, evalStaticRep, getStaticRep)
import Kiroku.Store.Connection (ConnectionSettings, KirokuStore, withStore)

-- ---------------------------------------------------------------------------
-- KirokuStoreResource static effect
-- ---------------------------------------------------------------------------

{- | Static effect carrying a 'KirokuStore' handle.

Static rather than dynamic because the store handle is acquired exactly
once per program and is not meant to be mocked — the dynamic mocking
surface lives on the 'Kiroku.Store.Effect.Store' effect that operates
against the handle. Splitting the resource (static) from the operations
(dynamic) keeps mocking ergonomic without requiring callers to swap the
handle itself.

@Static WithSideEffects@ rather than @Static NoSideEffects@ because the
underlying connection pool performs IO during operation lookup.
-}
data KirokuStoreResource :: Effect

type instance DispatchOf KirokuStoreResource = Static WithSideEffects

newtype instance StaticRep KirokuStoreResource = KirokuStoreResource KirokuStore

-- | Retrieve the 'KirokuStore' handle from the effect stack.
getKirokuStore :: (KirokuStoreResource :> es) => Eff es KirokuStore
getKirokuStore = do
    KirokuStoreResource store <- getStaticRep
    pure store

-- | Bracket-style runner: acquire the store, install the effect, run the action, release.
withKirokuStore ::
    (IOE :> es) =>
    ConnectionSettings ->
    Eff (KirokuStoreResource : es) a ->
    Eff es a
withKirokuStore settings action = withEffToIO SeqUnlift $ \unlift ->
    withStore settings $ \store ->
        unlift (evalStaticRep (KirokuStoreResource store) action)

{- | Install an /already acquired/ 'KirokuStore' into the effect stack.

Unlike 'withKirokuStore', this neither acquires nor releases: the caller owns
the handle's lifetime. Use it when a process has opened exactly one store (the
documented arrangement) and needs to run several independent effectful actions
against it. Acquiring a store per action instead costs a connection pool, a
dedicated @LISTEN@ connection, and a publisher thread each time.

There is no bracket and no unlifting here, but @IOE@ is still required:
'KirokuStoreResource' is @Static WithSideEffects@, and 'evalStaticRep' demands
@IOE@ for any effect declared that way.
-}
runKirokuStoreWith ::
    (IOE :> es) =>
    KirokuStore ->
    Eff (KirokuStoreResource : es) a ->
    Eff es a
runKirokuStoreWith = evalStaticRep . KirokuStoreResource
