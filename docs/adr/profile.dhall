--| Shared ADR profile. Bump the tag and semantic hash together when upgrading.
--
-- This descriptor is a plain pinned import. It carries no override, because
-- v0.8.0 folded the one this file used to layer into the upstream profile:
-- `supersedes`, `supersededBy`, and `originatingPlan` are `optional` as
-- shipped, so the local reclassification became a no-op. If you are upgrading a
-- descriptor installed at v0.7.0, delete the `//` override it carries; deleting
-- it changes nothing about which documents pass.
--
-- The profile targets Open Knowledge Format v0.2. Every concept must carry a
-- `generated` mapping whose `by` is an OKF §7 actor (`human:<id>`,
-- `process:<id>`, or `<producer>/<version>`), and the bundle root must declare
-- `okf_version: "0.2"` -- write it with
-- `okf index docs/adr --write --okf-version 0.2`. The superseded v0.1
-- `timestamp` key is `optional`: keep it if you have it, its format is still
-- checked, and its absence is never reported.
--
-- The integrity hash below was computed by `dhall freeze` against the real
-- v0.8.0 tag. When bumping to a future release, change the tag, delete the hash
-- line, and re-run:
--
--     dhall freeze blueprints/adopt-architecture-decisions/files/architecture-decisions-profile.dhall
--
-- Never hand-write a `sha256:` value, and never delete a hash from a frozen
-- import to make it resolve.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.8.0/package.dhall
        sha256:0d66bb25b99e74a10598be06eef30356f331ff9c1c557e8578daf48cbd50d8d3

in  Profiles.documentation.architectureDecisions
