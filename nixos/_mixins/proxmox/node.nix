{
  config,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  bridgeName = "vmbr0";
  macAddress = config.host.network.macAddress;
  primaryInterface = config.host.network.primaryInterface;
in
{
  config = lib.mkIf config.host.isProxmox {
    host.network.stableAddress.requiredBy = [ "Proxmox VE node" ];

    host.autoUpgrade.claims.proxmox-node = {
      switch.cadence = "weekly";
      reboot.cadence = "weekly";
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
    // lib.optionalAttrs (macAddress != null) {
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
  };
}
