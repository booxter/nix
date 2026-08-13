{
  lib,
  pkgs,
  ...
}:
let
  absolutePath = lib.types.strMatching "^/.*";
in
{
  options.host.seerr = {
    enable = lib.mkEnableOption "Seerr media request manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.seerr;
      description = "Seerr package to run.";
    };

    stateDir = lib.mkOption {
      type = absolutePath;
      default = "/var/lib/seerr";
    };

    publicHostName = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "seerr";
      internal = true;
    };

    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "seerr";
      internal = true;
    };

    backups.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };
}
