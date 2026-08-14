{ lib, ... }:
{
  options.host.degoog = {
    enable = lib.mkEnableOption "Degoog search aggregator";

    engines = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = [ ];
      description = "Search engines selected from the Degoog engine catalog.";
    };

    features = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = [ ];
      description = "Optional capabilities selected from the Degoog feature catalog.";
    };

    theme = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "Theme selected from the Degoog theme catalog.";
    };

    integrations = {
      jellyfin = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "NixOS host providing Jellyfin to its Degoog extension.";
      };

      romm = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "NixOS host providing RomM to its Degoog extension.";
      };
    };
  };
}
