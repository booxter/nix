{
  inputs,
  pkgs,
  ...
}:
let
  atomicFileWrites = pkgs.python3Packages.callPackage ../../../pkgs/atomic-file-writes { };
in
{
  backup-server-tools = pkgs.callPackage ./backup-server-tools { };

  jellyfin-exporter = pkgs.callPackage ./jellyfin-exporter { };

  jellyfin-tools = pkgs.callPackage ./jellyfin-tools { };

  jellarr = pkgs.callPackage ./jellarr {
    src = inputs.jellarr;
  };

  restic-tools = pkgs.callPackage ./restic-tools {
    inherit atomicFileWrites;
  };

  storage-observability = pkgs.callPackage ./storage-observability {
    inherit atomicFileWrites;
  };

  watchstate-tools = pkgs.callPackage ./watchstate-tools {
    inherit atomicFileWrites;
  };
}
