{ ... }:
{
  projectRootFile = "flake.nix";
  programs = {
    nixfmt.enable = true;
    fourmolu.enable = true;
    cabal-fmt.enable = true;
  };
}
