{
  description = "Plan 97 original public-runner benchmarks on a verification cell";
  inputs = {
    kiroku.url = "path:../..";
    kiroku.flake = false;
    kenshou.url = "github:shinzui/keiro-runtime-kenshou/31275c01a5e011d13465f4ef9a9c6abfd4b5e9df";
  };
  outputs =
    inputs:
    let
      system = "x86_64-linux";
      pkgs = import inputs.kenshou.inputs.nixpkgs { inherit system; };
      lib = pkgs.lib;
      hl = pkgs.haskell.lib.compose;
      base = inputs.kenshou.packages.${system}.kenshou-released.hp;
      hp = base.override (old: {
        overrides = lib.composeManyExtensions [
          old.overrides
          (import (inputs.kiroku + "/nix/haskell-overlay.nix") { inherit pkgs; })
          (
            self: _:
            (lib.genAttrs [ "kiroku-store" "kiroku-store-migrations" "kiroku-test-support" ] (
              name: hl.dontCheck (hl.doJailbreak (self.callCabal2nix name (inputs.kiroku + "/${name}") { }))
            ))
            // {
              stream-head-cell = hl.dontCheck (
                hl.doJailbreak (
                  self.callCabal2nix "stream-head-cell" (pkgs.runCommand "stream-head-cell-source" { } ''
                    cp -r ${inputs.self} "$out"
                    chmod -R u+w "$out"
                    cp ${inputs.kiroku}/kiroku-store/bench/StreamHeadCost.hs "$out/src/StreamHeadCost.hs"
                    cp ${inputs.kiroku}/kiroku-store/bench/RegressionGate.hs "$out/src/RegressionGate.hs"
                  '') { }
                )
              );
            }
          )
        ];
      });
      executable = hl.justStaticExecutables hp.stream-head-cell;
    in
    {
      packages.${system}.default = pkgs.writeShellApplication {
        name = "stream-head-cell";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          exec python3 ${./entry.py} ${executable}/bin/stream-head-cost ${executable}/bin/workload-gate "$@"
        '';
      };
    };
}
