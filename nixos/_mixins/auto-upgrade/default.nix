{
  config,
  hostname,
  lib,
  pkgs,
  utils,
  ...
}:
let
  autoUpgradeTools = pkgs.callPackage ./pkgs/auto-upgrade-tools {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  rebootIfNeeded = utils.escapeSystemdExecArgs [
    (lib.getExe autoUpgradeTools)
    "reboot-if-needed"
    "--shutdown-executable"
    "${config.systemd.package}/bin/shutdown"
  ];
in
{
  imports = [
    ./holds.nix
    ./metrics.nix
  ];

  config = lib.mkMerge [
    {
      _module.args.autoUpgradeTools = autoUpgradeTools;

      system.autoUpgrade = {
        enable = true;
        flake = "github:booxter/nix#${hostname}";
        flags = [
          "-L"
          "--show-trace"
        ];
        # Run inherited daily upgrades after the Monday Proxmox node window.
        dates = lib.mkDefault "05:15";
        randomizedDelaySec = "5min";
        persistent = false;
        allowReboot = true;
        rebootWindow = {
          lower = "04:00";
          upper = "06:00";
        };
      };

      host.autoUpgrade.holds = [
        {
          startDate = "2026-06-08";
          stopDate = "2026-06-28";
        }
      ];
    }
    (lib.mkIf (config.host.isCritical && config.system.autoUpgrade.enable) {
      system.autoUpgrade = {
        allowReboot = lib.mkForce false;
        rebootWindow = lib.mkForce null;
      };

      systemd.services.nixos-weekly-reboot-if-needed = {
        description = "Reboot once a week if the current NixOS profile needs it";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = rebootIfNeeded;
        };
      };

      systemd.timers.nixos-weekly-reboot-if-needed = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "Sat 04:00";
          RandomizedDelaySec = "5min";
          Persistent = false;
          Unit = "nixos-weekly-reboot-if-needed.service";
        };
      };
    })
  ];
}
