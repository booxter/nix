{
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  beastHostConfig = outputs.nixosConfigurations.beast.config;
  beastPrometheusEndpoints = beastHostConfig.host.observability.client.prometheusMtlsEndpoints;
  lolekEndpoint = beastPrometheusEndpoints.lolek;
  sabnzbdHostConfig = outputs.nixosConfigurations.srvarr.config;
  sabnzbdEndpoint = sabnzbdHostConfig.host.observability.client.prometheusMtlsEndpoints.sabnzbd;
  vikunjaHostConfig = outputs.nixosConfigurations.org.config;
  vikunjaHost = vikunjaHostConfig.host.dnsName;
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
            "${beastHostConfig.host.dnsName}:${toString beastPrometheusEndpoints.smartctl.port}"
          ];
          labels.instance = beastHostConfig.host.dnsName;
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
            "${beastHostConfig.host.dnsName}:${toString beastPrometheusEndpoints.jellyfin.port}"
          ];
          labels.instance = beastHostConfig.host.dnsName;
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
            "${beastHostConfig.host.dnsName}:${toString lolekEndpoint.port}"
          ];
          labels.instance = beastHostConfig.host.dnsName;
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
            "${sabnzbdHostConfig.host.dnsName}:${toString sabnzbdEndpoint.port}"
          ];
          labels.instance = sabnzbdHostConfig.host.dnsName;
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
          targets = [ "${vikunjaHost}:${toString vikunjaEndpoint.port}" ];
          labels.instance = vikunjaHost;
        }
      ];
    }
  ];
}
