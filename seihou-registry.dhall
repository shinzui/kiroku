{ repoName = "kiroku"
, repoDescription = Some "PostgreSQL append-only event store in Haskell"
, modules =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
, recipes =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
, blueprints =
  [ { name = "kiroku-upgrade"
    , version = Some "0.1.0"
    , path = "blueprints/kiroku-upgrade"
    , description = Some
        "Upgrade guidance for Kiroku consumers: one agent-guided edge per released version window that needs judgement work"
    , tags =
      [ "haskell", "postgresql", "event-sourcing", "kiroku", "migration" ]
    }
  ]
, prompts =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
}
