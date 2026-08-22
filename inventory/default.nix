{ lib }:
{
  atticServers = import ./attic.nix { inherit lib; };
}
