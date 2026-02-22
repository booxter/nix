{
  inputs,
  system,
}:
let
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  mkApp = program: description: {
    type = "app";
    inherit program;
    meta = { inherit description; };
  };
in
if builtins.hasAttr system inputs.proxmox-nixos.packages then
  let
    proxmoxPkgs = builtins.getAttr system inputs.proxmox-nixos.packages;
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
        Example: prox-deploy srvarr prx1
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
        flake_target="prox-''${vm_type}vm"

        exec ${../scripts/prox-deploy.sh} \
          "$proxmox_host" \
          "root" \
          "priv/lab-''${proxmox_host}" \
          "$flake_target"
      '';
    };
  in
  if builtins.hasAttr "nixmoxer" proxmoxPkgs then
    {
      packages = {
        prox-deploy = proxDeploy;
      };
      apps = {
        prox-deploy = mkApp "${proxDeploy}/bin/prox-deploy" "Deploy a prox VM via nixmoxer.";
      };
    }
  else
    {
      packages = { };
      apps = { };
    }
else
  {
    packages = { };
    apps = { };
  }
