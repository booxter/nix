{ lib, pkgs, ... }:
{
  options.host.mediaRepair = import ./options.nix { inherit lib pkgs; };

  imports = [
    ./planner.nix
    ./worker.nix
  ];
}
