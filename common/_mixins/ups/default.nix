{
  config,
  fleetInventory,
  lib,
  ...
}:
let
  client = builtins.hasAttr config.networking.hostName fleetInventory.ups.clients;
in
{
  imports = [
    ./assertions.nix
    ./options.nix
  ];

  config.host.power.shutdown.leadSeconds.ups-client = lib.mkIf client 150;
}
