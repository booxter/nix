{ ... }:
{
  imports = [
    ./ups.nix
  ];

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
