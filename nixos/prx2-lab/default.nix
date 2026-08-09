{ config, ... }:
{
  system.stateVersion = "25.11";
  home-manager.users.${config.host.username}.home.stateVersion = "25.11";

  host.isProxmox = true;
  host.network.primaryInterface = "enp5s0f0np0";
}
