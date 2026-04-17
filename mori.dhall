let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/ad9960dd3dd3b33eadd45f17bcf430b0e1ec13bc/package.dhall
        sha256:83aa1432e98db5da81afde4ab2057dcab7ce4b2e883d0bc7f16c7d25b917dd0c

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
      ]
    , dependencies =
      [ "effectful/effectful"
      , "hasql/hasql"
      , "hasql:hasql-notifications"
      , "hasql:hasql-pool"
      , "hasql:hasql-transaction"
      , "MMZK1526/mmzk-typeid"
      , "shinzui/ephemeral-pg"
      , "shinzui/shibuya"
      ]
    }
