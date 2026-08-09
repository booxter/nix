{
  config,
  hostInventory,
  hostSpec,
  lib,
  ...
}:
let
  siteName = hostSpec.site or null;
  site = if siteName == null then null else hostInventory.sites.${siteName} or null;
  positiveNumber = lib.types.addCheck lib.types.number (value: value > 0);
in
{
  options.host.site = {
    name = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = siteName;
      readOnly = true;
      internal = true;
      description = "Physical site assigned by host inventory.";
    };

    uplink = {
      downloadMbit = lib.mkOption {
        type = with lib.types; nullOr positiveNumber;
        default = if site == null then null else site.uplink.downloadMbit;
        readOnly = true;
        internal = true;
        description = "Physical site download capacity in Mbit/s.";
      };

      uploadMbit = lib.mkOption {
        type = with lib.types; nullOr positiveNumber;
        default = if site == null then null else site.uplink.uploadMbit;
        readOnly = true;
        internal = true;
        description = "Physical site upload capacity in Mbit/s.";
      };
    };
  };

  config.assertions = [
    {
      assertion = siteName == null || site != null;
      message = "host '${config.networking.hostName}' references unknown site '${toString siteName}'";
    }
  ];
}
