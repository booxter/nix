{
  inputs,
  system,
}:
let
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  proxmoxPkgs = inputs.proxmox-nixos.packages.${system};
  hostInventory = import ../lib/inventory.nix { lib = pkgs.lib; };
  vmSpecs = builtins.filter hostInventory.isNixosVM hostInventory.nixosHostSpecs;
  vmTargetCases = pkgs.lib.concatMapStringsSep "\n" (spec: ''
    ${pkgs.lib.escapeShellArg spec.name})
      ;;
  '') vmSpecs;
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };
  proxDeploy = pkgs.writeShellApplication {
    name = "prox-deploy";
    runtimeInputs = [
      pkgs.pass
      proxmoxPkgs.nixmoxer
    ];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'EOF'
      Usage: prox-deploy <vm-type> <proxmox-host>
      Example: prox-deploy srvarr prx1-lab
      EOF
      }

      if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
        usage
        exit 0
      fi

      if [ "$#" -ne 2 ]; then
        usage >&2
        exit 1
      fi

      vm_type="$1"
      proxmox_host="$2"
      case "$vm_type" in
      ${vmTargetCases}
        *)
          echo "Unknown VM type: $vm_type" >&2
          usage >&2
          exit 1
          ;;
      esac

      exec ${../apps/prox-deploy.sh} \
        "$proxmox_host" \
        "root" \
        "host/''${proxmox_host}/root" \
        "$vm_type"
    '';
    derivationArgs = {
      doCheck = true;
      nativeCheckInputs = [
        pkgs.bash
        pkgs.bats
        pkgs.gnugrep
        pkgs.shellcheck
      ];
    };
    checkPhase = ''
      runHook preCheck
      ${pkgs.lib.getExe pkgs.bash} -n "$target"
      ${pkgs.lib.getExe pkgs.shellcheck} "$target"
      cd ${../.}
      PROX_DEPLOY_BIN=${../apps/prox-deploy.sh} \
        ${pkgs.lib.getExe pkgs.bats} --print-output-on-failure ${../apps/prox-deploy.bats}
      runHook postCheck
    '';
  };
in
{
  packages = {
    prox-deploy = proxDeploy;
  };
  apps = {
    prox-deploy = mkApp "${proxDeploy}/bin/prox-deploy" "Deploy a prox VM via nixmoxer.";
  };
}
