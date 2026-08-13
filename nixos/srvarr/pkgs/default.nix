pkgs: {
  dynamic-ip-updater = pkgs.callPackage ./dynamic-ip-updater {
    atomicFileWrites = pkgs.atomic-file-writes;
  };

  letterboxd-list-radarr = pkgs.callPackage ./letterboxd-list-radarr { };

  lidarr-cue-splitter = pkgs.callPackage ./lidarr-cue-splitter {
    atomicFileWrites = pkgs.atomic-file-writes;
  };

}
