{ ... }:
{
  imports = [
    ./ups.nix
  ];

  host.fleetCacheWarmer = {
    enable = true;
    targetFilter = "non-work";
    pushToAttic = true;
  };

  programs.yubi = {
    smartCard = {
      enable = true;
      sshSudoPassword.enable = true;
    };
  };
}
