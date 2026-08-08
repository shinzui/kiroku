let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/b85081a0e935a976202fd7a1227f8b93e2cbeb23/package.dhall
        sha256:1501e5c3e55e78d2a58774e2f8aefda20e32b948fa7caf639473fce90929464b

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
      ]
    }
