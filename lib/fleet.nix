{ pkgs }:
let
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };

  deploy = pkgs.writeShellApplication {
    name = "deploy";
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
        deploy [fleet deploy args]
        deploy --home <target> [username]
        deploy --disko <host> <device>

      Examples:
        deploy -A --select
        deploy --home nv ihrachyshka
        deploy --disko frame /dev/sdX
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
      export VM_REPO_ROOT="${../.}"
      exec ${pkgs.bash}/bin/bash ${../scripts/vm.sh} "$@"
    '';
  };

  getLocalBuilders = pkgs.writeShellApplication {
    name = "get-local-builders";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      gawk
    ];
    text = ''
      exec ${../scripts/get-local-builders.sh} "$@"
    '';
  };
in
{
  deploy = mkApp "${deploy}/bin/deploy" "Apply fleet operations: host deploys (default), standalone Home Manager (--home), or disk provisioning (--disko).";
  vm = mkApp "${vm}/bin/vm" "Run a local NixOS VM for a nixosConfigurations host via local-<target-host>vm.";
  "get-local-builders" =
    mkApp "${getLocalBuilders}/bin/get-local-builders" "Read local Nix builders from nix.conf or nix.machines.";
}
