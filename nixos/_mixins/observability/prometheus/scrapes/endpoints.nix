{
  config,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  localHost = config.networking.hostName;
  configurations = outputs.nixosConfigurations // {
    ${localHost} = { inherit config; };
  };
  endpointEntries = lib.concatMap (
    hostName:
    let
      hostConfig = configurations.${hostName}.config;
    in
    lib.mapAttrsToList
      (endpointName: endpoint: {
        inherit
          endpoint
          endpointName
          hostConfig
          hostName
          ;
      })
      (
        lib.filterAttrs (
          _: endpoint: endpoint.scrape != null
        ) hostConfig.host.observability.prometheusEndpoints
      )
  ) (builtins.attrNames configurations);
  entriesByJob = lib.groupBy (entry: entry.endpoint.scrape.jobName) endpointEntries;
  scrapeShape = entry: {
    inherit (entry.endpoint) path;
    inherit (entry.endpoint.scrape) interval metricRelabelConfigs timeout;
  };
  incompatibleJobs = builtins.attrNames (
    lib.filterAttrs (
      _: entries: builtins.length (lib.unique (map scrapeShape entries)) != 1
    ) entriesByJob
  );
  labelsFor =
    entry:
    {
      inherit (entry.endpoint.scrape) availability component;
      instance = entry.hostName;
      realm = entry.hostConfig.host.realm;
      scrape_profile = entry.endpoint.scrape.profile;
    }
    // lib.optionalAttrs (entry.endpoint.scrape.service != null) {
      service = entry.endpoint.scrape.service;
    }
    // entry.endpoint.scrape.labels;
  mkScrapeConfig =
    jobName: entries:
    let
      first = lib.head entries;
      scrape = first.endpoint.scrape;
    in
    {
      job_name = jobName;
      metrics_path = first.endpoint.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = map (entry: {
        targets = [ "${entry.hostName}:${toString entry.endpoint.port}" ];
        labels = labelsFor entry;
      }) entries;
    }
    // lib.optionalAttrs (scrape.interval != null) { scrape_interval = scrape.interval; }
    // lib.optionalAttrs (scrape.timeout != null) { scrape_timeout = scrape.timeout; }
    // lib.optionalAttrs (scrape.metricRelabelConfigs != [ ]) {
      metric_relabel_configs = scrape.metricRelabelConfigs;
    };
in
{
  assertions = [
    {
      assertion = incompatibleJobs == [ ];
      message = "Prometheus endpoints sharing a job must use the same path and timing: ${lib.concatStringsSep ", " incompatibleJobs}";
    }
  ];
  scrapeConfigs = lib.mapAttrsToList mkScrapeConfig entriesByJob;
}
