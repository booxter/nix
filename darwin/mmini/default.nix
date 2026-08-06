{ config, ... }:
let
  username = config.host.username;
in
{
  imports = [
    ./ups.nix
  ];

  home-manager.users.${username}.programs.sshTicket.enableKnownHosts = true;

  host.fleetCacheWarmer = {
    enable = true;
    targetFilter = "non-work";
    pushToAttic = true;
  };

  programs.yubi = {
    ssh.enable = true;
    smartCard = {
      enable = true;
      sshSudoPassword.enable = true;
    };
  };
}
