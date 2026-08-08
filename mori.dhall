let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/027403783777cbce0e87eb660a0b3d8119ebe8d2/package.dhall
        sha256:d29ca03286afa92b7589d09b7a6d98ad8e39d11b255a4b8751f3327b0722fba3

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
        }
      , Schema.Package::{
        , name = "shibuya-kiroku-adapter"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-kiroku-adapter"
        , description = Some
            "Shibuya adapter for Kiroku event store subscriptions"
        }
      , Schema.Package::{
        , name = "kiroku-otel"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-otel"
        , description = Some
            "OpenTelemetry W3C trace-context helpers for Kiroku event metadata"
        }
      , Schema.Package::{
        , name = "kiroku-metrics"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-metrics"
        , description = Some
            "Metrics, health, and event-streaming HTTP endpoints for Kiroku"
        }
      , Schema.Package::{
        , name = "kiroku-store-migrations"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-store-migrations"
        , description = Some
            "Native pg-migrate component and checked-in Codd history mapping for Kiroku"
        }
      ]
    , dependencies =
      [ "effectful/effectful"
      , "hasql/hasql"
      , "hasql:hasql-notifications"
      , "hasql:hasql-pool"
      , "hasql:hasql-transaction"
      , "iand675/hs-opentelemetry"
      , "MMZK1526/mmzk-typeid"
      , "shinzui/ephemeral-pg"
      , "shinzui/pg-migrate"
      , "shinzui/shibuya"
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
      ]
    }
