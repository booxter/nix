{
  hostInventory,
  lib,
  pkgs,
}:
let
  beastSpec = hostInventory.nixosHostSpecsByName.beast;
  frameSpec = hostInventory.nixosHostSpecsByName.frame;
  prx1Spec = hostInventory.nixosHostSpecsByName."prx1-lab";
  nutExporterPort = 9199;
  nutExporterVariables = lib.concatStringsSep "," [
    "battery.charge"
    "battery.charge.low"
    "battery.runtime"
    "battery.runtime.low"
    "input.voltage"
    "input.voltage.nominal"
    "ups.load"
    "ups.status"
  ];
  mkNutScrape =
    {
      jobName,
      spec,
    }:
    {
      job_name = jobName;
      metrics_path = "/ups_metrics";
      params = {
        # Use the stable LAN DNS hostname rather than .local/mDNS.
        server = [ (spec.dnsName or spec.name) ];
        ups = [ (hostInventory.toUpsName spec.name) ];
      };
      static_configs = [
        {
          targets = [ "127.0.0.1:${toString nutExporterPort}" ];
        }
      ];
      relabel_configs = [
        {
          source_labels = [ "__param_server" ];
          target_label = "instance";
        }
        {
          source_labels = [ "__param_server" ];
          target_label = "ups_server";
        }
        {
          source_labels = [ "__param_ups" ];
          target_label = "ups";
        }
      ];
    };
in
{
  exporterService = {
    description = "Prometheus exporter for NUT UPS servers";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.prometheus-nut-exporter}/bin/nut_exporter --web.listen-address=127.0.0.1:${toString nutExporterPort} --nut.vars_enable=${nutExporterVariables}";
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  scrapeConfigs = [
    (mkNutScrape {
      jobName = "nut-prx1";
      spec = prx1Spec;
    })
    (mkNutScrape {
      jobName = "nut-beast";
      spec = beastSpec;
    })
    (mkNutScrape {
      jobName = "nut-frame";
      spec = frameSpec;
    })
  ];
}
