# Per-site capacity and policy facts.
{
  home = {
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
