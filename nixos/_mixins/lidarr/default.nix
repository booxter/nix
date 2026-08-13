{ lib, pkgs, ... }:
let
  cueSplitterPackage = pkgs.callPackage ./pkgs/lidarr-cue-splitter {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
in
{
  imports = [
    (import ../servarr {
      name = "lidarr";
      apiGroup = "lidarr-api";
      addUserToApiGroup = false;
    })
    ./cue-splitter.nix
  ];

  options.host.lidarr.cueSplitter = {
    enable = lib.mkEnableOption "automatic splitting and importing of CUE images";

    package = lib.mkOption {
      type = lib.types.package;
      default = cueSplitterPackage;
      internal = true;
    };
  };
}
