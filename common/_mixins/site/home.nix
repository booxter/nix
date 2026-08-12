{ config, lib, ... }:
lib.mkIf (config.host.site.name == "home") {
  host.site = {
    timeZone = lib.mkDefault "America/New_York";

    uplink = {
      downloadMbit = lib.mkDefault 1000;
      uploadMbit = lib.mkDefault 40;
    };

    policies = {
      backups.maxUploadMbit = lib.mkDefault 10;
      downloaders.maxDownloadMbit = lib.mkDefault 400;
    };
  };
}
