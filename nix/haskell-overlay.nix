{ pkgs }:
let
  inherit (pkgs.haskell.lib.compose) doJailbreak dontCheck;
in
final: prev: {
  haxl = dontCheck (doJailbreak prev.haxl);

  codd = dontCheck (
    doJailbreak (
      final.callCabal2nix "codd" (pkgs.fetchFromGitHub {
        owner = "mzabani";
        repo = "codd";
        rev = "29478ff469b1c0466a7d126d64ab3dc1dbff4756";
        hash = "sha256-7MKlR3oepOwlBwiEpzz3NFepEYGqROT5RrYoe/vvBKM=";
      }) { }
    )
  );

  hasql-notifications = dontCheck (
    doJailbreak (
      final.callHackageDirect {
        pkg = "hasql-notifications";
        ver = "0.2.5.0";
        sha256 = "sha256-iLw/CEQclpzJI9ep47Mgrzkin3oXdQwL4+UEH5/NU4Y=";
      } { }
    )
  );

  shibuya-core =
    let
      src = pkgs.fetchurl {
        url = "https://hackage.haskell.org/package/shibuya-core-0.5.0.0/shibuya-core-0.5.0.0.tar.gz";
        hash = "sha256-24Af101mkjH+7uuRUw/cQMCz3kJzeUZ/DpcNNpbtI6k=";
      };

      patched = pkgs.runCommand "shibuya-core-0.5.0.0-patched" { } ''
        mkdir -p $out
        tar -xzf ${src} --strip-components=1 -C $out
        chmod -R u+w $out
        ${pkgs.gnused}/bin/sed -i 's/^cabal-version: *3\.14/cabal-version: 3.4/' $out/shibuya-core.cabal
      '';
    in
    dontCheck (doJailbreak (final.callCabal2nix "shibuya-core" patched { }));

  kiroku-test-support = dontCheck (
    doJailbreak (final.callCabal2nix "kiroku-test-support" ../kiroku-test-support { })
  );

  kiroku-store = dontCheck (
    doJailbreak (
      final.callCabal2nix "kiroku-store" ../kiroku-store {
        inherit (final) kiroku-test-support;
      }
    )
  );

  kiroku-store-migrations = dontCheck (
    doJailbreak (final.callCabal2nix "kiroku-store-migrations" ../kiroku-store-migrations { })
  );

  shibuya-kiroku-adapter = dontCheck (
    doJailbreak (
      final.callCabal2nix "shibuya-kiroku-adapter" ../shibuya-kiroku-adapter {
        inherit (final) kiroku-test-support;
      }
    )
  );

  kiroku-otel = dontCheck (doJailbreak (final.callCabal2nix "kiroku-otel" ../kiroku-otel { }));
}
