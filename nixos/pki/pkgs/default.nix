pkgs: {
  unifi-sync = pkgs.callPackage ./unifi-sync { };

  wg-home-dns-sync = pkgs.callPackage ./wg-home-dns-sync { };
}
