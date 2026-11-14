{
  config,
  fleetInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  autoUpgradeTools = pkgs.callPackage ./package {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  hostname = config.networking.hostName;
  policy = fleetInventory.autoUpgrade.policy;
  # Keep host evaluation local; fleet constraints are checked against this
  # committed schedule by the auto-upgrade CI evaluation.
  schedule =
    fleetInventory.autoUpgrade.schedules.${hostname}
      or (throw "host '${hostname}' has no auto-upgrade schedule in fleet inventory");
  formatClock =
    clock:
    let
      pad = part: if part < 10 then "0${toString part}" else toString part;
    in
    "${pad clock.hour}:${pad clock.minute}";
  randomizedDelay = "${toString policy.randomizedDelayMinutes}min";
  rebootWindow = {
    lower = formatClock policy.allowedWindow.start;
    upper = formatClock policy.allowedWindow.end;
  };
  metricsEnabled = config.host.observability.enable;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile/auto-upgrade";
  toolCommand =
    arguments: utils.escapeSystemdExecArgs ([ (lib.getExe autoUpgradeTools) ] ++ arguments);
  rebootIfNeeded = toolCommand [
    "reboot-if-needed"
    "--shutdown-executable"
    "${config.systemd.package}/bin/shutdown"
  ];
  writeSuccessMetric = toolCommand [
    "write-success-metric"
    "--output"
    "${textfileDir}/nixos-upgrade.prom"
  ];
  writeRebootMetric = toolCommand [
    "write-reboot-metric"
    "--output"
    "${textfileDir}/nixos-reboot.prom"
    "--state"
    "/var/lib/nixos-reboot-metrics/pending-since"
  ];
  maintenanceGuards = builtins.attrValues config.host.maintenance.guards;
  maintenanceConditions = builtins.attrValues config.host.maintenance.holds;
in
{
  config = lib.mkMerge [
    {
      host.autoUpgrade = {
        claims.baseline = {
          switch.cadence = "daily";
          reboot.cadence = "daily";
        };
      };

      system.autoUpgrade = {
        enable = true;
        flake = "github:booxter/nix#${hostname}";
        flags = [
          "-L"
          "--show-trace"
        ];
        dates = schedule.switch;
        randomizedDelaySec = randomizedDelay;
        persistent = false;
        allowReboot = schedule.reboot.mode == "with-upgrade";
        rebootWindow = if schedule.reboot.mode == "with-upgrade" then rebootWindow else null;
      };

      systemd.services.nixos-upgrade.serviceConfig.TimeoutStartSec = "12h";
    }

    (lib.mkIf (maintenanceGuards != [ ]) {
      systemd.services.nixos-upgrade.serviceConfig.ExecStartPre = maintenanceGuards;
    })

    (lib.mkIf (schedule.reboot.mode == "scheduled") {
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
          OnCalendar = schedule.reboot.calendar;
          RandomizedDelaySec = randomizedDelay;
          Persistent = false;
          Unit = "nixos-reboot-if-needed.service";
        };
      };
    })

    (lib.mkIf (maintenanceConditions != [ ]) {
      systemd.services.nixos-upgrade.serviceConfig.ExecCondition = maintenanceConditions;
    })

    (lib.mkIf (maintenanceConditions != [ ] && schedule.reboot.mode == "scheduled") {
      systemd.services.nixos-reboot-if-needed.serviceConfig.ExecCondition = maintenanceConditions;
    })

    (lib.mkIf metricsEnabled {
      host.observability.nodeExporter.textfile.directories.auto-upgrade = textfileDir;

      systemd.services = {
        nixos-reboot-metrics = {
          description = "Record how long a NixOS reboot has been pending";
          serviceConfig = {
            Type = "oneshot";
            StateDirectory = "nixos-reboot-metrics";
            ExecStart = writeRebootMetric;
          };
        };
        nixos-upgrade.serviceConfig.ExecStartPost = "${writeSuccessMetric}";
      };

      systemd.timers.nixos-reboot-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "5min";
          Unit = "nixos-reboot-metrics.service";
        };
      };

      systemd.tmpfiles.rules = [
        "d ${textfileDir} 0755 root root - -"
        # Preserve the last upgrade result until the next successful upgrade.
        "C- ${textfileDir}/nixos-upgrade.prom 0644 root root - /var/lib/prometheus-node-exporter-textfile/nixos-upgrade.prom"
        "z ${textfileDir}/nixos-upgrade.prom 0644 root root - -"
      ];
    })
  ];
}
