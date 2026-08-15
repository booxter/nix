{ config, lib, ... }:
let
  cfg = config.host.ups;
in
{
  imports = [
    ./assertions.nix
    ./options.nix
  ];

  config.host.power.shutdown.leadSeconds.ups-client = lib.mkIf (cfg.client.server != null) 150;
}
