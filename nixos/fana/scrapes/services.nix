{
  hostInventory,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  beastHostConfig = outputs.nixosConfigurations.beast.config;
  beastPrometheusEndpoints = beastHostConfig.host.observability.client.prometheusMtlsEndpoints;
  beastTargetHost = hostInventory.toNixosShortDnsName hostInventory.nixosHostSpecsByName.beast;
  lolekEndpoint = beastPrometheusEndpoints.lolek;
  sabnzbdHostConfig = outputs.nixosConfigurations.srvarr.config;
  sabnzbdEndpoint = sabnzbdHostConfig.host.observability.client.prometheusMtlsEndpoints.sabnzbd;
  sabnzbdTargetHost = hostInventory.toNixosShortDnsName hostInventory.nixosHostSpecsByName.srvarr;
  vikunjaHostConfig = outputs.nixosConfigurations.org.config;
  vikunjaTargetHost = hostInventory.toNixosShortDnsName hostInventory.nixosHostSpecsByName.org;
  vikunjaEndpoint = vikunjaHostConfig.host.observability.client.prometheusMtlsEndpoints.vikunja;
in
{
  scrapeConfigs = [
    {
      job_name = "smartctl";
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [
            "${beastTargetHost}:${toString beastPrometheusEndpoints.smartctl.port}"
          ];
          labels.instance = "beast";
        }
      ];
    }
    {
      job_name = "jellyfin";
      scrape_interval = "5s";
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [
            "${beastTargetHost}:${toString beastPrometheusEndpoints.jellyfin.port}"
          ];
          labels.instance = "beast";
        }
      ];
    }
    {
      job_name = "lolek";
      metrics_path = lolekEndpoint.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [
            "${beastTargetHost}:${toString lolekEndpoint.port}"
          ];
          labels.instance = "beast";
        }
      ];
    }
    {
      job_name = "sabnzbd";
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [
            "${sabnzbdTargetHost}:${toString sabnzbdEndpoint.port}"
          ];
          labels.instance = "srvarr";
        }
      ];
    }
    # TODO: Restore the beast IPMI scrape target when the local IPMI card is
    # back and the exporter is re-enabled on beast.
    {
      job_name = "vikunja";
      metrics_path = vikunjaEndpoint.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [ "${vikunjaTargetHost}:${toString vikunjaEndpoint.port}" ];
          labels.instance = "org";
        }
      ];
    }
  ];
}
