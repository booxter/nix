{
  appSet,
  inputs,
  lib,
  pkgs,
  plainPkgs,
  system,
  ...
}:
{
  codex = pkgs.codex;
  fleet-tools = appSet.packages.deploy;
  pki-certificates = appSet.packages.issue-internal-service-cert;

  qemu-host-package = plainPkgs.qemu;
}
// lib.optionalAttrs (system == "x86_64-linux") {
  inherit (inputs.disko.packages.${system}) disko-install;
}
