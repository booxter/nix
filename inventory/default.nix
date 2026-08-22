{
  fleetHosts,
  lib,
}:
{
  atticServers = import ./attic.nix { inherit lib; };
  builders = import ./builders.nix { inherit lib; };
  hosts = import ./hosts.nix { inherit fleetHosts lib; };
  upsServers = import ./ups.nix { inherit lib; };
}
