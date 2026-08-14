{ lib, pkgs, ... }:
let
  cueSplitterPackage = pkgs.callPackage ./pkgs/lidarr-cue-splitter {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
in
{
  imports = [
    (import ../servarr { name = "lidarr"; })
    ./cue-splitter.nix
  ];

  options.host.lidarr.cueSplitter = {
    package = lib.mkOption {
      type = lib.types.package;
      default = cueSplitterPackage;
      internal = true;
    };
  };
}
