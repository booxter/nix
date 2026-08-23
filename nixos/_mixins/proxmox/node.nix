{
  config,
  inputs,
  lib,
  pkgs,
  proxmoxTopology,
  system,
  ...
}:
let
  bridgeName = "vmbr0";
  macAddress = config.host.network.macAddress;
  primaryInterface = config.host.network.primaryInterface;
  expectedCertificateDnsNames = [
    config.networking.hostName
    "${config.networking.hostName}.${config.host.network.lanDomain}"
    "${config.networking.hostName}.local"
  ];
  proxmoxCache = import ../../../common/_mixins/nix/cache/proxmox.nix { inherit lib; };
in
{
  config = lib.mkIf (config.host.proxmox.node != null) {
    assertions = [
      {
        assertion = primaryInterface != null;
        message = "host.proxmox.node requires host.network.primaryInterface";
      }
      {
        assertion = lib.all (
          name: builtins.elem name config.host.network.certificateDnsNames
        ) expectedCertificateDnsNames;
        message = "Proxmox node certificates must include conventional host DNS names used by OIDC";
      }
    ];

    host.nix.caches.proxmox = lib.mkDefault proxmoxCache;

    host.network.stableAddress.requiredBy = [ "Proxmox VE node" ];

    host.autoUpgrade.claims.proxmox-node = {
      switch.cadence = "weekly";
      reboot.cadence = "weekly";
      availabilityGroup = "proxmox:${config.host.realm}:${proxmoxTopology.clusterName}";
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
