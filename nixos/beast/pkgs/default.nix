{ pkgs, ... }:
{
  jellyfin-exporter = pkgs.callPackage ./jellyfin-exporter { };
}
