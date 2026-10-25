-- OKF profile descriptor written by `okf profile init`.
--
-- Profile: coordination.frictionLog
-- Source:  https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall
--
-- Existing hashes are preserved and unhashed remote value imports are frozen.
-- Local and environment inputs remain live; this is not a portable snapshot.
-- To update remote imports, remove their hashes and run `dhall freeze profile.dhall`.
-- Never hand-write a sha256 value.
let registry =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall
        sha256:a3343fd47e2cc51907ae81ccaec2f3957e048e37545df7ecb0bcac8604d4cab0

in  registry.coordination.frictionLog
