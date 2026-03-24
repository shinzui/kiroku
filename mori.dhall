let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/58523ea11e120f3be1c978e509d67f51311a8280/package.dhall
        sha256:e4acbb565c9f4e4b3831dabf084e50f8687dda780b7874ced90ae88d6f349f4f

in  { project =
      { name = "kiroku"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , description = Some "PostgreSQL event store in Haskell"
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , domains = [ "EventSourcing", "EventStore" ]
      , owners = [ "shinzui" ]
      , origin = Schema.Origin.Own
      }
    , repos =
      [ { name = "kiroku"
        , github = Some "shinzui/kiroku"
        , gitlab = None Text
        , git = None Text
        , localPath = None Text
        }
      ]
    , packages =
      [ { name = "kiroku-store"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kiroku-store"
        , description = Some "Core event store library using hasql"
        , lifecycle = None Schema.Lifecycle
        , visibility = Schema.Visibility.Public
        , runtime = { deployable = False, exposesApi = False }
        , runtimeEnvironment = None Schema.RuntimeEnvironment
        , dependencies = [] : List Schema.Dependency
        , docs = [] : List Schema.DocRef
        , config = [] : List Schema.ConfigItem
        }
      ]
    , bundles = [] : List Schema.PackageBundle
    , dependencies =
      [ "effectful/effectful"
      , "hasql/hasql"
      , "hasql:hasql-notifications"
      , "hasql:hasql-pool"
      , "hasql:hasql-transaction"
      , "MMZK1526/mmzk-typeid"
      , "shinzui/ephemeral-pg"
      ]
    , apis = [] : List Schema.Api
    , agents = [] : List Schema.AgentHint
    , skills = [] : List Schema.Skill
    , subagents = [] : List Schema.Subagent
    , standards = [] : List Text
    , docs = [] : List Schema.DocRef
    }
