let S =
      https://raw.githubusercontent.com/shinzui/seihou-schema/49ff1e5b353b171b1b52946f478623ee4423ea93/package.dhall
        sha256:cadacb688dd31ec39feb7f2fe599973a1ad58ef8fcc8ed1100bf3da22a1222cb

in  S.Blueprint::{
    , name = "kiroku-upgrade"
    , version = Some "0.1.0"
    , description = Some
        "Upgrade guidance for projects consuming Kiroku, the PostgreSQL append-only event store. One edge per released version window that needs judgement work: source changes across call sites Kiroku cannot see, and read-only classification of databases whose migration ledger needs an operator-applied fixup before the next migrate."
    , prompt = ./prompt.md as Text
    , versionProbe = Some
        "jq -r '.\"install-plan\"[] | select(.\"pkg-name\"==\"kiroku-store\") | .\"pkg-version\"' dist-newstyle/cache/plan.json 2>/dev/null | sort -u | tail -1 | grep ."
    , allowedTools = Some [ "Bash(cabal *)", "Bash(psql *)", "Bash(rg *)" ]
    , migrations =
      [ S.BlueprintMigration::{
        , from = "0.7.0.1"
        , to = "0.8.0.0"
        , prompt = ./migrations/0-7-to-0-8.md as Text
        }
      ]
    , tags = [ "haskell", "postgresql", "event-sourcing", "kiroku", "migration" ]
    }
