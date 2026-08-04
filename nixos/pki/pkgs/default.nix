pkgs:
let
  kanidmTools = pkgs.callPackage ./kanidm-tools { };
  unifiSync = pkgs.callPackage ./unifi-sync { };
in
{
  kanidm-person-mail-provision = pkgs.callPackage ./kanidm-person-mail-provision { };

  kanidm-mail-sender-bootstrap = kanidmTools;

  oidc-synthetic-probe = pkgs.callPackage ./oidc-synthetic-probe { };

  reset-oidc = kanidmTools;

  step-ca-bootstrap = pkgs.callPackage ./step-ca-bootstrap { };

  unifi-sync = unifiSync;

  uptimerobot-sync = pkgs.callPackage ./uptimerobot-sync { };

  wg-home-dns-sync = pkgs.callPackage ./wg-home-dns-sync { inherit unifiSync; };
}
