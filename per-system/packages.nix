{
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
  isDarwin = lib.hasSuffix "-darwin" system;
  isLinux = lib.hasSuffix "-linux" system;
  basePackages = removeAttrs (import ../pkgs pkgs) (
    lib.optionals isDarwin [
      "postgresql-role-password"
      "storage-observability"
    ]
  );
  fleet = import ../apps/fleet.nix {
    inherit
      fleetInventory
      outputs
      pkgs
      ;
  };
  degoogPackages = import ../nixos/_mixins/degoog/packages.nix { inherit pkgs; };
in
basePackages
// {
  inherit (inputs.disko.packages.${system}) disko-install;
  inherit (import ../hm/_mixins/dev/nvidia/pkgs { inherit pkgs; }) nico-cli;

  fleet-tools = fleet.packages.fleet-tools;

  qemu-host-package = pkgs.qemu;
}
// lib.optionalAttrs isDarwin {
  ismc = pkgs.callPackage ../darwin/_mixins/thermal-accounting/pkgs/ismc { };
}
// lib.optionalAttrs isLinux {
  aurral = pkgs.callPackage ../nixos/_mixins/aurral/package { };
  inherit (degoogPackages) degoog;
  degoog-devinside-extensions = degoogPackages.devinsideExtensions;
  degoog-georgvwt-extensions = degoogPackages.georgvwtExtensions;
  degoog-official-extensions = degoogPackages.officialExtensions;
  degoog-stackexchange-engine = degoogPackages.stackexchangeEngine;
  degoog-toolkit-extensions = degoogPackages.toolkitExtensions;
  ebook-converter-cli = pkgs.callPackage ../nixos/_mixins/shelfmark/ebook-converter/cli { };
  houndarr = pkgs.callPackage ../nixos/_mixins/houndarr/package {
    inherit (basePackages) aiosqlitepool;
  };
}
