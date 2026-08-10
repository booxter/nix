pkgs:
let
  unifiSync = pkgs.callPackage ./unifi-sync { };
in
{
  unifi-sync = unifiSync;
  wg-home-dns-sync = pkgs.callPackage ./wg-home-dns-sync { inherit unifiSync; };
}
