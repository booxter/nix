{ config, lib, ... }:
let
  cfg = config.host.ups;
in
{
  imports = [
    ./assertions.nix
    ./options.nix
  ];

  config.host.power.shutdown.before.ups-server = lib.optional (
    cfg.client.server != null
  ) cfg.client.server;
}
