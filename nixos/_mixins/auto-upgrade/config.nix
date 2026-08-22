{
  autoUpgradeModel,
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = autoUpgradeModel;
  autoUpgradeTools = pkgs.callPackage ./package {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  cfg = config.host.autoUpgrade;
  hostname = config.networking.hostName;
  metricsEnabled = config.host.observability.enable;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  toolsConfig = (pkgs.formats.json { }).generate "auto-upgrade-tools.json" {
    inherit hostname;
    inherit (cfg) holds;
  };
  toolCommand =
    arguments: utils.escapeSystemdExecArgs ([ (lib.getExe autoUpgradeTools) ] ++ arguments);
  rebootIfNeeded = toolCommand [
    "reboot-if-needed"
    "--shutdown-executable"
    "${config.systemd.package}/bin/shutdown"
  ];
  upgradeHoldGuard = toolCommand [
    "guard"
    "--config"
    toolsConfig
  ];
  writeHoldMetrics = toolCommand [
    "write-hold-metrics"
    "--config"
    toolsConfig
    "--output"
    "${textfileDir}/nixos-upgrade-hold.prom"
  ];
  writeSuccessMetric = toolCommand [
    "write-success-metric"
    "--output"
    "${textfileDir}/nixos-upgrade.prom"
  ];
  maintenanceGuards = builtins.attrValues config.host.maintenance.guards;
in
{
  config = lib.mkMerge [
    {
      host.autoUpgrade = {
        claims.baseline = {
          switch.cadence = "daily";
          reboot.cadence = "daily";
        };
        holds = [
          {
            startDate = "2026-06-08";
            stopDate = "2026-06-28";
          }
        ];
      };

      system.autoUpgrade = {
        enable = true;
        flake = "github:booxter/nix#${hostname}";
        flags = [
          "-L"
          "--show-trace"
        ];
        dates = model.plan.switch.calendar;
        randomizedDelaySec = model.randomizedDelay;
        persistent = false;
        allowReboot = model.plan.reboot.mode == "with-upgrade";
        rebootWindow = if model.plan.reboot.mode == "with-upgrade" then model.rebootWindow else null;
      };

      systemd.services.nixos-upgrade.serviceConfig.TimeoutStartSec = "12h";
    }

    (lib.mkIf (maintenanceGuards != [ ]) {
      systemd.services.nixos-upgrade.serviceConfig.ExecStartPre = maintenanceGuards;
    })

    (lib.mkIf (model.plan.reboot.mode == "scheduled") {
      systemd.services.nixos-reboot-if-needed = {
        description = "Reboot on schedule if the current NixOS profile needs it";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = rebootIfNeeded;
          ExecStartPre = maintenanceGuards;
          TimeoutStartSec = lib.mkIf (maintenanceGuards != [ ]) "infinity";
        };
      };

      systemd.timers.nixos-reboot-if-needed = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = model.plan.reboot.scheduledCalendar;
          RandomizedDelaySec = model.randomizedDelay;
          Persistent = false;
          Unit = "nixos-reboot-if-needed.service";
        };
      };
    })

    (lib.mkIf (cfg.holds != [ ]) {
      systemd.services.nixos-upgrade.serviceConfig.ExecCondition = upgradeHoldGuard;
    })

    (lib.mkIf (cfg.holds != [ ] && model.plan.reboot.mode == "scheduled") {
      systemd.services.nixos-reboot-if-needed.serviceConfig.ExecCondition = upgradeHoldGuard;
    })

    (lib.mkIf metricsEnabled {
      # Update immediately on switch so adding or removing a hold changes alert
      # suppression without waiting for the next hourly timer tick.
      system.activationScripts.nixosUpgradeHoldMetrics.text = writeHoldMetrics;

      systemd.services = {
        nixos-upgrade.serviceConfig.ExecStartPost = "${writeSuccessMetric}";
        nixos-upgrade-hold-metrics = {
          description = "Write NixOS auto-upgrade hold metrics";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = writeHoldMetrics;
          };
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

      systemd.tmpfiles.rules = [
        "d ${textfileDir} 0755 root root - -"
        "z ${textfileDir}/nixos-upgrade.prom 0644 root root - -"
      ];
    })
  ];
}
