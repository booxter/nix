{
  lib,
  pkgs,
  ...
}:
{
  options.services.jellyfin.tools.package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.callPackage ./pkgs/jellyfin-tools { };
    description = "Package providing Jellyfin backup and maintenance helpers.";
  };
}
