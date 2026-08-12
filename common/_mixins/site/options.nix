{ hostSpec, lib, ... }:
let
  positiveNumber = lib.types.addCheck lib.types.number (value: value > 0);
in
{
  options.host.site = {
    name = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = hostSpec.site or "home";
      defaultText = lib.literalExpression ''hostSpec.site or "home"'';
      description = "Physical site containing this host, or null for hosts without a physical site.";
    };

    timeZone = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "IANA timezone of the physical site.";
    };

    uplink = {
      downloadMbit = lib.mkOption {
        type = with lib.types; nullOr positiveNumber;
        default = null;
        description = "Physical site download capacity in Mbit/s.";
      };

      uploadMbit = lib.mkOption {
        type = with lib.types; nullOr positiveNumber;
        default = null;
        description = "Physical site upload capacity in Mbit/s.";
      };
    };

    policies = {
      backups.maxUploadMbit = lib.mkOption {
        type = with lib.types; nullOr positiveNumber;
        default = null;
        description = "Maximum site upload rate allocated to backups in Mbit/s.";
      };

      downloaders.maxDownloadMbit = lib.mkOption {
        type = with lib.types; nullOr positiveNumber;
        default = null;
        description = "Maximum site download rate allocated to downloaders in Mbit/s.";
      };
    };
  };
}
