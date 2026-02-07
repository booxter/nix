{ inputs, helpers }:
helpers.forAllSystems (
  system:
  let
    pkgs = import inputs.nixpkgs { inherit system; };
    mkCheck =
      {
        name,
        nativeBuildInputs,
        buildPhase,
      }:
      pkgs.stdenv.mkDerivation {
        inherit name nativeBuildInputs buildPhase;
        src = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./scripts
            ./tests
          ];
        };
        installPhase = ''
          touch "$out"
        '';
      };
  in
  {
    bats-tests = mkCheck {
      name = "bats-tests";
      nativeBuildInputs = with pkgs; [
        bats
        jq
      ];
      buildPhase = ''
        bats tests/update-machines.bats
        bats tests/test-sops-config.bats
        bats tests/test-sops-bootstrap.bats
      '';
    };
    box-py = mkCheck {
      name = "box-py-tests";
      nativeBuildInputs = with pkgs; [
        python3
        python3Packages.pytest
      ];
      buildPhase = ''
        pytest -q tests/test_box.py
      '';
    };
  }
)
