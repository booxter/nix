pkgs: {
  kanidm-mail-sender-bootstrap = pkgs.callPackage ./kanidm-mail-sender-bootstrap { };

  unifi-sync = pkgs.callPackage ./unifi-sync { };

  wg-home-dns-sync = pkgs.callPackage ./wg-home-dns-sync { };
}
