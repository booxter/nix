{
  hostInventory,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  beastHostConfig = outputs.nixosConfigurations.beast.config;
  beastPrometheusEndpoints = beastHostConfig.host.observability.prometheusEndpoints;
  beastTargetHost = hostInventory.nixosHosts.beast.name;
  jellyfinService = hostInventory.servicesById.jellyfin;
  jellyfinHost = hostInventory.serviceHost jellyfinService;
  jellyfinHostConfig = outputs.nixosConfigurations.${jellyfinHost}.config;
  jellyfinEndpoint = jellyfinHostConfig.host.observability.prometheusEndpoints.jellyfin;
  jellyfinTargetHost = hostInventory.nixosHosts.${jellyfinHost}.name;
  lolekService = hostInventory.servicesById.lolek;
  lolekHost = hostInventory.serviceHost lolekService;
  lolekHostConfig = outputs.nixosConfigurations.${lolekHost}.config;
  lolekEndpoint = lolekHostConfig.host.observability.prometheusEndpoints.lolek;
  lolekTargetHost = hostInventory.nixosHosts.${lolekHost}.name;
  homeAssistantService = hostInventory.servicesById.home;
  homeHost = hostInventory.serviceHost homeAssistantService;
  homeHostConfig = outputs.nixosConfigurations.${homeHost}.config;
  homeTargetHost = hostInventory.nixosHosts.${homeHost}.name;
  homeAssistantEndpoint = homeHostConfig.host.observability.prometheusEndpoints.home-assistant;
  sabnzbdHostConfig = outputs.nixosConfigurations.srvarr.config;
  sabnzbdEndpoint = sabnzbdHostConfig.host.observability.prometheusEndpoints.sabnzbd;
  sabnzbdTargetHost = hostInventory.nixosHosts.srvarr.name;
  orgHostConfig = outputs.nixosConfigurations.org.config;
  orgTargetHost = hostInventory.nixosHosts.org.name;
  paperlessEndpoint = orgHostConfig.host.observability.prometheusEndpoints.paperless;
  vikunjaEndpoint = orgHostConfig.host.observability.prometheusEndpoints.vikunja;
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
            "${jellyfinTargetHost}:${toString jellyfinEndpoint.port}"
          ];
          labels.instance = jellyfinHost;
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
            "${lolekTargetHost}:${toString lolekEndpoint.port}"
          ];
          labels.instance = lolekHost;
        }
      ];
    }
    {
      job_name = "home-assistant";
      metrics_path = homeAssistantEndpoint.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [
            "${homeTargetHost}:${toString homeAssistantEndpoint.port}"
          ];
          labels.instance = homeHost;
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
      job_name = "paperless";
      metrics_path = paperlessEndpoint.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [ "${orgTargetHost}:${toString paperlessEndpoint.port}" ];
          labels.instance = "org";
        }
      ];
    }
    {
      job_name = "vikunja";
      metrics_path = vikunjaEndpoint.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [ "${orgTargetHost}:${toString vikunjaEndpoint.port}" ];
          labels.instance = "org";
        }
      ];
    }
  ];
}
