{
  description = "Kiroku — PostgreSQL event store in Haskell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    haskell-nix.url = "github:shinzui/haskell-nix";
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      haskell-nix,
      pre-commit-hooks,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        ghcVersion = "ghc9122";

        haskellPackages = pkgs.haskell.packages.${ghcVersion}.override {
          overrides =
            pkgs.lib.composeExtensions (haskell-nix.lib.haskellExtension pkgs.haskell.lib.compose pkgs)
              (import ./nix/haskell-overlay.nix { inherit pkgs; });
        };

        treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

        pre-commit-check = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            treefmt = {
              enable = true;
              package = treefmtEval.config.build.wrapper;
            };
          };
        };

        postgresql = pkgs.postgresql_18;
      in
      {
        packages = {
          kiroku-store = haskellPackages.kiroku-store;
          kiroku-store-migrations = haskellPackages.kiroku-store-migrations;
          shibuya-kiroku-adapter = haskellPackages.shibuya-kiroku-adapter;
          kiroku-otel = haskellPackages.kiroku-otel;
          default = haskellPackages.kiroku-store;
        };

        checks = {
          formatting = treefmtEval.config.build.check self;
          inherit pre-commit-check;
        };

        formatter = treefmtEval.config.build.wrapper;

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            # Haskell tooling
            (haskellPackages.ghcWithPackages (ps: [
              ps.haskell-language-server
            ]))
            pkgs.cabal-install

            # PostgreSQL
            postgresql

            # Native deps for hasql/libpq
            pkgs.pkg-config
            pkgs.zlib

            # Dev tools
            pkgs.just
            pkgs.process-compose
          ];

          shellHook = ''
            ${pre-commit-check.shellHook}

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
      }
    );
}
