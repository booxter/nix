{
  config,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  fleetServices = import ../../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  discoveredMetrics = builtins.filter (metric: metric.value.discover) fleetServices.metrics;
  mkWebMetricScrape =
    metric:
    {
      job_name = metric.value.jobName;
      metrics_path = metric.value.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [ "${metric.owner}:${toString metric.value.port}" ];
          labels = {
            instance = metric.owner;
            service = metric.serviceId;
          }
          // metric.value.labels;
        }
      ];
    }
    // lib.optionalAttrs (metric.value.scrapeInterval != null) {
      scrape_interval = metric.value.scrapeInterval;
    };
  standaloneScrapes = [
    {
      job_name = "smartctl";
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [
            "beast:${toString outputs.nixosConfigurations.beast.config.host.observability.prometheusEndpoints.smartctl.port}"
          ];
          labels.instance = "beast";
        }
      ];
    }
    {
      job_name = "lolek";
      metrics_path =
        outputs.nixosConfigurations.beast.config.host.observability.prometheusEndpoints.lolek.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = [
        {
          targets = [
            "beast:${toString outputs.nixosConfigurations.beast.config.host.observability.prometheusEndpoints.lolek.port}"
          ];
          labels.instance = "beast";
        }
      ];
    }
  ];
in
{
  scrapeConfigs = standaloneScrapes ++ map mkWebMetricScrape discoveredMetrics;
}
