{
  config,
  hostSpec,
  inputs,
  lib,
  outputs,
  ...
}:
let
  isVM = hostSpec.isVM or false;
  bridgeName = "vmbr0";
  macAddress = config.host.network.macAddress;
  cores = hostSpec.cores or 4;
  memorySize = hostSpec.memorySize or 8;
  balloonSize = hostSpec.balloonSize or null;
  diskSize = hostSpec.diskSize or 100;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
in
{
  imports = lib.optionals isVM [
    inputs.proxmox-nixos.nixosModules.declarative-vms
    (import ../../disko { device = "/dev/sda"; })
  ];

  config = lib.optionalAttrs isVM {
    host.power.shutdown.before.proxmox-cluster = model.guestNodes.${hostSpec.name} or [ ];

    host.autoUpgrade.claims.proxmox-guest.exclusions.cluster-nodes = {
      hosts = model.guestNodes.${hostSpec.name} or [ ];
    };

    virtualisation.proxmox = {
      inherit cores;
      name = hostSpec.name;
      autoInstall = true;
      memory = memorySize * 1024;
      balloon = if balloonSize == null then null else balloonSize * 1024;
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
          file = "local:${toString diskSize}";
          discard = "on";
        }
      ];
      onboot = true;
    };

    boot.growPartition = true;
  };
}
