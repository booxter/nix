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
  guestUpsServer = model.hosts.${config.networking.hostName}.upsServer;
  mismatchedUpsNodes = builtins.filter (
    name: model.hosts.${name}.upsServer != guestUpsServer
  ) model.nodeNames;
in
{
  config = lib.mkMerge [
    (lib.mkIf (guest != null) (import ../disko/plain.nix { device = "/dev/sda"; }))
    (lib.mkIf (guest != null) {
      assertions = [
        {
          assertion = model.nodeNames != [ ];
          message = "${config.networking.hostName} references Proxmox cluster '${guest.cluster}' without any nodes in realm '${config.host.realm}'";
        }
        {
          assertion = guestUpsServer == null || mismatchedUpsNodes == [ ];
          message = "${config.networking.hostName} and its Proxmox nodes must use the same UPS server; mismatched nodes: ${lib.concatStringsSep ", " mismatchedUpsNodes}";
        }
      ];

      host.power.shutdown.leadSeconds.proxmox-guest = 150;

      host.autoUpgrade.claims.proxmox-guest.exclusions.cluster-nodes = {
        hosts = model.nodeNames;
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
