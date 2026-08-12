{
  facts,
  hostSpec,
  lib,
  ...
}:
let
  siteName = hostSpec.site or "home";
  site = if siteName == null then null else facts.sites.${siteName} or null;
  positiveNumber = lib.types.addCheck lib.types.number (value: value > 0);
in
{
  imports = [ ./assertions.nix ];

  options.host.site = {
    name = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = siteName;
      readOnly = true;
      internal = true;
      description = "Physical site assigned by host facts.";
    };

    timeZone = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = if site == null then null else site.timeZone;
      readOnly = true;
      internal = true;
      description = "IANA timezone of the physical site.";
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

}
