{
  lib,
  observabilityInventory,
  prometheusMtlsTlsConfig,
}:
let
  endpointEntries = builtins.concatLists (
    map (inventory: builtins.attrValues inventory.endpoints) (
      builtins.attrValues observabilityInventory.nixos
    )
  );
  entriesByJob = lib.groupBy (endpoint: endpoint.jobName) endpointEntries;
  scrapeShape = endpoint: {
    inherit (endpoint)
      interval
      metricRelabelConfigs
      path
      ;
  };
  incompatibleJobs = builtins.attrNames (
    lib.filterAttrs (
      _: entries: builtins.length (lib.unique (map scrapeShape entries)) != 1
    ) entriesByJob
  );
  mkScrapeConfig =
    jobName: entries:
    let
      first = lib.head entries;
    in
    {
      job_name = jobName;
      metrics_path = first.path;
      scheme = "https";
      tls_config = prometheusMtlsTlsConfig;
      static_configs = map (entry: {
        targets = [ entry.target ];
        inherit (entry) labels;
      }) entries;
    }
    // lib.optionalAttrs (first.interval != null) { scrape_interval = first.interval; }
    // lib.optionalAttrs (first.metricRelabelConfigs != [ ]) {
      metric_relabel_configs = first.metricRelabelConfigs;
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
