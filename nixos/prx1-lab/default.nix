{ config, ... }:
{
  system.stateVersion = "25.11";

  imports = [
    ./netboot.nix
  ];

  host.isProxmox = true;
  host.network.primaryInterface = "enp5s0f0np0";
  host.proxmox.apiCertificate.serverName = "proxmox.${config.host.network.lanDomain}";
  host.ups = {
    server = {
      description = "APC UPS 1500VA";
    };
    shutdown.critical = true;
  };
}
