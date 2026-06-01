let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/f53517e1a532275569bb14a452359f11c3e02c03/package.dhall
        sha256:3b79aae9216456678300441ca8616b64a4b4fa520a1286dfcc418f60899d5d4a

in  Schema.Project::{ project =
      Schema.ProjectIdentity::{ name = "kiroku"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , description = Some "PostgreSQL event store in Haskell"
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , domains = [ "EventSourcing", "EventStore" ]
      , owners = [ "shinzui" ]
      }
    , repos =
      [ Schema.Repo::{ name = "kiroku"
        , github = Some "shinzui/kiroku"
        }
      ]
    , packages =
      [ Schema.Package::{ name = "kiroku-store"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-store"
        , description = Some "Core event store library using hasql"
        }
      , Schema.Package::{ name = "shibuya-kiroku-adapter"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shibuya-kiroku-adapter"
        , description = Some "Shibuya adapter for Kiroku event store subscriptions"
        }
      , Schema.Package::{ name = "kiroku-otel"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-otel"
        , description = Some "OpenTelemetry W3C trace-context helpers for Kiroku event metadata"
        }
      , Schema.Package::{ name = "kiroku-metrics"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-metrics"
        , description = Some "Metrics, health, and event-streaming HTTP endpoints for Kiroku"
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
      , "shinzui/shibuya"
      ]
    }
