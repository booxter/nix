{ pkgs }:
let
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };

  fleetDeploy = pkgs.writeShellApplication {
    name = "fleet-deploy";
    runtimeInputs = with pkgs; [
      bind
      git
      home-manager
      jq
      nix
      openssh
      python3
      python3Packages.prompt-toolkit
    ];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'EOF'
      Usage:
        fleet-deploy [fleet deploy args]
        fleet-deploy --home <target> [username]
        fleet-deploy --disko <host> <device>

      Examples:
        fleet-deploy -A --select
        fleet-deploy --home nv ihrachyshka
        fleet-deploy --disko frame /dev/sdX
      EOF
      }

      if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
        usage
        exit 0
      fi

      if [ "$#" -gt 0 ] && [ "$1" = "--home" ]; then
        shift

        if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
          usage >&2
          exit 1
        fi

        target="$1"
        username="''${USERNAME:-ihrachyshka}"
        if [ "$#" -eq 2 ]; then
          username="$2"
        fi

        exec home-manager switch --flake "${../.}#''${username}@''${target}" -L --show-trace -b backup
      fi

      if [ "$#" -gt 0 ] && [ "$1" = "--disko" ]; then
        shift

        if [ "$#" -ne 2 ]; then
          usage >&2
          exit 1
        fi

        host="$1"
        device="$2"
        disko_cmd=(
          nix
          --extra-experimental-features "nix-command flakes"
          run
          -L
          --show-trace
          "github:nix-community/disko/latest#disko-install"
          --
          --flake "${../.}#''${host}"
          --disk main
          "''${device}"
        )

        if [ "''${EUID}" -eq 0 ]; then
          exec "''${disko_cmd[@]}"
        fi
        exec sudo "''${disko_cmd[@]}"
      fi

      exec ${pkgs.bash}/bin/bash ${../.}/scripts/update-machines.sh "$@"
    '';
  };

  vm = pkgs.writeShellApplication {
    name = "vm";
    runtimeInputs = with pkgs; [
      jq
      nix
    ];
    text = ''
      set -euo pipefail

      list_target_hosts() {
        nix flake show --json "${../.}" 2>/dev/null \
          | jq -r '.nixosConfigurations | keys[] | select(test("^local-.*vm$")) | capture("^local-(?<host>.*)vm$").host' \
          | sort -u
      }

      usage() {
        cat <<'EOF'
      Usage: vm <target-host>
      Example: vm builder1

      Available target hosts (from local-<host>vm configs):
      EOF
        list_target_hosts | sed 's/^/  /'
      }

      if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
        usage
        exit 0
      fi

      if [ "$#" -ne 1 ]; then
        usage >&2
        exit 1
      fi

      target_host="$1"
      if ! list_target_hosts | grep -Fxq "$target_host"; then
        echo "Unknown target host: $target_host" >&2
        echo >&2
        usage >&2
        exit 1
      fi

      exec nix run "${../.}#nixosConfigurations.local-''${target_host}vm.config.system.build.vm" -L --show-trace
    '';
  };
in
{
  "fleet-deploy" =
    mkApp "${fleetDeploy}/bin/fleet-deploy" "Apply fleet operations: host deploys (default), standalone Home Manager (--home), or disk provisioning (--disko).";
  vm = mkApp "${vm}/bin/vm" "Run a local NixOS VM for a target host defined as local-<target-host>vm in nixosConfigurations.";
}
