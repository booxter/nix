{ pkgs }:
let
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };

  fleetApply = pkgs.writeShellApplication {
    name = "fleet-apply";
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
        fleet-apply [fleet deploy args]
        fleet-apply --home <target> [username]
        fleet-apply --disko <host> <device>

      Examples:
        fleet-apply -A --select
        fleet-apply --home nv ihrachyshka
        fleet-apply --disko frame /dev/sdX
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
in
{
  "fleet-apply" =
    mkApp "${fleetApply}/bin/fleet-apply" "Apply fleet operations: host deploys (default), standalone Home Manager (--home), or disk provisioning (--disko).";
}
