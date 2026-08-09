{ config, ... }:
{
  system.stateVersion = 5;
  home-manager.users.${config.host.username}.home.stateVersion = "25.11";

  host.fleetCacheWarmer = {
    enable = true;
    targetRealm = "home";
    pushToAttic = true;
  };

  programs.yubi = {
    smartCard = {
      enable = true;
      sshSudoPassword.enable = true;
    };
  };
}
