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

  config.host.power.shutdown.leadSeconds.ups-client = lib.mkIf (cfg.client.server != null) 150;
}
