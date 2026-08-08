pkgs:
let
  unifiSync = pkgs.callPackage ../../_mixins/unifi-sync/package { };
in
{
  step-ca-bootstrap = pkgs.callPackage ./step-ca-bootstrap { };

  wg-home-dns-sync = pkgs.callPackage ./wg-home-dns-sync { inherit unifiSync; };
}
