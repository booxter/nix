{ lib, pkgs, ... }:
{
  options.host.mediaRepair = import ./options.nix { inherit lib pkgs; };

  imports = [
    ../radarr/repair.nix
    ../radarr/worker.nix
  ];
}
