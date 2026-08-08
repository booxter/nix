{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.netboot;
  netboot = hostInventory.site.lan.netboot;
  isNetbootHost = netboot.host == config.networking.hostName;
  proxmoxBridges = config.services.proxmox-ve.bridges;
  firewallInterface =
    if config.host.isProxmox && proxmoxBridges != [ ] then
      builtins.head proxmoxBridges
    else
      config.host.network.primaryInterface;
in
{
  options.host.netboot.enable = lib.mkOption {
    type = lib.types.bool;
    default = isNetbootHost;
    readOnly = true;
    internal = true;
    description = "Whether inventory assigns the LAN netboot service to this host.";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = firewallInterface != null;
        message = "The netboot host requires a firewall interface";
      }
    ];

    services.atftpd = {
      enable = true;
      root = "/var/lib/tftp";
      extraOptions = [
        "--bind-address"
        (hostInventory.toNixosHostIpv4Address netboot.host)
      ];
    };

    networking.firewall.interfaces = lib.optionalAttrs (firewallInterface != null) {
      ${firewallInterface}.allowedUDPPorts = [
        69 # TFTP
      ];
    };

    systemd.tmpfiles.rules = [
      "L+ /var/lib/tftp/${netboot.bootfile} - - - - ${pkgs.netbootxyz-efi}"
    ];
  };
}
