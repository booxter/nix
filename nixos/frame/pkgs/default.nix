pkgs: {
  fana-alertmanager-watchdog = pkgs.callPackage ./fana-alertmanager-watchdog {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  frame-observability = pkgs.callPackage ./frame-observability { };
}
