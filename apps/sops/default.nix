{
  fleetInventory,
  pkgs,
}:
let
  realmsByHost = pkgs.lib.mapAttrs (_: host: host.realm) fleetInventory.hosts;
in
{
  packages = {
    sops-tools = import ./package.nix { inherit pkgs realmsByHost; };
  };
}
