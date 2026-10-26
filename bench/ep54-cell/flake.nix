{
  description = "Plan 54 controlled Kenshou cell payloads";
  inputs = {
    kiroku.url = "github:shinzui/kiroku/94c2839f4b9a51bff2bfead57b8e587389a7875f";
    kiroku.flake = false;
    kenshou = {
      url = "github:shinzui/keiro-runtime-kenshou/2129bb917da811ef1e90198d91db873cc8d05b7b";
    };
    control = {
      url = "github:shinzui/kiroku/364ffa82136fcfc83d39ead1234abffaf500844b";
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
            cohort: stallDiagnostics:
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
                        "kiroku-test-support"
                        "kiroku-metrics"
                      ]
                      (
                        name:
                        hl.dontCheck (
                          hl.doJailbreak (
                            hself.callCabal2nix name (lib.cleanSourceWith {
                              name = "${name}-ep54-source";
                              src = source + "/${name}";
                              filter = _: _: true;
                            }) { }
                          )
                        )
                      )
                    )
                    // {
                      strict-mutable-base = hl.dontCheck (
                        hself.callHackageDirect {
                          pkg = "strict-mutable-base";
                          ver = "1.1.0.0";
                          sha256 = "1d2knfykhs5a8mhnycgipap0gpgj6rifr83pbd1ndz4ls6hb053h";
                        } { }
                      );
                      kenshou-cli = hl.dontCheck (
                        hl.doJailbreak (
                          hself.callCabal2nixWithOptions "kenshou-cli" (pkgs.runCommand "ep54-operator-cli-source" { } ''
                            cp -r ${inputs.kenshou}/kenshou-cli "$out"
                            chmod -R u+w "$out"
                            sed -i '/import Kenshou.Suite.Shibuya qualified as Shibuya/d; s/++ \[Shibuya.bundle\]/++ []/' "$out/src/Kenshou/Cli/Registry.hs"
                            sed -i '/^[[:space:]]*kenshou-shibuya,/d' "$out/kenshou-cli.cabal"
                          '') "--flag=-runtime-suites" { }
                        )
                      );
                      kenshou-core = hl.dontCheck (
                        hl.doJailbreak (
                          hself.callCabal2nixWithOptions "kenshou-core" (
                            inputs.kenshou + "/kenshou-core"
                          ) "--flag=-keiro-schema" { }
                        )
                      );

                      kenshou-ep54-cell = hl.dontCheck (
                        hl.doJailbreak (hself.callCabal2nix "kenshou-ep54-cell" inputs.self { })
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
                  "kenshou-ep54-cell"
                ];
              };
              selected = hl.overrideCabal (_: {
                configureFlags = [
                  (if cohort == "released" then "-f-category-namespace" else "-fcategory-namespace")
                ];
              }) hp.kenshou-ep54-cell;
              executable = hl.overrideCabal (_: { disallowGhcReference = false; }) (
                hl.justStaticExecutables (
                  hl.disableLibraryProfiling (hl.disableSharedLibraries (hl.disableSharedExecutables selected))
                )
              );
            in
            pkgs.runCommand "kiroku-ep54-${cohort}"
              {
                nativeBuildInputs = [
                  pkgs.makeWrapper
                  pkgs.removeReferencesTo
                ];
                disallowedRequisites = [ hp.ghc ];
                meta.mainProgram = "kenshou";
                passthru = {
                  operator = executable;
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
                  ${lib.optionalString stallDiagnostics "--set KENSHOU_MP12_STALL_DIAGNOSTICS 1"} \
                  --set-default KENSHOU_COHORT_IDENTITY "$out/share/kenshou/cohort-identity.json" \
                  --set-default KENSHOU_PAYLOAD_IDENTITY "$out/share/kenshou/payload-identity.json" \
                  --set-default KENSHOU_HARNESS_REVISION "${inputs.self.rev or "dirty"}" \
                  --set-default KENSHOU_HARNESS_DIRTY "${if inputs.self ? rev then "false" else "true"}" \
                  --prefix PATH : "${pkgs.postgresql_18}/bin"
              '';
        in
        {
          kenshou-released = mk "released" false;
          kenshou-head = mk "head" false;
          kenshou-head-stall = mk "head" true;
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
