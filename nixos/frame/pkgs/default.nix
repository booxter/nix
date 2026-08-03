pkgs: {
  fana-alertmanager-watchdog = pkgs.callPackage ./fana-alertmanager-watchdog { };
  frame-observability = pkgs.callPackage ./frame-observability { };
}
