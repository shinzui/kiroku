{
  description = "MP-12 controlled Kenshou cell payloads";
  inputs = {
    kiroku.url = "path:../..";
    kenshou = {
      url = "github:shinzui/keiro-runtime-kenshou/68f986cd7548e7da64e6eeb0444d8f5524cf5e82";
    };
    control = {
      url = "github:shinzui/kiroku/e6ea66433c5320097b6afd3c4ca56cd18ba86bd0";
      flake = false;
    };
  };
  outputs =
    inputs:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
      perSystem =
        system:
        let
          pkgs = import inputs.kenshou.inputs.nixpkgs { inherit system; };
          lib = pkgs.lib;
          hl = pkgs.haskell.lib.compose;
          base = inputs.kenshou.packages.${system}.kenshou-released.hp;
          mk =
            cohort:
            let
              source = if cohort == "released" then inputs.control else inputs.kiroku;
              hp = base.override (old: {
                overrides = lib.composeManyExtensions [
                  old.overrides
                  (import (inputs.kiroku + "/nix/haskell-overlay.nix") { inherit pkgs; })
                  (
                    hself: _:
                    (lib.genAttrs
                      [
                        "kiroku-store"
                        "kiroku-store-migrations"
                        "kiroku-test-support"
                        "kiroku-cli"
                        "kiroku-metrics"
                        "kiroku-otel"
                        "shibuya-kiroku-adapter"
                      ]
                      (
                        name:
                        hl.dontCheck (
                          hl.doJailbreak (
                            hself.callCabal2nix name (lib.cleanSourceWith {
                              name = "${name}-mp12-source";
                              src = source + "/${name}";
                              filter = _: _: true;
                            }) { }
                          )
                        )
                      )
                    )
                    // {
                      kenshou-core = hl.dontCheck (
                        hl.doJailbreak (hself.callCabal2nix "kenshou-core" (inputs.kenshou + "/kenshou-core") { })
                      );
                      shibuya-core = base.shibuya-core;
                      kenshou-mp12-cell = hl.dontCheck (
                        hl.doJailbreak (
                          hself.callCabal2nix "kenshou-mp12-cell" (pkgs.runCommand "kenshou-mp12-cell-source" { } ''
                            cp -r ${inputs.self} "$out"
                            chmod -R u+w "$out"
                            mkdir -p "$out/src/Kenshou/Suite/Kiroku/Bench"
                            cp ${inputs.kenshou}/kenshou-kiroku/src/Kenshou/Suite/Kiroku/Bench/Hardening.hs "$out/src/Kenshou/Suite/Kiroku/Bench/Hardening.hs"
                          '') { }
                        )
                      );
                    }
                  )
                ];
              });
              descriptorFile = inputs.self + "/cohort/${cohort}.json";
              descriptor = builtins.fromJSON (builtins.readFile descriptorFile);
              identity = import (inputs.kenshou + "/nix/kenshou/identity.nix") {
                inputs = inputs.kenshou.inputs;
                inherit
                  pkgs
                  hp
                  descriptor
                  cohort
                  ;
                lock = {
                  descriptorSha256 = builtins.hashFile "sha256" descriptorFile;
                };
                variant = "default";
                localNames = [
                  "kenshou-core"
                  "kenshou-measure"
                  "kenshou-remote"
                  "kenshou-mp12-cell"
                ];
              };
              selected = hl.overrideCabal (_: {
                configureFlags = [ (if cohort == "released" then "-flegacy-topology" else "-f-legacy-topology") ];
              }) hp.kenshou-mp12-cell;
              executable = hl.justStaticExecutables (
                hl.disableLibraryProfiling (hl.disableSharedLibraries (hl.disableSharedExecutables selected))
              );
            in
            pkgs.runCommand "kiroku-mp12-${cohort}"
              {
                nativeBuildInputs = [
                  pkgs.makeWrapper
                  pkgs.removeReferencesTo
                ];
                disallowedRequisites = [ hp.ghc ];
                meta.mainProgram = "kenshou";
                passthru = {
                  cohortIdentity = identity.value;
                  payloadIdentity = identity.payloadValue;
                };
              }
              ''
                mkdir -p "$out/bin" "$out/share/kenshou"
                cp "${executable}/bin/kenshou" "$out/bin/kenshou"
                chmod u+w "$out/bin/kenshou"
                remove-references-to -t ${executable} -t ${hp.ghc} -t ${hp.kenshou-core} -t ${hp.pg-migrate} "$out/bin/kenshou"
                cp "${identity.file}" "$out/share/kenshou/cohort-identity.json"
                cp "${identity.payloadFile}" "$out/share/kenshou/payload-identity.json"
                wrapProgram "$out/bin/kenshou" \
                  --set-default KENSHOU_COHORT_IDENTITY "$out/share/kenshou/cohort-identity.json" \
                  --set-default KENSHOU_PAYLOAD_IDENTITY "$out/share/kenshou/payload-identity.json" \
                  --set-default KENSHOU_HARNESS_REVISION "${inputs.self.rev or "dirty"}" \
                  --set-default KENSHOU_HARNESS_DIRTY "${if inputs.self ? rev then "false" else "true"}" \
                  --prefix PATH : "${pkgs.postgresql_18}/bin"
              '';
        in
        {
          kenshou-released = mk "released";
          kenshou-head = mk "head";
        };
    in
    {
      packages = builtins.listToAttrs (
        map (system: {
          name = system;
          value = perSystem system;
        }) systems
      );
    };
}
