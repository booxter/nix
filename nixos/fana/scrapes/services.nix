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
  orgHostConfig = outputs.nixosConfigurations.org.config;
  orgTargetHost = hostInventory.toNixosShortDnsName hostInventory.nixosHostSpecsByName.org;
  litellmEndpoint = orgHostConfig.host.observability.client.prometheusMtlsEndpoints.litellm;
  openWebuiEndpoint = orgHostConfig.host.observability.client.prometheusMtlsEndpoints."open-webui";
  paperlessEndpoint = orgHostConfig.host.observability.client.prometheusMtlsEndpoints.paperless;
  searchlessEndpoint = orgHostConfig.host.observability.client.prometheusMtlsEndpoints.searchless;
  vikunjaEndpoint = orgHostConfig.host.observability.client.prometheusMtlsEndpoints.vikunja;
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
      job_name = "litellm";
      metrics_path = litellmEndpoint.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [ "${orgTargetHost}:${toString litellmEndpoint.port}" ];
          labels.instance = "org";
        }
      ];
    }
    {
      job_name = "open-webui";
      metrics_path = openWebuiEndpoint.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [ "${orgTargetHost}:${toString openWebuiEndpoint.port}" ];
          labels.instance = "org";
        }
      ];
    }
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
      job_name = "searchless";
      metrics_path = searchlessEndpoint.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [ "${orgTargetHost}:${toString searchlessEndpoint.port}" ];
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
