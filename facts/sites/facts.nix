# Physical-site facts and policies.
{
  home = {
    timeZone = "America/New_York";

    uplink = {
      downloadMbit = 1000;
      uploadMbit = 40;
    };

    policies = {
      backups.maxUploadMbit = 10;
      downloaders.maxDownloadMbit = 400;
    };
  };
}
