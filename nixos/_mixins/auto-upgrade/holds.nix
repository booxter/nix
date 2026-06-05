{
  config,
  hostname,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.autoUpgrade;
  metricsCfg = config.host.observability.nixosUpgrade;
  isoDatePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$";
  upgradeHoldGuard = pkgs.writeShellScript "nixos-upgrade-hold-guard" ''
    set -euo pipefail

    today="$(${pkgs.coreutils}/bin/date +%F)"

    ${lib.concatMapStringsSep "\n" (hold: ''
      if [[ ! "$today" < "${hold.startDate}" && ! "$today" > "${hold.stopDate}" ]]; then
        echo "Skipping NixOS auto-upgrade maintenance on ${hostname}: ''${today} is within hold ${hold.startDate}..${hold.stopDate}." >&2
        exit 1
      fi
    '') cfg.holds}

    exit 0
  '';
  writeHoldMetrics = pkgs.writeShellScript "write-nixos-upgrade-hold-metrics" ''
    set -euo pipefail

    today="$(${pkgs.coreutils}/bin/date +%F)"
    active=0
    hold_start=0
    hold_stop=0

    ${lib.concatMapStringsSep "\n" (hold: ''
      if [ "$active" -eq 0 ] && [[ ! "$today" < "${hold.startDate}" && ! "$today" > "${hold.stopDate}" ]]; then
        active=1
        hold_start="$(${pkgs.coreutils}/bin/date -d "${hold.startDate} 00:00:00" +%s)"
        hold_stop="$(${pkgs.coreutils}/bin/date -d "${hold.stopDate} 23:59:59" +%s)"
      fi
    '') cfg.holds}

    ${pkgs.coreutils}/bin/mkdir -p ${metricsCfg.textfileDir}
    tmp_file="$(${pkgs.coreutils}/bin/mktemp ${metricsCfg.textfileDir}/nixos-upgrade-hold.prom.XXXXXX)"
    trap '${pkgs.coreutils}/bin/rm -f "$tmp_file"' EXIT

    cat >"$tmp_file" <<EOF
    # HELP node_nixos_upgrade_hold_active Whether NixOS auto-upgrade is currently suppressed by a declared hold.
    # TYPE node_nixos_upgrade_hold_active gauge
    node_nixos_upgrade_hold_active $active
    # HELP node_nixos_upgrade_hold_start_time_seconds Unix time for the active NixOS auto-upgrade hold start, or 0 when no hold is active.
    # TYPE node_nixos_upgrade_hold_start_time_seconds gauge
    node_nixos_upgrade_hold_start_time_seconds $hold_start
    # HELP node_nixos_upgrade_hold_stop_time_seconds Unix time for the active NixOS auto-upgrade hold stop, or 0 when no hold is active.
    # TYPE node_nixos_upgrade_hold_stop_time_seconds gauge
    node_nixos_upgrade_hold_stop_time_seconds $hold_stop
    EOF

    ${pkgs.coreutils}/bin/chmod 0644 "$tmp_file"
    ${pkgs.coreutils}/bin/mv "$tmp_file" ${metricsCfg.textfileDir}/nixos-upgrade-hold.prom
  '';
in
{
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
        upgrade service and delayed critical-host reboot service exit cleanly
        before they perform changes.
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.concatMap (hold: [
        {
          assertion = builtins.match isoDatePattern hold.startDate != null;
          message = "host.autoUpgrade.holds startDate `${hold.startDate}` must use YYYY-MM-DD.";
        }
        {
          assertion = builtins.match isoDatePattern hold.stopDate != null;
          message = "host.autoUpgrade.holds stopDate `${hold.stopDate}` must use YYYY-MM-DD.";
        }
        {
          assertion = hold.startDate <= hold.stopDate;
          message = "host.autoUpgrade.holds range `${hold.startDate}..${hold.stopDate}` must not end before it starts.";
        }
      ]) cfg.holds;
    }
    (lib.mkIf (cfg.holds != [ ]) {
      systemd.services.nixos-upgrade.serviceConfig.ExecCondition = upgradeHoldGuard;
    })
    (lib.mkIf (cfg.holds != [ ] && config.host.isCritical && config.system.autoUpgrade.enable) {
      systemd.services.nixos-weekly-reboot-if-needed.serviceConfig.ExecCondition = upgradeHoldGuard;
    })
    (lib.mkIf metricsCfg.enable {
      # Update immediately on switch so adding or removing a hold changes alert
      # suppression without waiting for the next hourly timer tick.
      system.activationScripts.nixosUpgradeHoldMetrics.text = ''
        ${writeHoldMetrics}
      '';

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
