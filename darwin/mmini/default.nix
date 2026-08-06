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
    ssh.enable = true;
    smartCard = {
      enable = true;
      sshSudoPassword.enable = true;
    };
  };
}
