{
  facts,
  inputs,
  outputs,
  plainPkgs,
  system,
  ...
}:
let
  pkgs = plainPkgs;
  basePackages = pkgs.lib.filterAttrs (
    _: package: pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform package
  ) (import ../pkgs pkgs);
  fleet = import ../apps/fleet.nix {
    inherit
      facts
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
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
  ismc = pkgs.callPackage ../darwin/_mixins/thermal-accounting/pkgs/ismc { };
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  aurral = pkgs.callPackage ../nixos/_mixins/aurral/package { };
  inherit (degoogPackages) degoog;
  degoog-devinside-extensions = degoogPackages.devinsideExtensions;
  degoog-georgvwt-extensions = degoogPackages.georgvwtExtensions;
  degoog-official-extensions = degoogPackages.officialExtensions;
  degoog-stackexchange-engine = degoogPackages.stackexchangeEngine;
  degoog-toolkit-extensions = degoogPackages.toolkitExtensions;
  ebook-converter-cli = pkgs.callPackage ../nixos/_mixins/ebook-converter/package/cli { };
  houndarr = pkgs.callPackage ../nixos/srvarr/pkgs/houndarr { };
}
