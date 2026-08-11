{
  autoUpgradeTools,
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  hostname = config.networking.hostName;
  cfg = config.host.autoUpgrade;
  metricsCfg = config.host.observability.nixosUpgrade;
  textfileDir = config.host.observability.nodeExporter.textfile.directory;
  toolsConfig = (pkgs.formats.json { }).generate "auto-upgrade-tools.json" {
    inherit hostname;
    inherit (cfg) holds;
  };
  upgradeHoldGuard = utils.escapeSystemdExecArgs [
    (lib.getExe autoUpgradeTools)
    "guard"
    "--config"
    toolsConfig
  ];
  writeHoldMetrics = utils.escapeSystemdExecArgs [
    (lib.getExe autoUpgradeTools)
    "write-hold-metrics"
    "--config"
    toolsConfig
    "--output"
    "${textfileDir}/nixos-upgrade-hold.prom"
  ];
in
{
  imports = [ ./holds/assertions.nix ];

  options.host.autoUpgrade = {
    holds = lib.mkOption {
      type =
        with lib.types;
        listOf (submodule {
          options = {
            startDate = lib.mkOption {
              type = str;
              example = "2026-07-06";
              description = "Inclusive local start date for a NixOS auto-upgrade hold window in YYYY-MM-DD format.";
            };

            stopDate = lib.mkOption {
              type = str;
              example = "2026-07-19";
              description = "Inclusive local stop date for a NixOS auto-upgrade hold window in YYYY-MM-DD format.";
            };
          };
        });
      default = [ ];
      example = [
        {
          startDate = "2026-07-06";
          stopDate = "2026-07-19";
        }
      ];
      description = ''
        Inclusive local-date ranges during which unattended NixOS auto-upgrade
        maintenance should be skipped. Timers still fire on schedule, but the
        upgrade service and separately scheduled reboot service exit cleanly
        before they perform changes.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && cfg.holds != [ ]) {
      systemd.services.nixos-upgrade.serviceConfig.ExecCondition = upgradeHoldGuard;
    })
    (lib.mkIf (cfg.holds != [ ] && cfg.reboot.mode == "scheduled" && cfg.enable) {
      systemd.services.nixos-reboot-if-needed.serviceConfig.ExecCondition = upgradeHoldGuard;
    })
    (lib.mkIf metricsCfg.enable {
      # Update immediately on switch so adding or removing a hold changes alert
      # suppression without waiting for the next hourly timer tick.
      system.activationScripts.nixosUpgradeHoldMetrics.text = writeHoldMetrics;

      systemd.services.nixos-upgrade-hold-metrics = {
        description = "Write NixOS auto-upgrade hold metrics";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = writeHoldMetrics;
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
