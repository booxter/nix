{
  config,
  facts,
  hostSpec,
  lib,
  ...
}:
let
  siteName = hostSpec.site or "home";
  site = if siteName == null then null else facts.sites.${siteName} or null;
in
{
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
