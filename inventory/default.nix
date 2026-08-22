{ lib }:
{
  atticServers = import ./attic.nix { inherit lib; };
  upsServers = import ./ups.nix { inherit lib; };
}
