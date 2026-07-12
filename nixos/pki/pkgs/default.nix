pkgs: {
  kanidm-mail-sender-bootstrap = pkgs.callPackage ./kanidm-mail-sender-bootstrap { };

  oidc-synthetic-probe = pkgs.callPackage ./oidc-synthetic-probe { };

  unifi-sync = pkgs.callPackage ./unifi-sync { };

  uptimerobot-sync = pkgs.callPackage ./uptimerobot-sync { };

  wg-home-dns-sync = pkgs.callPackage ./wg-home-dns-sync { };
}
