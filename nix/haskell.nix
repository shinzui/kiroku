# Dev shell, built from the haskell-nix-dev base flake's mkDevShell (GHC 9.12.4 +
# cabal + HLS). The package build lives in ../flake.module.nix.
#
# mkDevShell already provides: the GHC compiler, cabal, HLS (when withHls),
# pkg-config, and zlib, plus a LANG=en_US.UTF-8 export. Only list tools BEYOND
# those in extraNativeBuildInputs.
{
  inputs,
  lib,
  flake-parts-lib,
  ...
}:
{
  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { ... }:
    {
      options.haskellProject.extraDevPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        example = lib.literalExpression "[ pkgs.ghciwatch ]";
        description = "Extra packages to add to the dev shell.";
      };
    }
  );

  config.perSystem =
    {
      system,
      pkgs,
      config,
      ...
    }:
    let
      hsdev = inputs.haskell-nix-dev.lib.${system};

      mkProjectShell =
        ghc:
        hsdev.mkDevShell {
          inherit ghc;
          withHls = true;
          extraNativeBuildInputs = [
            # PostgreSQL
            pkgs.postgresql_18

            # Dev tools
            pkgs.just
            pkgs.process-compose
          ]
          ++ config.haskellProject.extraDevPackages;
          shellHook = ''
            ${config.pre-commit.installationScript}

            # Local PostgreSQL setup (unix socket only, no TCP)
            export PGHOST="$PWD/.pg"
            export PGDATA="$PGHOST/data"
            export PGLOG="$PGHOST/postgres.log"
            export PGDATABASE=kiroku
            export PG_CONNECTION_STRING="postgresql:///kiroku?host=$PGHOST"

            if [ ! -d "$PGDATA" ]; then
              echo "Initializing PostgreSQL 18 database..."
              mkdir -p "$PGHOST"
              initdb --auth=trust --no-locale --encoding=UTF8 -D "$PGDATA"
            fi
          '';
        };
    in
    {
      devShells.default = mkProjectShell "ghc9124";
      devShells.ghc9124 = mkProjectShell "ghc9124";
    };
}
