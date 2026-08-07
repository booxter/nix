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
  selectedRebootMode =
    if config.host.boot.requiresInteractiveUnlock then
      "manual"
    else
      hostSpec.autoUpgrade.rebootMode or "after-upgrade";
  phasePolicy = upgradePolicy.phases.${config.host.autoUpgrade.phase};
  upgradeSchedule =
    if config.host.autoUpgrade.phase == "hypervisor" then
      {
        inherit (phasePolicy) cadence weekday;
        at =
          phasePolicy.atByHost.${hostname}
            or (throw "Proxmox host ${hostname} has no explicit auto-upgrade slot");
      }
    else
      phasePolicy.upgrade;
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
        dates = upgradePolicy.renderSchedule upgradeSchedule;
        inherit (upgradePolicy) persistent randomizedDelaySec;
        allowReboot = config.host.autoUpgrade.rebootMode == "after-upgrade";
        rebootWindow =
          if config.host.autoUpgrade.rebootMode == "weekly-if-needed" then
            null
          else
            upgradePolicy.renderRebootWindow phasePolicy.rebootWindow;
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
            !config.host.boot.requiresInteractiveUnlock || config.host.autoUpgrade.rebootMode == "manual";
          message = "Hosts requiring interactive disk unlock must not reboot automatically.";
        }
        {
          assertion =
            !config.host.isProxmox
            || (upgradeSchedule.cadence == "weekly" && config.host.autoUpgrade.rebootMode == "after-upgrade");
          message = "Proxmox hosts must have one weekly conditional reboot opportunity.";
        }
      ];
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
