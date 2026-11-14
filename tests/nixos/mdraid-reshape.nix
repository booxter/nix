{ pkgs, ... }:
let
  inherit (pkgs) lib;
  schedule = import ../../inventory/auto-upgrade.nix;
in
pkgs.testers.runNixOSTest {
  name = "mdraid-reshape";

  nodes.machine = {
    imports = [
      ../../nixos/_mixins/auto-upgrade/options.nix
      ../../nixos/_mixins/auto-upgrade/config.nix
      ../../nixos/_mixins/maintenance
      ../../nixos/_mixins/hardware/storage.nix
      ../../nixos/_mixins/hardware/mdraid.nix
    ];

    options.host.observability.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    options.host.observability.nodeExporter.textfile.directories = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };
    options.host.observability.nodeExporter.textfile.periodicProducers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };

    config = {
      _module.args.fleetInventory.autoUpgrade = schedule // {
        schedules.machine = schedule.schedules.beast;
      };
      host.hardware.storage.mdraid.enable = true;
      host.maintenance.vacations = lib.mkForce [
        {
          startDate = "2020-01-01";
          stopDate = "2020-01-03";
        }
      ];
      services.timesyncd.enable = false;
      # This test never runs Nix; avoid rebuilding the fleet's patched client.
      nix.package = pkgs.nixVersions.stable;
      environment.systemPackages = [
        pkgs.btrfs-progs
        pkgs.mdadm
      ];
      virtualisation = {
        memorySize = 2048;
        emptyDiskImages = [
          512
          512
          512
          512
          512
        ];
      };
      services.openssh.enable = true;
      virtualisation.fileSystems."/bulk" = {
        device = "/dev/disk/by-label/reshape-test";
        fsType = "btrfs";
        options = [
          "nofail"
          "x-systemd.device-timeout=10s"
        ];
      };
      systemd.services.bulk-consumer = {
        wantedBy = [ "multi-user.target" ];
        unitConfig.RequiresMountsFor = [ "/bulk" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/touch /bulk/consumer-started";
        };
      };

      # Exercise the real service conditions without downloading an upgrade or
      # rebooting the VM while the test is checking the guarded operation.
      systemd.services.nixos-upgrade.serviceConfig = {
        ExecStart = lib.mkForce "${pkgs.coreutils}/bin/touch /run/upgrade-ran";
        ExecStartPost = lib.mkForce [ ];
      };
      systemd.services.nixos-reboot-if-needed.serviceConfig.ExecStart =
        lib.mkForce "${pkgs.coreutils}/bin/touch /run/reboot-ran";
      systemd.timers.nixos-upgrade.wantedBy = lib.mkForce [ ];
      systemd.timers.nixos-reboot-if-needed.wantedBy = lib.mkForce [ ];

    };
  };

  testScript = builtins.readFile ./mdraid-reshape/test.py;
}
