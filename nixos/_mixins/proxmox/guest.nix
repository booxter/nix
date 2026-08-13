{
  config,
  hostSpec,
  inputs,
  lib,
  outputs,
  ...
}:
let
  isGuest = (hostSpec.proxmox or { }) ? guest;
  guest = config.host.proxmox.guest;
  bridgeName = "vmbr0";
  macAddress = config.host.network.macAddress;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
in
{
  imports = lib.optionals isGuest [
    inputs.proxmox-nixos.nixosModules.declarative-vms
    (import ../disko { device = "/dev/sda"; })
  ];

  config = lib.optionalAttrs isGuest {
    host.power.shutdown.before.proxmox-cluster = model.guestNodes.${hostSpec.name} or [ ];

    host.autoUpgrade.claims.proxmox-guest.exclusions.cluster-nodes = {
      hosts = model.guestNodes.${hostSpec.name} or [ ];
    };

    virtualisation.proxmox = {
      inherit (guest) cores;
      name = hostSpec.name;
      autoInstall = true;
      memory = guest.memoryGiB * 1024;
      balloon = if guest.balloonGiB == null then null else guest.balloonGiB * 1024;
      cpu.cputype = "host";
      agent = {
        enabled = true;
        type = "virtio";
        freeze-fs-on-backup = true;
        fstrim_cloned_disks = true;
      };
      net = [
        (
          {
            model = "virtio";
            bridge = bridgeName;
          }
          // lib.optionalAttrs (macAddress != null) {
            macaddr = macAddress;
          }
        )
      ];
      scsi = [
        {
          file = "local:${toString guest.diskGiB}";
          discard = "on";
        }
      ];
      onboot = true;
    };

    boot.growPartition = true;
  };
}
