{
  config,
  hostname,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.autoUpgrade;
  isoDatePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$";
  upgradeHoldGuard = pkgs.writeShellScript "nixos-upgrade-hold-guard" ''
    set -euo pipefail

    today="$(${pkgs.coreutils}/bin/date +%F)"

    ${lib.concatMapStringsSep "\n" (hold: ''
      if [[ ! "$today" < "${hold.startDate}" && ! "$today" > "${hold.stopDate}" ]]; then
        echo "Skipping nixos-upgrade on ${hostname}: ''${today} is within hold ${hold.startDate}..${hold.stopDate}." >&2
        exit 1
      fi
    '') cfg.holds}

    exit 0
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
        Inclusive local-date ranges during which `nixos-upgrade.service` should
        be skipped. Timers still fire on schedule, but the upgrade service exits
        cleanly before it starts the actual upgrade.
      '';
    };
  };

  config = lib.mkIf (cfg.holds != [ ]) {
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

    systemd.services.nixos-upgrade.serviceConfig.ExecCondition = upgradeHoldGuard;
  };
}
