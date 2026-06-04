# treefmt-nix as a flake-parts module (wires `nix fmt` + a treefmt flake check).
# fourmolu and cabal-fmt are taken from the ghc9124 package set so they match the
# project's compiler. Preserves the project's existing formatter set:
# nixfmt + fourmolu + cabal-fmt.
{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem =
    { pkgs, ... }:
    let
      haskellPkgs = pkgs.haskell.packages.ghc9124;
    in
    {
      treefmt = {
        projectRootFile = "flake.nix";
        programs.nixfmt.enable = true;
        programs.fourmolu.enable = true;
        programs.fourmolu.package = haskellPkgs.fourmolu;
        programs.cabal-fmt.enable = true;
        programs.cabal-fmt.package = haskellPkgs.cabal-fmt;
      };
    };
}
