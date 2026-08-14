{ lib, ... }:
let
  extensionRegistration = lib.types.submodule {
    options = {
      extension = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Upstream extension path implementing this catalog entry.";
      };
      source = lib.mkOption {
        type =
          with lib.types;
          nullOr (oneOf [
            package
            path
            str
          ]);
        default = null;
        description = "Source for a non-official Degoog extension.";
      };
      settings = lib.mkOption {
        type = with lib.types; attrsOf anything;
        default = { };
        description = "Managed settings contributed by this extension.";
      };
      secretNames = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        default = [ ];
        description = "Degoog SOPS secret names consumed by this extension.";
      };
    };
  };
in
{
  options.host.degoog = {
    enable = lib.mkEnableOption "Degoog search aggregator";

    catalog = {
      engines = lib.mkOption {
        type = lib.types.attrsOf extensionRegistration;
        default = { };
        internal = true;
        description = "Registered Degoog search engines keyed by deployment-facing names.";
      };
      features = lib.mkOption {
        type = lib.types.attrsOf extensionRegistration;
        default = { };
        internal = true;
        description = "Registered Degoog features keyed by deployment-facing names.";
      };
      themes = lib.mkOption {
        type = lib.types.attrsOf extensionRegistration;
        default = { };
        internal = true;
        description = "Registered Degoog themes keyed by deployment-facing names.";
      };
    };

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
