{
  autoUpgradeTools,
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.host.autoUpgrade;
  guards = config.host.maintenance.guards;
  rebootIfNeeded = utils.escapeSystemdExecArgs [
    (lib.getExe autoUpgradeTools)
    "reboot-if-needed"
    "--shutdown-executable"
    "${config.systemd.package}/bin/shutdown"
  ];
  guardsBefore =
    operations:
    builtins.attrValues (
      lib.filterAttrs (
        _: guard: lib.any (operation: builtins.elem operation guard.before) operations
      ) guards
    );
  upgradeGuards = guardsBefore (
    [ "upgrade" ] ++ lib.optional (cfg.reboot.mode == "with-upgrade") "reboot"
  );
  rebootGuards = guardsBefore [ "reboot" ];
  commands = selectedGuards: map (guard: guard.command) selectedGuards;
  waitsIndefinitely = selectedGuards: lib.any (guard: guard.waitIndefinitely) selectedGuards;
in
{
  config = lib.mkMerge [
    {
      system.autoUpgrade = {
        enable = true;
        flake = "github:booxter/nix#${config.networking.hostName}";
        flags = [
          "-L"
          "--show-trace"
        ];
        dates = cfg.schedule.calendar;
        randomizedDelaySec = cfg.schedule.randomizedDelay;
        persistent = false;
        allowReboot = cfg.reboot.mode == "with-upgrade";
        rebootWindow =
          if cfg.reboot.mode == "with-upgrade" then
            {
              inherit (cfg.reboot.window) lower upper;
            }
          else
            null;
      };
    }
    (lib.mkIf (upgradeGuards != [ ]) {
      systemd.services.nixos-upgrade.serviceConfig = {
        ExecStartPre = commands upgradeGuards;
        TimeoutStartSec = lib.mkIf (waitsIndefinitely upgradeGuards) "infinity";
      };
    })
    (lib.mkIf (cfg.reboot.mode == "scheduled") {
      systemd.services.nixos-reboot-if-needed = {
        description = "Reboot on schedule if the current NixOS profile needs it";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = rebootIfNeeded;
          ExecStartPre = commands rebootGuards;
          TimeoutStartSec = lib.mkIf (waitsIndefinitely rebootGuards) "infinity";
        };
      };

      systemd.timers.nixos-reboot-if-needed = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.reboot.calendar;
          RandomizedDelaySec = cfg.reboot.randomizedDelay;
          Persistent = false;
          Unit = "nixos-reboot-if-needed.service";
        };
      };
    })
  ];
}
