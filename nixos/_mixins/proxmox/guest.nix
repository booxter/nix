{
  config,
  lib,
  outputs,
  ...
}:
let
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
  config = lib.mkMerge [
    (lib.mkIf guest.enable (import ../disko { device = "/dev/sda"; }))
    (lib.mkIf guest.enable {
      host.power.shutdown.before.proxmox-cluster = model.guestNodes.${config.networking.hostName} or [ ];

      host.autoUpgrade.claims.proxmox-guest.exclusions.cluster-nodes = {
        hosts = model.guestNodes.${config.networking.hostName} or [ ];
      };

      virtualisation.proxmox = {
        inherit (guest) cores;
        name = config.networking.hostName;
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
    })
  ];
}
