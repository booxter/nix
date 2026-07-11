{ username, ... }:
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
    age.enable = true;
    ssh.enable = true;
    smartCard = {
      enable = true;
      sshSudoPassword.enable = true;
    };
  };
}
