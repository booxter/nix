{
  appSet,
  fleetInventory,
  inputs,
  lib,
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
  fleet-tools = fleet.packages.fleet-tools;
  pki-certificates = appSet.packages.issue-internal-service-cert;

  qemu-host-package = pkgs.qemu;
}
// lib.optionalAttrs (system == "x86_64-linux") {
  inherit (inputs.disko.packages.${system}) disko-install;
}
