{
  config,
  hostSpec,
  inputs,
  lib,
  outputs,
  pkgs,
  system,
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
  primaryInterface = config.host.network.primaryInterface;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  nodeMaintenanceDays = [
    "Wed"
    "Thu"
    "Fri"
    "Sun"
  ];
  clusterNodes = model.nodesByRealmCluster.${config.host.realm}.${config.host.proxmox.cluster} or [ ];
  nodeMaintenanceDay =
    let
      nodeIndex = lib.lists.findFirstIndex (name: name == hostSpec.name) 0 clusterNodes;
    in
    builtins.elemAt nodeMaintenanceDays (lib.mod nodeIndex (builtins.length nodeMaintenanceDays));
in
{
  imports = [
    ./assertions.nix
    ./integrations.nix
    inputs.proxmox-nixos.nixosModules.proxmox-ve
  ]
  ++ lib.optionals isVM [
    inputs.proxmox-nixos.nixosModules.declarative-vms
    (import ../../disko { device = "/dev/sda"; })
  ];

  options.host.proxmox.cluster = lib.mkOption {
    type = lib.types.nonEmptyStr;
    default = "default";
    description = "Proxmox cluster used when this host participates as a node or guest.";
  };

  config = lib.mkMerge (
    [
      {
        host.power.shutdown.before.proxmox-cluster = lib.optionals isVM (
          model.guestNodes.${hostSpec.name} or [ ]
        );
      }
      (lib.mkIf config.host.isProxmox {
        host.network.stableAddress.requiredBy = [ "Proxmox VE node" ];

        host.autoUpgrade.claims.proxmox-node = {
          switch = {
            cadence = "weekly";
            weekday = nodeMaintenanceDay;
          };
          reboot = {
            cadence = "weekly";
            weekday = nodeMaintenanceDay;
          };
          availabilityGroups = [
            "proxmox:${config.host.realm}:${config.host.proxmox.cluster}"
          ];
        };

        nixpkgs.overlays = [
          inputs.proxmox-nixos.overlays.${system}
          (
            _final: prev:
            let
              patchedPveManager = prev.pve-manager.overrideAttrs (old: {
                patches = (old.patches or [ ]) ++ [
                  ../../../patches/pve-manager-disable-subscription-popup.patch
                ];
              });
            in
            {
              pve-manager = patchedPveManager;
              proxmox-ve = prev.proxmox-ve.override {
                pve-manager = patchedPveManager;
              };
            }
          )
        ];

        services.proxmox-ve = {
          ipAddress = config.host.network.ipAddress;
          enable = true;
          bridges = [ bridgeName ];
        };

        # Some packages useful when debugging Proxmox VE.
        environment.systemPackages = with pkgs; [ bridge-utils ];

        # Bridge to the LAN, while retaining the IP address and MAC address on
        # the main interface as expected by the DHCP server.
        networking.useNetworkd = true;
        systemd.network.enable = true;

        services.resolved.settings.Resolve.ResolveUnicastSingleLabel = true;

        systemd.network.networks."10-lan" = {
          matchConfig.Name = lib.optional (primaryInterface != null) primaryInterface;
          networkConfig.Bridge = bridgeName;
        };

        systemd.network.netdevs."10-lan-bridge".netdevConfig = {
          Name = bridgeName;
          Kind = "bridge";
        }
        // inputs.nixpkgs.lib.optionalAttrs (macAddress != null) {
          MACAddress = macAddress;
        };

        systemd.network.networks."10-lan-bridge" = {
          matchConfig.Name = bridgeName;
          networkConfig = {
            IPv6AcceptRA = true;
            DHCP = "ipv4";
          };
          dhcpV4Config = {
            # systemd-networkd receives DOMAINNAME=home.arpa from DHCP, but does
            # not install it as a search domain unless enabled.
            UseDomains = true;
          };
          linkConfig.RequiredForOnline = "routable";
        };
      })
    ]
    ++ lib.optional isVM {
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
            // inputs.nixpkgs.lib.optionalAttrs (macAddress != null) {
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
    }
    ++ lib.optional isVM (
      lib.mkIf config.host.isProxmox {
        virtualisation.vmVariant.virtualisation.forwardPorts = [
          {
            from = "host";
            guest.port = 8006;
            host.port = 8006;
          }
        ];
      }
    )
  );
}
