{ inputs, pkgs }:
let
  inherit (pkgs) lib;
  testPaths =
    lib.mapAttrs'
      (fileName: _: lib.nameValuePair (lib.removeSuffix ".nix" fileName) (./nixos + "/${fileName}"))
      (
        lib.filterAttrs (fileName: type: type == "regular" && lib.hasSuffix ".nix" fileName) (
          builtins.readDir ./nixos
        )
      );
in
lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
  lib.mapAttrs (_: path: import path { inherit inputs pkgs; }) testPaths
)
