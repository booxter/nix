{
  inputs,
  pkgs,
  system,
  username,
}:
let
  orgPackages = import ./nixos/org/pkgs pkgs;
in
(import ./pkgs pkgs)
// {
  inherit (inputs.disko.packages.${system}) disko-install;
  inherit (import ./home-manager/_mixins/nv/pkgs { inherit pkgs; }) nico-cli;

  fleet-tools = (import ./apps/fleet.nix { inherit pkgs username; }).packages.fleet-tools;

  # nix-update runs on GitHub-hosted Linux. Expose this Darwin-only package
  # there so its fixed-output source can be prefetched without trying to build
  # an aarch64-darwin fetcher on Linux.
  ismc = pkgs.callPackage ./darwin/pkgs/ismc { };

  qemu-host-package = pkgs.qemu;
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  aurral = pkgs.callPackage ./nixos/srvarr/pkgs/aurral { };
  inherit (orgPackages)
    degoog
    degoog-devinside-extensions
    degoog-georgvwt-extensions
    degoog-official-extensions
    degoog-stackexchange-engine
    degoog-toolkit-extensions
    ;
  ebook-converter-cli = pkgs.callPackage ./nixos/srvarr/pkgs/ebook-converter-cli { };
  houndarr = pkgs.callPackage ./nixos/srvarr/pkgs/houndarr { };
}
