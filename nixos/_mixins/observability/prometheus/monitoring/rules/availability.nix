{ lib }:
let
  inherit (import ./lib.nix { inherit lib; }) mkAlert mkGroup mkScrapeDown;
in
{
  groups = [
    (mkGroup {
      name = "observability-availability";
      rules = [
        (mkAlert {
          name = "NodeTelemetryDown";
          expr = ''max without (scrape_expectation) (up{job=~"node-local|node-mtls",scrape_expectation!="intermittent"}) < 1'';
          for = "10m";
          severity = "warning";
          category = "observability";
          summary = "Node telemetry down: {{ $labels.instance }}";
          description = "Prometheus has been unable to scrape {{ $labels.job }} on {{ $labels.instance }} for 10 minutes.";
        })
        (mkScrapeDown {
          name = "DNSProbeScrapeDown";
          selector = ''up{job="blackbox-dns"}'';
          for = "5m";
          category = "observability";
          summary = "DNS probe scrape down: {{ $labels.instance }}";
          description = "Prometheus has been unable to scrape the blackbox DNS probe target {{ $labels.instance }} for 5 minutes.";
        })
        (mkScrapeDown {
          name = "SmartctlExporterDown";
          selector = ''up{job="smartctl"}'';
          for = "5m";
          category = "storage";
          summary = "SMART exporter down: {{ $labels.instance }}";
          description = "Prometheus has been unable to scrape the SMART exporter on {{ $labels.instance }} for 5 minutes.";
        })
        (mkAlert {
          name = "BeastHDDTemperatureTelemetryMissing";
          expr = ''absent(smartctl_device_temperature{instance="beast",temperature_type="current",device=~"sd[a-z]+"}) and on(instance) up{job="smartctl",instance="beast"} == 1'';
          for = "15m";
          severity = "warning";
          category = "storage";
          summary = "Beast HDD temperature telemetry missing";
          description = "The SMART exporter on beast is reachable, but it has not been exporting HDD temperature metrics for /dev/sdX for 15 minutes.";
        })
        (mkAlert {
          name = "BeastDiskBayMappingMissing";
          expr = ''absent(host_observability_disk_bay_info{job="node-mtls",instance="beast"}) and on(instance) up{job="node-mtls",instance="beast"} == 1'';
          for = "15m";
          severity = "warning";
          category = "storage";
          summary = "Beast disk bay mapping missing";
          description = "The beast disk bay mapping metric is missing even though node telemetry is reachable.";
        })
      ];
    })
  ];
}
