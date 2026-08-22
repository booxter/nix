{ lib }:
{
  atticServers = import ./attic.nix { inherit lib; };
  builders = import ./builders.nix { inherit lib; };
  upsServers = import ./ups.nix { inherit lib; };
}
