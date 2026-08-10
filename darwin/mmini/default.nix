{ ... }:
{
  system.stateVersion = 5;

  host.nix.builder.enable = true;

  host.nix.cacheWarmer.enable = true;

  host.remote-control = {
    client.enable = true;
    server.vnc.enable = true;
  };

  programs.yubi = {
    smartCard = {
      enable = true;
      sshSudoPassword.enable = true;
    };
  };
}
