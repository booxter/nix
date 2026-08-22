{
  fleetHosts,
  lib,
}:
let
  hosts = import ./hosts.nix { inherit fleetHosts lib; };
  webServices = import ./web-services-model.nix {
    entriesByOwner = import ./web-services.nix;
    inherit hosts lib;
  };
in
{
  atticServers = import ./attic.nix { inherit lib; };
  autoUpgrade = import ./auto-upgrade.nix;
  builders = import ./builders.nix { inherit lib; };
  inherit hosts;
  sites = import ./sites.nix;
  upsServers = import ./ups.nix { inherit lib; };
  inherit webServices;
}
