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
    fleetApps = import ./apps/fleet.nix { inherit pkgs; };
    fanaMonitoring = import ./nixos/fana/monitoring/catalog.nix;
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
    bats = mkCheck {
      name = "bats";
      nativeBuildInputs = with pkgs; [
        age
        bats
        git
        jq
        mkpasswd
        python3
        sops
        yq-go
      ];
      buildPhase = ''
        bats --print-output-on-failure tests/get-local-builders.bats
        bats --print-output-on-failure tests/codex-usage.bats
        bats --print-output-on-failure tests/codex-warmer.bats
        bats --print-output-on-failure tests/sketchybar-alertmanager.bats
        bats --print-output-on-failure tests/test-diff-config.bats
        bats --print-output-on-failure tests/test-prox-deploy.bats
        bats --print-output-on-failure tests/test-update-packages.bats
        bats --print-output-on-failure tests/test-update-oci-images.bats
        bash tests/check-sops-helpers.sh
        bats --print-output-on-failure tests/test-vm.bats
        bats --print-output-on-failure tests/update-machines.bats
      '';
      extraFileset = [
        ./home-manager/_mixins/agents/pkgs/codex-usage-status.sh
        ./home-manager/_mixins/agents/pkgs/codex-warmer.sh
        ./home-manager/_mixins/sketchybar/sketchybar/plugins/codex.sh
        ./home-manager/_mixins/sketchybar/sketchybar/plugins/alertmanager.sh
      ];
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
    wg-home-client-config = mkCheck {
      name = "wg-home-client-config-tests";
      nativeBuildInputs = with pkgs; [
        bash
        coreutils
        gnugrep
      ];
      buildPhase = ''
        private_key_file="$PWD/client.key"
        printf '%s\n' 'test-private-key' > "$private_key_file"

        help_output="$(${fleetApps."wg-home-client-config".program} --help)"
        printf '%s\n' "$help_output" | grep -F -- '--peer mair' >/dev/null
        printf '%s\n' "$help_output" | grep -F -- 'Inventory-backed peers: mair' >/dev/null

        peer_output="$(${
          fleetApps."wg-home-client-config".program
        } --peer mair --private-key-file "$private_key_file" --server-public-key test-server-pubkey)"
        printf '%s\n' "$peer_output" | grep -F -- 'Address = 10.83.0.10/32' >/dev/null
        printf '%s\n' "$peer_output" | grep -F -- 'DNS = 192.168.0.1, home.arpa' >/dev/null
        printf '%s\n' "$peer_output" | grep -F -- "Endpoint = wg.${inventory.site.public.domain}:51820" >/dev/null
        printf '%s\n' "$peer_output" | grep -F -- 'AllowedIPs = 10.83.0.0/24, 192.168.0.0/16' >/dev/null

        explicit_output="$(${
          fleetApps."wg-home-client-config".program
        } --address 10.83.0.50/32 --private-key-file "$private_key_file" --server-public-key test-server-pubkey)"
        printf '%s\n' "$explicit_output" | grep -F -- 'Address = 10.83.0.50/32' >/dev/null

        if ${
          fleetApps."wg-home-client-config".program
        } --peer nope --private-key-file "$private_key_file" --server-public-key test-server-pubkey >unknown.out 2>unknown.err; then
          echo "expected unknown peer resolution to fail" >&2
          exit 1
        fi
        grep -F -- "unknown inventory peer 'nope'" unknown.err >/dev/null

        if ${
          fleetApps."wg-home-client-config".program
        } --address 10.84.0.50/32 --private-key-file "$private_key_file" --server-public-key test-server-pubkey >subnet.out 2>subnet.err; then
          echo "expected out-of-subnet peer address to fail" >&2
          exit 1
        fi
        grep -F -- 'is not inside 10.83.0.0/24' subnet.err >/dev/null
      '';
    };
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
