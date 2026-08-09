{
  config,
  hostInventory,
  hostSpec,
  lib,
  ...
}:
let
  siteName = hostSpec.site or "home";
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

    policies = {
      backups.maxUploadMbit = lib.mkOption {
        type = with lib.types; nullOr positiveNumber;
        default = if site == null then null else site.policies.backups.maxUploadMbit;
        readOnly = true;
        internal = true;
        description = "Maximum site upload rate allocated to backups in Mbit/s.";
      };

      downloaders.maxDownloadMbit = lib.mkOption {
        type = with lib.types; nullOr positiveNumber;
        default = if site == null then null else site.policies.downloaders.maxDownloadMbit;
        readOnly = true;
        internal = true;
        description = "Maximum site download rate allocated to downloaders in Mbit/s.";
      };
    };
  };

  config.assertions = [
    {
      assertion = siteName == null || site != null;
      message = "host '${config.networking.hostName}' references unknown site '${toString siteName}'";
    }
  ]
  ++ lib.optionals (site != null) [
    {
      assertion = site.policies.backups.maxUploadMbit <= site.uplink.uploadMbit;
      message = "site '${siteName}' backup policy must not exceed its upload capacity";
    }
    {
      assertion = site.policies.downloaders.maxDownloadMbit <= site.uplink.downloadMbit;
      message = "site '${siteName}' downloader policy must not exceed its download capacity";
    }
  ];
}
