{
  inputs,
  pkgs,
  publicHostKey,
  installedSystem,
}:
let
  identityPath = "/run/bootstrap/ssh_host_ed25519_key";
  installationLayout = installedSystem.extendModules {
    modules = [
      {
        disko.devices.disk.main.content.partitions.root.content.postMountHook = ''
          install -Dm600 ${identityPath} /mnt/etc/ssh/ssh_host_ed25519_key
        '';
      }
    ];
  };
in
{
  imports = [
    (import (inputs.proxmox-nixos + "/modules/declarative-vms/iso.nix") (
      installedSystem.config.system.build
      // {
        diskoScript = installationLayout.config.system.build.diskoScript;
      }
    ))
  ];

  # Upstream forces a shared name; keep each guest's installer separate on
  # Proxmox storage. The ISO builder derives its filename from image.baseName.
  image.baseName = pkgs.lib.mkOverride 40 "nixos-${installedSystem.config.networking.hostName}-installer";

  services.qemuGuest.enable = true;
  environment.systemPackages = [ pkgs.proxmox-bootstrap ];
  environment.etc."proxmox-bootstrap/host.pub".text = publicHostKey + "\n";
  systemd.tmpfiles.rules = [ "d /run/bootstrap 0700 root root -" ];
  systemd.services.installer.preStart = ''
    # Only the receiver publishes this file, after validating its public key.
    echo "Waiting for the installation identity"
    until test -f ${identityPath}; do
      sleep 0.1
    done
  '';
}
