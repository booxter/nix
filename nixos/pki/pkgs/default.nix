pkgs:
let
  kanidmTools = pkgs.callPackage ./kanidm-tools { };
in
{
  kanidm-person-mail-provision = pkgs.callPackage ./kanidm-person-mail-provision { };

  kanidm-mail-sender-bootstrap = kanidmTools;

  oidc-synthetic-probe = pkgs.callPackage ./oidc-synthetic-probe { };

  reset-oidc = kanidmTools;

  unifi-sync = pkgs.callPackage ./unifi-sync { };

  uptimerobot-sync = pkgs.callPackage ./uptimerobot-sync { };

  wg-home-dns-sync = pkgs.callPackage ./wg-home-dns-sync { };
}
