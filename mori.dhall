let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/027403783777cbce0e87eb660a0b3d8119ebe8d2/package.dhall
        sha256:d29ca03286afa92b7589d09b7a6d98ad8e39d11b255a4b8751f3327b0722fba3

let testDep =
      \(name : Text) ->
        Schema.Dependency.WithAugmentation
          { name
          , extraDocs = [] : List Schema.DocRef.Type
          , localPathOverride = None Text
          , kind = None Schema.DependencyKind
          , source = None Schema.DependencySource
          , scope = Some Schema.DependencyScope.Test
          , versionConstraint = None Text
          }

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "kiroku"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , description = Some "PostgreSQL event store in Haskell"
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , domains = [ "EventSourcing", "EventStore" ]
      , owners = [ "shinzui" ]
      }
    , repos =
      [ Schema.Repo::{ name = "kiroku", github = Some "shinzui/kiroku" } ]
    , packages =
      [ Schema.Package::{
        , name = "kiroku-store"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-store"
        , description = Some "Core event store library using hasql"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "nikita-volkov/contravariant-extras"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "ekmett/lens"
          , Schema.Dependency.ByName "hasql/hasql"
          , Schema.Dependency.ByName "MMZK1526/mmzk-typeid"
          , Schema.Dependency.ByName "composewell/streamly"
          , Schema.Dependency.ByName "haskell-hvr/uuid"
          , testDep "shinzui/ephemeral-pg"
          , testDep "shinzui/shibuya"
          , testDep "Bodigrim/tasty-bench"
          ]
        }
      , Schema.Package::{
        , name = "shibuya-kiroku-adapter"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-kiroku-adapter"
        , description = Some
            "Shibuya adapter for Kiroku event store subscriptions"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "effectful/effectful"
          , Schema.Dependency.ByName "iand675/hs-opentelemetry"
          , Schema.Dependency.ByName "shinzui/shibuya"
          , Schema.Dependency.ByName "composewell/streamly"
          , Schema.Dependency.ByName "haskell-hvr/uuid"
          , testDep "shinzui/ephemeral-pg"
          , testDep "ekmett/lens"
          , testDep "hasql/hasql"
          ]
        }
      , Schema.Package::{
        , name = "kiroku-otel"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-otel"
        , description = Some
            "OpenTelemetry W3C trace-context helpers for Kiroku event metadata"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "ekmett/lens"
          , Schema.Dependency.ByName "iand675/hs-opentelemetry"
          , testDep "shinzui/ephemeral-pg"
          , testDep "hasql/hasql"
          , testDep "haskell-hvr/uuid"
          ]
        }
      , Schema.Package::{
        , name = "kiroku-metrics"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-metrics"
        , description = Some
            "Metrics, health, and event-streaming HTTP endpoints for Kiroku"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "hasql/hasql"
          , Schema.Dependency.ByName "snoyberg/http-client"
          , Schema.Dependency.ByName "ekmett/lens"
          , Schema.Dependency.ByName "haskell-hvr/uuid"
          , Schema.Dependency.ByName "yesodweb/wai"
          ]
        }
      , Schema.Package::{
        , name = "kiroku-store-migrations"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-store-migrations"
        , description = Some
            "Native pg-migrate component and checked-in Codd history mapping for Kiroku"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "hasql/hasql"
          , Schema.Dependency.ByName "pcapriotti/optparse-applicative"
          , Schema.Dependency.ByName "shinzui/pg-migrate"
          , testDep "shinzui/ephemeral-pg"
          ]
        }
      , Schema.Package::{
        , name = "kiroku-test-support"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-test-support"
        , description = Some "Shared test fixtures for Kiroku packages"
        , dependencies =
          [ Schema.Dependency.ByName "shinzui/ephemeral-pg"
          , Schema.Dependency.ByName "hasql/hasql"
          , Schema.Dependency.ByName "shinzui/pg-migrate"
          ]
        }
      , Schema.Package::{
        , name = "kiroku-cli"
        , type = Schema.PackageType.Tool
        , language = Schema.Language.Haskell
        , path = Some "kiroku-cli"
        , description = Some "Embeddable operator CLI for Kiroku"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "ekmett/lens"
          , Schema.Dependency.ByName "snoyberg/http-client"
          , Schema.Dependency.ByName "pcapriotti/optparse-applicative"
          ]
        }
      , Schema.Package::{
        , name = "kiroku-jitsurei"
        , type = Schema.PackageType.Other "Examples"
        , language = Schema.Language.Haskell
        , path = Some "kiroku-jitsurei"
        , description = Some "Worked examples (実例) for kiroku-store"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson"
          , Schema.Dependency.ByName "shinzui/ephemeral-pg"
          , Schema.Dependency.ByName "ekmett/lens"
          ]
        }
      ]
    , dependencies =
      [ "Bodigrim/tasty-bench"
      , "composewell/streamly"
      , "effectful/effectful"
      , "ekmett/lens"
      , "haskell-hvr/uuid"
      , "haskell/aeson"
      , "hasql/hasql"
      , "hasql:hasql-notifications"
      , "hasql:hasql-pool"
      , "hasql:hasql-transaction"
      , "iand675/hs-opentelemetry"
      , "MMZK1526/mmzk-typeid"
      , "mzabani/codd"
      , "nikita-volkov/contravariant-extras"
      , "pcapriotti/optparse-applicative"
      , "shinzui/ephemeral-pg"
      , "shinzui/pg-migrate"
      , "shinzui/shibuya"
      , "snoyberg/http-client"
      , "yesodweb/wai"
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "mori/improvement-requests-profile.dhall"
        , okfVersion = "0.1"
        , description = Some
            "Cross-repository improvement requests owned by Kiroku"
        }
      , Schema.OkfBundle::{
        , name = "capabilities"
        , path = "docs/capabilities"
        , profile = Some "docs/capabilities/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "What Kiroku provides today, one concept per capability, with evidence"
        }
      , Schema.OkfBundle::{
        , name = "adrs"
        , path = "docs/adr"
        , profile = Some "docs/adr/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Durable architecture decisions"
        }
      , Schema.OkfBundle::{
        , name = "bug-reports"
        , path = "docs/bug-reports"
        , profile = Some "docs/bug-reports/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "Defects in behavior Kiroku already provides, one reproduction per report"
        }
      ]
    }
