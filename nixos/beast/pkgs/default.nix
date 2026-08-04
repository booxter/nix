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

  jellarr = pkgs.callPackage ./jellarr {
    src = inputs.jellarr;
  };

  restic-cloud-usage = pkgs.callPackage ./restic-cloud-usage {
    inherit atomicFileWrites;
  };
}
