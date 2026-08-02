{
  inputs,
  helpers,
  outputs,
}:
helpers.forAllSystems (
  system:
  let
    pkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [
        outputs.overlays.additions
        outputs.overlays.modifications
      ];
    };
    inventory = import ./lib/inventory.nix { inherit (pkgs) lib; };
    sops = import ./apps/sops {
      hostInventory = inventory;
      inherit pkgs;
    };
    fleet = import ./apps/fleet.nix { inherit pkgs; };
    fanaMonitoring = import ./nixos/fana/monitoring/catalog.nix;
    patchFiles = pkgs.lib.fileset.fileFilter (
      file: pkgs.lib.hasSuffix ".patch" file.name || pkgs.lib.hasSuffix ".diff" file.name
    ) ./.;
    mkCheck =
      {
        name,
        nativeBuildInputs,
        buildPhase,
        extraFileset ? [ ],
      }:
      pkgs.stdenv.mkDerivation {
        inherit name nativeBuildInputs buildPhase;
        src = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions (
            [
              ./apps
              ./tests
            ]
            ++ extraFileset
          );
        };
        installPhase = ''
          touch "$out"
        '';
      };
  in
  {
    sops-tools = sops.package;
    box = pkgs.box;
    patch-context = mkCheck {
      name = "patch-context";
      nativeBuildInputs = [ pkgs.python3 ];
      extraFileset = [ patchFiles ];
      buildPhase = ''
        python3 -m unittest discover -s tests -p 'test_patch_context.py'
        python3 tests/check_patch_context.py .
      '';
    };
    wg-home-client-config = fleet.packages.wg-home-client-config;
    fana-alertmanager-config = mkCheck {
      name = "fana-alertmanager-config";
      nativeBuildInputs = with pkgs; [
        gettext
        prometheus-alertmanager
      ];
      extraFileset = [ ./nixos/fana/monitoring ];
      buildPhase = ''
        export TELEGRAM_CHAT_ID='-1000000000000'
        envsubst < ${fanaMonitoring.alertmanager.configRelative} > alertmanager.rendered.yml
        amtool check-config alertmanager.rendered.yml
      '';
    };
    fana-prometheus-alerting = mkCheck {
      name = "fana-prometheus-alerting";
      nativeBuildInputs = [ pkgs.prometheus.cli ];
      extraFileset = [ ./nixos/fana/monitoring ];
      buildPhase = ''
        for rule_file in ${pkgs.lib.concatStringsSep " " fanaMonitoring.prometheus.ruleFilesRelative}; do
          promtool check rules "$rule_file"
        done

        for test_file in ${pkgs.lib.concatStringsSep " " fanaMonitoring.prometheus.testFilesRelative}; do
          test_dir="$(dirname "$test_file")"
          test_name="$(basename "$test_file")"
          (
            cd "$test_dir"
            promtool test rules "$test_name"
          )
        done
      '';
    };
  }
)
