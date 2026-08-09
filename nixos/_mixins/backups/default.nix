{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./artifacts.nix
    ./jobs.nix
    ./metrics
    ./server.nix
    ./sources.nix
  ];

  environment.systemPackages = lib.optional (
    config.host.backups.jobs != { } || config.host.backups.server.enable
  ) pkgs.restic;
}
