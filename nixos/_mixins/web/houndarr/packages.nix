{
  lib,
  pkgs,
  ...
}:
{
  options.services.houndarr = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./packages/houndarr { };
      description = "Houndarr package to run.";
    };

    tools.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./packages/houndarr-tools { };
      description = "Package providing Houndarr readiness and status helpers.";
    };
  };
}
