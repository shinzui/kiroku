module Kiroku.Store.Migrations (
    DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    kirokuMigrationPlan,
    kirokuMigrations,
) where

import Data.List.NonEmpty (NonEmpty (..))
import Database.PostgreSQL.Migrate (
    DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    migrationPlan,
 )
import Kiroku.Store.Migrations.Internal.Definition (kirokuMigrations)

{- | The complete single-component Kiroku migration plan.

The embedded manifest is validated at compile time, so a component-definition
failure indicates a broken package invariant rather than an operator error.
-}
kirokuMigrationPlan :: Either PlanError MigrationPlan
kirokuMigrationPlan =
    case kirokuMigrations of
        Left definitionError ->
            error ("invalid embedded Kiroku migration component: " <> show definitionError)
        Right component -> migrationPlan (component :| [])
