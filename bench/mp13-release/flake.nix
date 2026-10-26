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
        source: namespaceEnabled:
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
                    hl.doJailbreak (
                      (if namespaceEnabled then hl.enableCabalFlag "category-namespace" else x: x) (
                        self.callCabal2nix "inspection-probe" inputs.self { }
                      )
                    )
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
      candidate = build inputs.candidate false;
      namespaceCandidate = build inputs.candidate true;
      control = build inputs.control false;
    in
    {
      packages.${system} = {
        observed = pkgs.writeShellApplication {
          name = "inspection-observed-cell";
          runtimeInputs = [
            pkgs.python3
            pkgs.postgresql_18
          ];
          text =
            let
              original = builtins.storePath (builtins.fromJSON (
                builtins.readFile ./validation-2026-10-11/payload.json
              )).storePath;
            in
            ''
              exec python3 ${./observer-cell/observe.py} ${original}/bin/inspection-cell "$@"
            '';
        };
        candidate = candidate.probe;
        control = control.probe;
        namespace-observed = pkgs.writeShellApplication {
          name = "inspection-namespace-observed-cell";
          runtimeInputs = [
            pkgs.python3
            pkgs.postgresql_18
          ];
          text = ''
            exec python3 ${./observer-cell/observe.py} ${
              inputs.self.packages.${system}.namespace
            }/bin/inspection-namespace-cell "$@"
          '';
        };
        namespace = pkgs.writeShellApplication {
          name = "inspection-namespace-cell";
          runtimeInputs = [
            pkgs.python3
            pkgs.postgresql_18
          ];
          text = ''
            export EP54_NAMESPACE=1
            exec python3 ${./cell-entry.py} ${control.probe}/bin/inspection-probe ${namespaceCandidate.probe}/bin/inspection-probe ${candidate.gate}/bin/inspection-workload-gate "$@"
          '';
        };
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
