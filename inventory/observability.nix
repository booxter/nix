{
  realms.home.prometheusServer = "fana";

  blackboxSources = [
    "beast"
    "frame"
  ];

  dashboardOverrides = {
    beast = {
      gpuVendor = "intel";
      diskBays = {
        rows = 5;
        columns = 3;
      };
      backupServer = true;
    };
    frame.gpuVendor = "amd";
  };

  endpoints = {
    beast = {
      lolek = {
        port = 9568;
        path = "/metrics";
        jobName = "lolek";
        profile = "application";
        component = "lolek";
        service = "lolek";
      };
      smartctl = {
        port = 9633;
        path = "/metrics";
        jobName = "smartctl";
        profile = "hardware";
        component = "smartctl";
      };
    };
    gw.wg-home = {
      port = 9586;
      path = "/metrics";
      jobName = "wireguard";
      profile = "network";
      component = "wireguard";
      wireguardNetwork = "home";
    };
  };
}
