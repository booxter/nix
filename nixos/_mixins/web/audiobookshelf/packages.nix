{
  lib,
  pkgs,
  ...
}:
{
  options.services.audiobookshelf.tools.package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.callPackage ./packages/audiobookshelf-tools { };
    description = "Package providing Audiobookshelf configuration helpers.";
  };
}
