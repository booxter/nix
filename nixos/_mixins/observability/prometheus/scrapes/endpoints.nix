{
  hostInventory,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  endpointEntries = lib.concatMap (
    hostName:
    let
      hostConfig = outputs.nixosConfigurations.${hostName}.config;
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
          _: endpoint: endpoint.enable && endpoint.scrape.enable
        ) hostConfig.host.observability.metricsEndpoints
      )
  ) (builtins.attrNames outputs.nixosConfigurations);
  entriesByJob = lib.groupBy (entry: entry.endpoint.scrape.jobName) endpointEntries;
  unknownServices = lib.unique (
    builtins.concatMap (
      entry:
      lib.optional (
        entry.endpoint.scrape.service != null
        && !builtins.hasAttr entry.endpoint.scrape.service hostInventory.servicesById
      ) entry.endpoint.scrape.service
    ) endpointEntries
  );
  scrapeShape = entry: {
    path = entry.endpoint.path;
    interval = entry.endpoint.scrape.interval;
    timeout = entry.endpoint.scrape.timeout;
  };
  incompatibleJobs = builtins.attrNames (
    lib.filterAttrs (
      _: entries: builtins.length (lib.unique (map scrapeShape entries)) != 1
    ) entriesByJob
  );
  availabilityFor =
    entry:
    if entry.endpoint.scrape.service == null then
      entry.hostConfig.host.availability
    else
      hostInventory.servicesById.${entry.endpoint.scrape.service}.observability.availability;
  labelsFor =
    entry:
    {
      availability = availabilityFor entry;
      component = entry.endpoint.scrape.component;
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
    // lib.optionalAttrs (scrape.interval != null) {
      scrape_interval = scrape.interval;
    }
    // lib.optionalAttrs (scrape.timeout != null) {
      scrape_timeout = scrape.timeout;
    };
in
{
  assertions = [
    {
      assertion = unknownServices == [ ];
      message = "Prometheus metrics endpoints reference unknown inventory services: ${lib.concatStringsSep ", " unknownServices}";
    }
    {
      assertion = incompatibleJobs == [ ];
      message = "Prometheus metrics endpoints sharing a job must use the same path and timing: ${lib.concatStringsSep ", " incompatibleJobs}";
    }
  ];

  scrapeConfigs = lib.mapAttrsToList mkScrapeConfig entriesByJob;
}
