{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  upgradePolicy = hostInventory.autoUpgrade;
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
        flake = "${hostInventory.fleetRepository.flakeRef}#${config.networking.hostName}";
        flags = [
          "-L"
          "--show-trace"
        ];
        # Run inherited daily upgrades after the Monday Proxmox node window.
        dates = lib.mkDefault upgradePolicy.default.dates;
        inherit (upgradePolicy.default)
          allowReboot
          persistent
          randomizedDelaySec
          rebootWindow
          ;
      };

      host.autoUpgrade.holds = upgradePolicy.holds;
    }
    (lib.mkIf (config.host.isCritical && config.system.autoUpgrade.enable) {
      system.autoUpgrade = {
        allowReboot = lib.mkForce upgradePolicy.critical.allowReboot;
        rebootWindow = lib.mkForce upgradePolicy.critical.rebootWindow;
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
          OnCalendar = upgradePolicy.critical.weeklyReboot.dates;
          RandomizedDelaySec = upgradePolicy.critical.weeklyReboot.randomizedDelaySec;
          Persistent = upgradePolicy.critical.weeklyReboot.persistent;
          Unit = "nixos-weekly-reboot-if-needed.service";
        };
      };
    })
  ];
}
