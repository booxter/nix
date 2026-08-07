{
  config,
  hostInventory,
  hostSpec,
  lib,
  pkgs,
  utils,
  ...
}:
let
  upgradePolicy = hostInventory.autoUpgrade;
  hostname = config.networking.hostName;
  realmAttic = hostInventory.realms.${config.host.realm}.services.attic or null;
  isCacheHost = realmAttic != null && realmAttic.serverHost == hostname;
  selectedPhase =
    if config.host.isProxmox then
      "hypervisor"
    else if isCacheHost then
      "cache"
    else if config.host.isBuilder then
      "builder"
    else
      "workload";
  selectedRebootPolicy =
    if config.host.boot.requiresInteractiveUnlock then
      "manual-reboot"
    else
      hostSpec.autoUpgrade.rebootPolicy or "after-upgrade-if-needed";
  phasePolicy = upgradePolicy.phases.${config.host.autoUpgrade.phase};
  upgradeSchedule = phasePolicy.upgrade;
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

    rebootPolicy = lib.mkOption {
      type = lib.types.enum [
        "after-upgrade-if-needed"
        "manual-reboot"
        "weekly-if-needed"
      ];
      default = selectedRebootPolicy;
      readOnly = true;
      internal = true;
      description = "When unattended maintenance may reboot this host.";
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
        dates = upgradePolicy.renderSchedule upgradeSchedule;
        inherit (upgradePolicy) persistent randomizedDelaySec;
        allowReboot = config.host.autoUpgrade.rebootPolicy == "after-upgrade-if-needed";
        rebootWindow =
          if config.host.autoUpgrade.rebootPolicy == "weekly-if-needed" then
            null
          else
            upgradePolicy.renderRebootWindow (upgradePolicy.rebootWindowFor upgradeSchedule.at);
      };

      host.autoUpgrade.holds = upgradePolicy.holds;

      assertions = [
        {
          assertion = !config.host.isProxmox || config.host.autoUpgrade.phase == "hypervisor";
          message = "Proxmox hosts must use the hypervisor auto-upgrade phase.";
        }
        {
          assertion = !isCacheHost || config.host.autoUpgrade.phase == "cache";
          message = "The realm Nix cache host must use the cache auto-upgrade phase.";
        }
        {
          assertion =
            !config.host.isBuilder
            || builtins.elem config.host.autoUpgrade.phase [
              "builder"
              "hypervisor"
            ];
          message = "Nix builders must use a build-infrastructure auto-upgrade phase.";
        }
        {
          assertion =
            !config.host.boot.requiresInteractiveUnlock
            || config.host.autoUpgrade.rebootPolicy == "manual-reboot";
          message = "Hosts requiring interactive disk unlock must not reboot automatically.";
        }
        {
          assertion =
            !config.host.isProxmox
            || (
              upgradeSchedule.cadence == "weekly"
              && config.host.autoUpgrade.rebootPolicy == "after-upgrade-if-needed"
            );
          message = "Proxmox hosts must have one weekly conditional reboot opportunity.";
        }
      ];
    }
    (lib.mkIf
      (config.host.autoUpgrade.rebootPolicy == "weekly-if-needed" && config.system.autoUpgrade.enable)
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
            OnCalendar = upgradePolicy.renderSchedule upgradePolicy.weeklyReboot;
            RandomizedDelaySec = upgradePolicy.randomizedDelaySec;
            Persistent = upgradePolicy.persistent;
            Unit = "nixos-weekly-reboot-if-needed.service";
          };
        };
      }
    )
  ];
}
