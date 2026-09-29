{
  appSet,
  fleetInventory,
  inputs,
  lib,
  outputs,
  pkgs,
  plainPkgs,
  system,
  ...
}:
let
  fleet = import ../apps/fleet.nix {
    inherit
      fleetInventory
      outputs
      ;
    pkgs = plainPkgs;
  };
in
{
  codex = pkgs.codex;
  fleet-tools = fleet.packages.fleet-tools;
  pki-certificates = appSet.packages.issue-internal-service-cert;

  qemu-host-package = plainPkgs.qemu;
}
// lib.optionalAttrs (system == "x86_64-linux") {
  inherit (inputs.disko.packages.${system}) disko-install;
}
