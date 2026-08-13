{ config, lib, ... }:
let
  cfg = config.host.ups;
in
{
  imports = [
    ./assertions.nix
    ./home.nix
    ./options.nix
    ./work.nix
  ];

  config.host.power.shutdown.before.ups-server = lib.optional (
    cfg.client.server != null
  ) cfg.client.server;
}
