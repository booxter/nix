{
  lib,
  observabilityCatalog,
  prometheusMtlsTlsConfig,
}:
let
  endpointEntries = observabilityCatalog.endpoints;
  entriesByJob = lib.groupBy (endpoint: endpoint.jobName) endpointEntries;
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
  scrapeConfigs = lib.mapAttrsToList mkScrapeConfig entriesByJob;
}
