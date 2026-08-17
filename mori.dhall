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

let internalDep =
      \(name : Text) ->
        Schema.Dependency.WithAugmentation
          { name
          , extraDocs = [] : List Schema.DocRef.Type
          , localPathOverride = None Text
          , kind = Some Schema.DependencyKind.Internal
          , source = Some Schema.DependencySource.Local
          , scope = Some Schema.DependencyScope.Regular
          , versionConstraint = None Text
          }

let internalTestDep =
      \(name : Text) ->
        Schema.Dependency.WithAugmentation
          { name
          , extraDocs = [] : List Schema.DocRef.Type
          , localPathOverride = None Text
          , kind = Some Schema.DependencyKind.Internal
          , source = Some Schema.DependencySource.Local
          , scope = Some Schema.DependencyScope.Test
          , versionConstraint = None Text
          }

let projectRef =
      \(namespace : Text) ->
      \(name : Text) ->
        Schema.MoriRef::{ namespace, name }

let packageRef =
      \(namespace : Text) ->
      \(name : Text) ->
      \(package : Text) ->
        Schema.MoriRef::{
        , namespace
        , name
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some package
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
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "nikita-volkov/contravariant-extras"
          , Schema.Dependency.ByName "effectful/effectful:effectful-core"
          , Schema.Dependency.ByName "ekmett/lens:generic-lens"
          , Schema.Dependency.ByName "ekmett/lens:lens"
          , Schema.Dependency.ByName "hasql/hasql:hasql"
          , Schema.Dependency.ByName "hasql/hasql:hasql-notifications"
          , Schema.Dependency.ByName "hasql/hasql:hasql-pool"
          , Schema.Dependency.ByName "hasql/hasql:hasql-transaction"
          , Schema.Dependency.ByName "MMZK1526/mmzk-typeid"
          , Schema.Dependency.ByName "composewell/streamly:streamly-core"
          , Schema.Dependency.ByName "haskell-hvr/uuid:uuid"
          , testDep "shinzui/ephemeral-pg"
          , testDep "effectful/effectful:effectful"
          , testDep "composewell/streamly:streamly"
          , testDep "shinzui/shibuya:shibuya-core"
          , testDep "Bodigrim/tasty-bench"
          , internalTestDep "shinzui/kiroku:kiroku-test-support"
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
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "effectful/effectful:effectful-core"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-api"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-semantic-conventions"
          , Schema.Dependency.ByName "shinzui/shibuya:shibuya-core"
          , Schema.Dependency.ByName "composewell/streamly:streamly-core"
          , Schema.Dependency.ByName "haskell-hvr/uuid:uuid"
          , internalDep "shinzui/kiroku:kiroku-store"
          , testDep "shinzui/ephemeral-pg"
          , testDep "effectful/effectful:effectful"
          , testDep "ekmett/lens:generic-lens"
          , testDep "ekmett/lens:lens"
          , testDep "hasql/hasql:hasql"
          , testDep "hasql/hasql:hasql-pool"
          , internalTestDep "shinzui/kiroku:kiroku-test-support"
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
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "ekmett/lens:generic-lens"
          , Schema.Dependency.ByName "ekmett/lens:lens"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-api"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-propagator-w3c"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-semantic-conventions"
          , internalDep "shinzui/kiroku:kiroku-store"
          , testDep "shinzui/ephemeral-pg"
          , testDep "hasql/hasql:hasql-pool"
          , testDep
              "iand675/hs-opentelemetry:hs-opentelemetry-exporter-in-memory"
          , testDep "iand675/hs-opentelemetry:hs-opentelemetry-sdk"
          , testDep "haskell-hvr/uuid:uuid"
          , internalTestDep "shinzui/kiroku:kiroku-test-support"
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
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "hasql/hasql:hasql"
          , Schema.Dependency.ByName "hasql/hasql:hasql-pool"
          , Schema.Dependency.ByName "snoyberg/http-client:http-client"
          , Schema.Dependency.ByName "ekmett/lens:generic-lens"
          , Schema.Dependency.ByName "ekmett/lens:lens"
          , Schema.Dependency.ByName "haskell-hvr/uuid:uuid"
          , Schema.Dependency.ByName "yesodweb/wai:wai"
          , Schema.Dependency.ByName "yesodweb/wai:wai-websockets"
          , Schema.Dependency.ByName "yesodweb/wai:warp"
          , internalDep "shinzui/kiroku:kiroku-store"
          , internalDep "shinzui/kiroku:kiroku-cli"
          , internalTestDep "shinzui/kiroku:kiroku-test-support"
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
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "hasql/hasql:hasql"
          , Schema.Dependency.ByName "pcapriotti/optparse-applicative"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate-cli"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate-embed"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate-import-codd"
          , testDep "shinzui/ephemeral-pg"
          , testDep "shinzui/pg-migrate:pg-migrate-test-support"
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
          , Schema.Dependency.ByName "hasql/hasql:hasql"
          , Schema.Dependency.ByName "hasql/hasql:hasql-pool"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate"
          , internalDep "shinzui/kiroku:kiroku-store-migrations"
          ]
        }
      , Schema.Package::{
        , name = "kiroku-cli"
        , type = Schema.PackageType.Tool
        , language = Schema.Language.Haskell
        , path = Some "kiroku-cli"
        , description = Some "Embeddable operator CLI for Kiroku"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "ekmett/lens:generic-lens"
          , Schema.Dependency.ByName "ekmett/lens:lens"
          , Schema.Dependency.ByName "snoyberg/http-client:http-client"
          , Schema.Dependency.ByName "snoyberg/http-client:http-client-tls"
          , Schema.Dependency.ByName "pcapriotti/optparse-applicative"
          , internalDep "shinzui/kiroku:kiroku-store"
          , internalTestDep "shinzui/kiroku:kiroku-test-support"
          ]
        }
      , Schema.Package::{
        , name = "kiroku-jitsurei"
        , type = Schema.PackageType.Other "Examples"
        , language = Schema.Language.Haskell
        , path = Some "kiroku-jitsurei"
        , description = Some "Worked examples (実例) for kiroku-store"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "shinzui/ephemeral-pg"
          , Schema.Dependency.ByName "ekmett/lens:generic-lens"
          , Schema.Dependency.ByName "ekmett/lens:lens"
          , internalDep "shinzui/kiroku:kiroku-store"
          ]
        }
      ]
    , dependencies =
      [ "Bodigrim/tasty-bench"
      , "composewell/streamly:streamly"
      , "composewell/streamly:streamly-core"
      , "effectful/effectful:effectful"
      , "effectful/effectful:effectful-core"
      , "ekmett/lens:generic-lens"
      , "ekmett/lens:lens"
      , "haskell-hvr/uuid:uuid"
      , "haskell/aeson:aeson"
      , "hasql/hasql:hasql"
      , "hasql/hasql:hasql-notifications"
      , "hasql/hasql:hasql-pool"
      , "hasql/hasql:hasql-transaction"
      , "iand675/hs-opentelemetry:hs-opentelemetry-api"
      , "iand675/hs-opentelemetry:hs-opentelemetry-exporter-in-memory"
      , "iand675/hs-opentelemetry:hs-opentelemetry-propagator-w3c"
      , "iand675/hs-opentelemetry:hs-opentelemetry-sdk"
      , "iand675/hs-opentelemetry:hs-opentelemetry-semantic-conventions"
      , "MMZK1526/mmzk-typeid"
      , "mzabani/codd"
      , "nikita-volkov/contravariant-extras"
      , "pcapriotti/optparse-applicative"
      , "shinzui/ephemeral-pg"
      , "shinzui/pg-migrate:pg-migrate"
      , "shinzui/pg-migrate:pg-migrate-cli"
      , "shinzui/pg-migrate:pg-migrate-embed"
      , "shinzui/pg-migrate:pg-migrate-import-codd"
      , "shinzui/pg-migrate:pg-migrate-test-support"
      , "shinzui/shibuya:shibuya-core"
      , "snoyberg/http-client:http-client"
      , "snoyberg/http-client:http-client-tls"
      , "yesodweb/wai:wai"
      , "yesodweb/wai:wai-websockets"
      , "yesodweb/wai:warp"
      ]
    , dependencyRefs =
      [ projectRef "Bodigrim" "tasty-bench"
      , packageRef "composewell" "streamly" "streamly"
      , packageRef "composewell" "streamly" "streamly-core"
      , packageRef "effectful" "effectful" "effectful"
      , packageRef "effectful" "effectful" "effectful-core"
      , packageRef "ekmett" "lens" "generic-lens"
      , packageRef "ekmett" "lens" "lens"
      , packageRef "haskell-hvr" "uuid" "uuid"
      , packageRef "haskell" "aeson" "aeson"
      , packageRef "hasql" "hasql" "hasql"
      , packageRef "hasql" "hasql" "hasql-notifications"
      , packageRef "hasql" "hasql" "hasql-pool"
      , packageRef "hasql" "hasql" "hasql-transaction"
      , packageRef "iand675" "hs-opentelemetry" "hs-opentelemetry-api"
      , packageRef
          "iand675"
          "hs-opentelemetry"
          "hs-opentelemetry-exporter-in-memory"
      , packageRef "iand675" "hs-opentelemetry" "hs-opentelemetry-propagator-w3c"
      , packageRef "iand675" "hs-opentelemetry" "hs-opentelemetry-sdk"
      , packageRef
          "iand675"
          "hs-opentelemetry"
          "hs-opentelemetry-semantic-conventions"
      , projectRef "MMZK1526" "mmzk-typeid"
      , projectRef "mzabani" "codd"
      , projectRef "nikita-volkov" "contravariant-extras"
      , projectRef "pcapriotti" "optparse-applicative"
      , projectRef "shinzui" "ephemeral-pg"
      , packageRef "shinzui" "pg-migrate" "pg-migrate"
      , packageRef "shinzui" "pg-migrate" "pg-migrate-cli"
      , packageRef "shinzui" "pg-migrate" "pg-migrate-embed"
      , packageRef "shinzui" "pg-migrate" "pg-migrate-import-codd"
      , packageRef "shinzui" "pg-migrate" "pg-migrate-test-support"
      , packageRef "shinzui" "shibuya" "shibuya-core"
      , packageRef "snoyberg" "http-client" "http-client"
      , packageRef "snoyberg" "http-client" "http-client-tls"
      , packageRef "yesodweb" "wai" "wai"
      , packageRef "yesodweb" "wai" "wai-websockets"
      , packageRef "yesodweb" "wai" "warp"
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
