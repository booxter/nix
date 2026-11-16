{
  realms.home.prometheusServer = "fana";

  # Scrape only CAKE textfile metrics at high resolution on these nodes.
  cakeSources = [ "srvarr" ];

  blackboxSources = {
    beast = { };
    frame = { };
    srvarr = {
      networkScope = "vpn";
      dnsResolver = "10.128.0.1";
      directHttpComparison = true;
    };
  };

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
    mair.laptop = true;
  };

  endpoints = {
    srvarr.alloy = {
      port = 12346;
      path = "/metrics";
      jobName = "alloy";
      profile = "infrastructure";
      component = "alloy";
    };
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
