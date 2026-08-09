{ ... }:
{
  system.stateVersion = 5;

  host.isBuilder = true;

  host.fleetCacheWarmer = {
    enable = true;
    targetRealm = "home";
    pushToAttic = true;
  };

  host.remote-control = {
    client = {
      vnc.enable = true;
      x11.enable = true;
    };
    server.vnc.enable = true;
  };

  programs.yubi = {
    smartCard = {
      enable = true;
      sshSudoPassword.enable = true;
    };
  };
}
