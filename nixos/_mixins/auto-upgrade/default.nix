{
  config,
  hostSpecName,
  lib,
  pkgs,
  ...
}:
let
  rebootIfNeeded = pkgs.writeShellScript "nixos-weekly-reboot-if-needed" ''
    set -euo pipefail

    booted="$(${pkgs.coreutils}/bin/readlink /run/booted-system/{initrd,kernel,kernel-modules})"
    current="$(${pkgs.coreutils}/bin/readlink /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules})"

    if [ "$booted" = "$current" ]; then
      echo "Booted kernel, initrd, and modules match the current system profile; no reboot needed."
      exit 0
    fi

    echo "Booted kernel, initrd, or modules differ from the current system profile; scheduling reboot."
    ${config.systemd.package}/bin/shutdown -r +1 "Rebooting to activate staged NixOS kernel, initrd, or module upgrade"
  '';
in
{
  imports = [
    ./holds.nix
    ./metrics.nix
  ];

  config = lib.mkMerge [
    {
      system.autoUpgrade = {
        enable = true;
        flake = "github:booxter/nix#${hostSpecName}";
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
