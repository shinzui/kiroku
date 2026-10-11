{
  description = "MP13 isolated original-control inspection validation";
  inputs = {
    candidate.url = "github:shinzui/kiroku/109d58f57dbd5757ad55792474d046a37cc2e87d";
    candidate.flake = false;
    control.url = "github:shinzui/kiroku/364ffa82136fcfc83d39ead1234abffaf500844b";
    control.flake = false;
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
      build =
        source:
        let
          hp = base.override (old: {
            overrides = lib.composeManyExtensions [
              old.overrides
              (import (inputs.candidate + "/nix/haskell-overlay.nix") { inherit pkgs; })
              (
                self: _:
                (lib.genAttrs [
                  "kiroku-store"
                  "kiroku-store-migrations"
                  "kiroku-test-support"
                  "kiroku-cli"
                  "kiroku-metrics"
                ] (name: hl.dontCheck (hl.doJailbreak (self.callCabal2nix name (source + "/${name}") { }))))
                // {
                  inspection-probe = hl.dontCheck (
                    hl.doJailbreak (self.callCabal2nix "inspection-probe" inputs.self { })
                  );
                  inspection-workload-gate = hl.dontCheck (
                    hl.doJailbreak (
                      self.callCabal2nix "inspection-workload-gate" (pkgs.runCommand "inspection-workload-gate-source" { }
                        ''
                          mkdir -p "$out/Kiroku/Test"
                          cp ${./gate/inspection-workload-gate.cabal} "$out/"
                          cp ${./gate/RemotePostgres.hs} "$out/Kiroku/Test/Postgres.hs"
                          cp ${inputs.candidate}/kiroku-store/bench/RegressionGate.hs "$out/Main.hs"
                        ''
                      ) { }
                    )
                  );
                }
              )
            ];
          });
        in
        {
          probe = hl.justStaticExecutables hp.inspection-probe;
          gate = hl.justStaticExecutables hp.inspection-workload-gate;
        };
      candidate = build inputs.candidate;
      control = build inputs.control;
    in
    {
      packages.${system} = {
        candidate = candidate.probe;
        control = control.probe;
        default = pkgs.writeShellApplication {
          name = "inspection-cell";
          runtimeInputs = [
            pkgs.python3
            pkgs.postgresql_18
          ];
          text = ''
            exec python3 ${./cell-entry.py} ${control.probe}/bin/inspection-probe ${candidate.probe}/bin/inspection-probe ${candidate.gate}/bin/inspection-workload-gate "$@"
          '';
        };
      };
    };
}
