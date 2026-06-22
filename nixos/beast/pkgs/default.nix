{
  inputs,
  pkgs,
  ...
}:
{
  jellyfin-exporter = pkgs.callPackage ./jellyfin-exporter { };

  jellarr = pkgs.callPackage ./jellarr {
    src = inputs.jellarr;
  };
}
