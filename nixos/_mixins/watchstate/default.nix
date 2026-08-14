{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.watchstate;
  jellyfin = config.host.jellyfin;
  libraryPath = if jellyfin == null then null else "${jellyfin.media.mountPoint}/library";
  absolutePath = lib.types.strMatching "^/.*";
  atomicFileWrites = pkgs.python3Packages.callPackage ../../../pkgs/atomic-file-writes { };
in
{
  imports = [
    ./assertions.nix
    ./auth.nix
    ./backups.nix
    ./jellarr.nix
    ./service.nix
    ./web.nix
  ];

  options.host.watchstate = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options.backupStagingDirectory = lib.mkOption {
          type = absolutePath;
          description = "Directory where WatchState archives are staged for Restic.";
        };
      }
    );
    default = null;
    description = "WatchState media synchronization service configuration.";
  };

  config._module.args.watchstateModel = {
    inherit cfg jellyfin libraryPath;
    backupStagingDirectory = if cfg == null then null else cfg.backupStagingDirectory;
    dataDirectory = "/var/lib/watchstate";
    localUrl = "http://127.0.0.1:8080";
    port = 8080;
    tools = pkgs.callPackage ./packages/tools { inherit atomicFileWrites; };
  };
}
