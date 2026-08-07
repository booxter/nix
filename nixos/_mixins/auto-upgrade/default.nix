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
  hostname = config.networking.hostName;
  selectedPhase =
    if config.host.isProxmox then
      "hypervisor"
    else if hostname == upgradePolicy.cacheHost then
      "cache"
    else if config.host.isBuilder then
      "builder"
    else
      "workload";
  selectedRebootMode =
    if builtins.elem hostname upgradePolicy.manualRebootHosts then
      "manual"
    else if config.host.isCritical then
      "weekly-if-needed"
    else
      "after-upgrade";
  phasePolicy = upgradePolicy.phases.${config.host.autoUpgrade.phase};
  upgradeSchedule =
    if config.host.autoUpgrade.phase == "hypervisor" then
      {
        inherit (phasePolicy) cadence weekday;
        at = phasePolicy.atByHost.${hostname} or phasePolicy.defaultAt;
      }
    else
      phasePolicy.upgrade;
  formatClock =
    clock:
    let
      pad = value: if value < 10 then "0${toString value}" else toString value;
    in
    "${pad clock.hour}:${pad clock.minute}";
  renderSchedule =
    schedule:
    lib.optionalString (schedule.cadence == "weekly") "${schedule.weekday} " + formatClock schedule.at;
  renderRebootWindow = window: {
    lower = formatClock window.lower;
    upper = formatClock window.upper;
  };
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

  options.host.autoUpgrade = {
    phase = lib.mkOption {
      type = lib.types.enum [
        "builder"
        "cache"
        "hypervisor"
        "workload"
      ];
      default = selectedPhase;
      readOnly = true;
      internal = true;
      description = "Fleet maintenance phase selected for this host.";
    };

    rebootMode = lib.mkOption {
      type = lib.types.enum [
        "after-upgrade"
        "manual"
        "weekly-if-needed"
      ];
      default = selectedRebootMode;
      readOnly = true;
      internal = true;
      description = "How unattended upgrades may reboot this host.";
    };
  };

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
        dates = renderSchedule upgradeSchedule;
        inherit (upgradePolicy) persistent randomizedDelaySec;
        allowReboot = config.host.autoUpgrade.rebootMode == "after-upgrade";
        rebootWindow =
          if config.host.autoUpgrade.rebootMode == "weekly-if-needed" then
            null
          else
            renderRebootWindow phasePolicy.rebootWindow;
      };

      host.autoUpgrade.holds = upgradePolicy.holds;
    }
    (lib.mkIf
      (config.host.autoUpgrade.rebootMode == "weekly-if-needed" && config.system.autoUpgrade.enable)
      {
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
            OnCalendar = renderSchedule (upgradePolicy.weeklyReboot // { cadence = "weekly"; });
            RandomizedDelaySec = upgradePolicy.randomizedDelaySec;
            Persistent = upgradePolicy.persistent;
            Unit = "nixos-weekly-reboot-if-needed.service";
          };
        };
      }
    )
  ];
}
