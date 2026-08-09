{ config, ... }:
{
  system.stateVersion = "25.11";
  home-manager.users.${config.host.username}.home.stateVersion = "25.11";

  imports = [
    ./netboot.nix
  ];

  host.isProxmox = true;
  host.network.primaryInterface = "enp5s0f0np0";
  host.ups = {
    server = {
      description = "APC UPS 1500VA";
    };
    shutdown.critical = true;
  };
}
