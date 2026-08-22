{
  fleetInventory,
  inputs,
  outputs,
  plainPkgs,
  system,
  ...
}:
let
  pkgs = plainPkgs;
  fleet = import ../apps/fleet.nix {
    inherit
      fleetInventory
      outputs
      pkgs
      ;
  };
in
{
  inherit (inputs.disko.packages.${system}) disko-install;

  fleet-tools = fleet.packages.fleet-tools;

  qemu-host-package = pkgs.qemu;
}
