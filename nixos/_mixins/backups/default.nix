{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./artifacts.nix
    ./client.nix
    ./inventory.nix
    ./jobs.nix
    ./metrics
    ./server.nix
  ];

  environment.systemPackages = lib.optional (
    config.host.backups.jobs != { } || config.host.backups.server.enable
  ) pkgs.restic;
}
