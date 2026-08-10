{
  inputs,
  pkgs,
  ...
}:
let
  atomicFileWrites = pkgs.python3Packages.callPackage ../../../pkgs/atomic-file-writes { };
in
{
  jellyfin-exporter = pkgs.callPackage ./jellyfin-exporter { };

  jellyfin-tools = pkgs.callPackage ./jellyfin-tools { };

  jellarr = pkgs.callPackage ./jellarr {
    src = inputs.jellarr;
  };

  watchstate-tools = pkgs.callPackage ./watchstate-tools {
    inherit atomicFileWrites;
  };
}
