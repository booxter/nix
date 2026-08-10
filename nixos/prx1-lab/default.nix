{ config, ... }:
{
  system.stateVersion = "25.11";

  imports = [
    ./netboot.nix
  ];

  host.isProxmox = true;
  host.network = {
    interfaces.enp5s0f0np0.kind = "ethernet";
    macAddress = "38:05:25:30:7d:89";
    primaryInterface = "enp5s0f0np0";
    reservation = {
      enable = true;
      address = "192.168.15.10";
    };
  };
  host.proxmox.apiCertificate.serverName = "proxmox.${config.host.network.lanDomain}";
  host.ups = {
    server = {
      description = "APC UPS 1500VA";
    };
    shutdown.waitForLowBattery = true;
  };
}
