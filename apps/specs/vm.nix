{ facts, pkgs, ... }:
{
  package = (import ../fleet.nix { inherit facts pkgs; }).packages.vm;
  description = "Run a local NixOS VM for a nixosConfigurations host.";
}
