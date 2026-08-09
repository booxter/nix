{
  facts,
  inputs,
  plainPkgs,
  system,
  ...
}:
let
  pkgs = plainPkgs;
  basePackages = pkgs.lib.filterAttrs (
    _: package: pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform package
  ) (import ../pkgs pkgs);
  fleet = import ../apps/fleet.nix { inherit facts pkgs; };
  orgPackages = import ../nixos/org/pkgs pkgs;
in
basePackages
// {
  inherit (inputs.disko.packages.${system}) disko-install;
  inherit (import ../hm/_mixins/nv/pkgs { inherit pkgs; }) nico-cli;

  fleet-tools = fleet.packages.fleet-tools;

  qemu-host-package = pkgs.qemu;
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
  ismc = pkgs.callPackage ../darwin/pkgs/ismc { };
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  aurral = pkgs.callPackage ../nixos/srvarr/pkgs/aurral { };
  inherit (orgPackages)
    degoog
    degoog-devinside-extensions
    degoog-georgvwt-extensions
    degoog-official-extensions
    degoog-stackexchange-engine
    degoog-toolkit-extensions
    ;
  ebook-converter-cli = pkgs.callPackage ../nixos/srvarr/pkgs/ebook-converter-cli { };
  houndarr = pkgs.callPackage ../nixos/srvarr/pkgs/houndarr { };
}
