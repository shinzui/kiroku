{ pkgs }:
let
  inherit (pkgs.haskell.lib.compose) doJailbreak dontCheck overrideCabal;
  pgMigrateSrc = pkgs.fetchFromGitHub {
    owner = "shinzui";
    repo = "pg-migrate";
    rev = "v1.0.0.0";
    hash = "sha256-cxDPGqheAlDPniZPOuzz9JpKEb39ejdH+8RL8VN8A+w=";
  };
in
final: prev: {
  haxl = dontCheck (doJailbreak prev.haxl);

  # wai-websockets' optional `wai-websockets-example` executable (cabal flag
  # `example`, default off) depends on wai-app-static, which fails to build in
  # this nixpkgs Haskell set (a memory/crypton `ByteArrayAccess (Digest MD5)`
  # skew). cabal2nix lists those executable deps unconditionally, so nix realizes
  # wai-app-static as a build input even though the example is never compiled.
  # Drop the executable deps so the (fine) library builds, letting kiroku-metrics
  # (EP-3, which depends on wai-websockets) build under nix.
  wai-websockets = overrideCabal (_: {
    executableHaskellDepends = [ ];
  }) prev.wai-websockets;

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

  pg-migrate = dontCheck (final.callCabal2nix "pg-migrate" "${pgMigrateSrc}/pg-migrate" { });

  pg-migrate-embed = dontCheck (
    final.callCabal2nix "pg-migrate-embed" "${pgMigrateSrc}/pg-migrate-embed" { }
  );

  pg-migrate-cli = dontCheck (
    final.callCabal2nix "pg-migrate-cli" "${pgMigrateSrc}/pg-migrate-cli" { }
  );

  pg-migrate-import-codd = dontCheck (
    final.callCabal2nix "pg-migrate-import-codd" "${pgMigrateSrc}/pg-migrate-import-codd" { }
  );

  pg-migrate-test-support = dontCheck (
    final.callCabal2nix "pg-migrate-test-support" "${pgMigrateSrc}/pg-migrate-test-support" { }
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

  hs-opentelemetry-api-types = dontCheck (
    doJailbreak (
      final.callHackageDirect {
        pkg = "hs-opentelemetry-api-types";
        ver = "1.0.0.0";
        sha256 = "sha256-9ByP41wlV45TMCqbyyVpwejQDi5fsG0+j8bMk8ORLw8=";
      } { }
    )
  );

  thread-utils-context = dontCheck (
    doJailbreak (
      final.callHackageDirect {
        pkg = "thread-utils-context";
        ver = "0.4.1.0";
        sha256 = "sha256-etbB97HVjo0TL8s09wsgxFoKa8DnNbam0ToPl61jsiw=";
      } { }
    )
  );

  hs-opentelemetry-semantic-conventions = dontCheck (
    doJailbreak (
      final.callHackageDirect {
        pkg = "hs-opentelemetry-semantic-conventions";
        ver = "1.40.0.0";
        sha256 = "sha256-7cIC9dTrd5bJjAsiEyyupi1xSZyc17FpjbACnm0p5ik=";
      } { }
    )
  );

  hs-opentelemetry-api = dontCheck (
    doJailbreak (
      final.callHackageDirect {
        pkg = "hs-opentelemetry-api";
        ver = "1.0.0.0";
        sha256 = "sha256-COhj9Ms1eu1Gt9wTC21oQ37k6vJ9mxlJvYpHtvXff6A=";
      } { }
    )
  );

  hs-opentelemetry-propagator-w3c = dontCheck (
    doJailbreak (
      final.callHackageDirect {
        pkg = "hs-opentelemetry-propagator-w3c";
        ver = "1.0.0.0";
        sha256 = "sha256-p8d2Tx8bCVRk6hps8k0qAg/L2gdBVoYuLYJbTzTbI3s=";
      } { }
    )
  );

  shibuya-core =
    let
      src = pkgs.fetchurl {
        url = "https://hackage.haskell.org/package/shibuya-core-0.8.0.1/shibuya-core-0.8.0.1.tar.gz";
        hash = "sha256-Sx9Kn9AUjzMjKzJ5osbzlwhdhv6pT0hRW2kxNzuk7WQ=";
      };

      patched = pkgs.runCommand "shibuya-core-0.8.0.1-patched" { } ''
        mkdir -p $out
        tar -xzf ${src} --strip-components=1 -C $out
        chmod -R u+w $out
        ${pkgs.gnused}/bin/sed -i 's/^cabal-version: *3\.1[24]/cabal-version: 3.4/' $out/shibuya-core.cabal
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

  kiroku-cli = dontCheck (
    doJailbreak (
      final.callCabal2nix "kiroku-cli" ../kiroku-cli {
        inherit (final) kiroku-store kiroku-test-support;
      }
    )
  );

  kiroku-metrics = dontCheck (
    doJailbreak (
      overrideCabal
        (_: {
          # The self-verifying example executable (cabal flag `example`, on by
          # default so `cabal run kiroku-metrics-example` works in the dev shell)
          # depends on kiroku-test-support -> ephemeral-pg, which has no buildable
          # source in this nixpkgs Haskell set. Turn the flag off and drop the
          # example's deps so the library builds under nix.
          configureFlags = [ "-f-example" ];
          executableHaskellDepends = [ ];
        })
        (
          final.callCabal2nix "kiroku-metrics" ../kiroku-metrics {
            inherit (final) kiroku-cli kiroku-store kiroku-test-support;
          }
        )
    )
  );
}
