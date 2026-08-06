{
  config,
  hostSpec,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  isVM = hostSpec.isVM or false;
  bridgeName = "vmbr0";
  macAddress = hostSpec.macAddress or null;
  cores = hostSpec.cores or 4;
  memorySize = hostSpec.memorySize or 8;
  balloonSize = hostSpec.balloonSize or null;
  diskSize = hostSpec.diskSize or 100;
  dhcpReservation = hostSpec.dhcpReservation or null;
in
{
  imports = [
    ./integrations.nix
    inputs.proxmox-nixos.nixosModules.proxmox-ve
  ]
  ++ lib.optionals isVM [
    inputs.proxmox-nixos.nixosModules.declarative-vms
    (import ../../disko { device = "/dev/sda"; })
  ];

  options.host.isProxmox = lib.mkOption {
    type = lib.types.bool;
    default = false;
    internal = true;
    description = "Whether this host is a Proxmox VE node.";
  };

  config = lib.mkMerge (
    [
      (lib.mkIf config.host.isProxmox {
        # Hypervisors upgrade on a separate schedule to avoid disrupting guest
        # VMs running on top.
        system.autoUpgrade = {
          dates = hostSpec.proxmoxUpgradeTime or "Mon 04:00";
          rebootWindow.lower = lib.mkForce "03:45";
        };

        nixpkgs.overlays = [
          inputs.proxmox-nixos.overlays.${hostSpec.platform}
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
          ipAddress = hostSpec.ipAddress;
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
          matchConfig.Name = [ hostSpec.netIface ];
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
      virtualisation.proxmox = {
        inherit cores;
        name = hostSpec.name;
        node = hostSpec.proxNode or "prx1-lab";
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
            // inputs.nixpkgs.lib.optionalAttrs (dhcpReservation != null) {
              macaddr = dhcpReservation.match;
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
