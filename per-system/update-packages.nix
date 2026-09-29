{
  lib,
  pkgs,
  plainPkgs,
  system,
  ...
}:
let
  sharedPackages = import ../pkgs plainPkgs;
  degoogPackages = import ../nixos/_mixins/degoog/packages.nix { pkgs = plainPkgs; };
in
lib.optionalAttrs (lib.hasSuffix "-darwin" system) {
  ismc = plainPkgs.callPackage ../darwin/_mixins/thermal-accounting/pkgs/ismc { };
  jiratui = pkgs.jiratui;
}
// lib.optionalAttrs (lib.hasSuffix "-linux" system) {
  inherit (sharedPackages) aiosqlitepool firefox-devtools-mcp;
  inherit (degoogPackages) degoog;
  degoog-devinside-extensions = degoogPackages.devinsideExtensions;
  degoog-georgvwt-extensions = degoogPackages.georgvwtExtensions;
  degoog-official-extensions = degoogPackages.officialExtensions;
  degoog-stackexchange-engine = degoogPackages.stackexchangeEngine;
  degoog-toolkit-extensions = degoogPackages.toolkitExtensions;
  ebook-converter-cli = plainPkgs.callPackage ../nixos/_mixins/shelfmark/ebook-converter/cli { };
  houndarr = plainPkgs.callPackage ../nixos/_mixins/houndarr/package {
    inherit (sharedPackages) aiosqlitepool;
  };
  nico-cli = (import ../hm/_mixins/dev/nvidia/pkgs { pkgs = plainPkgs; }).nico-cli;
}
