{
  fleetInventory,
  lib,
  outputs,
}:
let
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  managedHosts = lib.genAttrs (builtins.attrNames configurations) (_: true);
  servers = lib.mapAttrs (name: server: server // { inherit name; }) fleetInventory.upsServers;
in
{
  inherit managedHosts servers;
}
