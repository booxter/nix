{
  pkgs,
  ...
}:
let
  atomicFileWrites = pkgs.python3Packages.callPackage ../../../pkgs/atomic-file-writes { };
in
{
  backup-server-tools = pkgs.callPackage ../../_mixins/backups/server/pkgs/backup-server-tools { };

  watchstate-tools = pkgs.callPackage ./watchstate-tools {
    inherit atomicFileWrites;
  };
}
