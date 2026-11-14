{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  vacations = config.host.maintenance.vacations;
  tools = pkgs.callPackage ../auto-upgrade/package {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  toolsConfig = (pkgs.formats.json { }).generate "maintenance-vacations.json" {
    hostname = config.networking.hostName;
    holds = vacations;
  };
  command = arguments: utils.escapeSystemdExecArgs ([ (lib.getExe tools) ] ++ arguments);
  textfileDir = "/var/lib/prometheus-node-exporter-textfile/auto-upgrade";
  writeMetrics = command [
    "write-hold-metrics"
    "--config"
    toolsConfig
    "--output"
    "${textfileDir}/nixos-upgrade-hold.prom"
  ];
  isoDatePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$";
in
{
  options.host.maintenance.vacations = lib.mkOption {
    type =
      with lib.types;
      listOf (submodule {
        options = {
          startDate = lib.mkOption {
            type = str;
            description = "Inclusive local start date in YYYY-MM-DD format.";
          };
          stopDate = lib.mkOption {
            type = str;
            description = "Inclusive local stop date in YYYY-MM-DD format.";
          };
        };
      });
    default = [ ];
    description = "Vacation date ranges that hold unattended maintenance.";
  };

  config = lib.mkMerge [
    {
      host.maintenance.vacations = [
        {
          startDate = "2026-06-08";
          stopDate = "2026-06-28";
        }
      ];

      assertions = lib.concatMap (vacation: [
        {
          assertion = builtins.match isoDatePattern vacation.startDate != null;
          message = "Vacation startDate `${vacation.startDate}` must use YYYY-MM-DD.";
        }
        {
          assertion = builtins.match isoDatePattern vacation.stopDate != null;
          message = "Vacation stopDate `${vacation.stopDate}` must use YYYY-MM-DD.";
        }
        {
          assertion = vacation.startDate <= vacation.stopDate;
          message = "Vacation `${vacation.startDate}..${vacation.stopDate}` must not end before it starts.";
        }
      ]) vacations;
    }

    (lib.mkIf (vacations != [ ]) {
      host.maintenance.holds.vacations = command [
        "guard"
        "--config"
        toolsConfig
      ];
    })

    (lib.mkIf config.host.observability.enable {
      host.observability.nodeExporter.textfile.directories.auto-upgrade = textfileDir;

      # Refresh alert suppression immediately when a vacation is added or removed.
      system.activationScripts.nixosUpgradeHoldMetrics.text = writeMetrics;
      systemd.services.nixos-upgrade-hold-metrics = {
        description = "Write NixOS vacation hold metrics";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = writeMetrics;
        };
      };
      systemd.timers.nixos-upgrade-hold-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnCalendar = "hourly";
          Persistent = true;
          RandomizedDelaySec = "1min";
          Unit = "nixos-upgrade-hold-metrics.service";
        };
      };
    })
  ];
}
