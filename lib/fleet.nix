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
      openssh
      python3
      python3Packages.prompt-toolkit
    ];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'EOF'
      Usage:
        fleet-apply [fleet-upgrade args]
        fleet-apply --home <target> [username]

      Examples:
        fleet-apply -A --select
        fleet-apply --home nv ihrachyshka
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

      exec ${pkgs.bash}/bin/bash ${../.}/scripts/update-machines.sh "$@"
    '';
  };
in
{
  "fleet-apply" =
    mkApp "${fleetApply}/bin/fleet-apply" "Apply fleet operations: host deploys (default) or standalone Home Manager with --home.";
}
