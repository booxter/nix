{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cgroupRoot = "/sys/fs/cgroup/system.slice/nix-daemon.service";
in
{
  config = lib.mkIf (config.host.nix.builder != null) {
    boot.kernel.sysctl."vm.swappiness" = 10;
    host.autoUpgrade.claims.builder = {
      switch.cadence = "weekly";
      reboot.cadence = "weekly";
      availabilityGroup = "builders:${config.host.realm}";
    };
    nix.settings = {
      auto-allocate-uids = true;
      use-cgroups = true;
      extra-experimental-features = [
        "auto-allocate-uids"
        "cgroups"
      ];
      extra-system-features = [
        "devnet"
        "uid-range"
      ];
      extra-sandbox-paths = [ "/dev/net" ];
    };
    swapDevices = [
      {
        device = "/var/lib/swapfile";
        size = 16 * 1024;
        randomEncryption.enable = true;
      }
    ];
    systemd.services = {
      # The upstream unit delegates its cgroup and Nix moves the daemon into a
      # child cgroup, but neither enables the delegated controllers in the
      # service root's cgroup.subtree_control. Enable them after that move so
      # Nix's per-build child cgroups expose memory and I/O accounting files.
      # Keep this separate from ExecStartPost so a metrics setup failure cannot
      # prevent the Nix daemon from serving builds.
      nix-builder-cgroup-setup = {
        description = "Enable accounting controllers for Nix build cgroups";
        after = [ "nix-daemon.service" ];
        requires = [ "nix-daemon.service" ];
        partOf = [ "nix-daemon.service" ];
        wantedBy = [
          "multi-user.target"
          "nix-daemon.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = utils.escapeSystemdExecArgs [
            (lib.getExe' pkgs.nix-builder-metrics "nix-builder-cgroup-setup")
            "--cgroup-root"
            cgroupRoot
          ];
        };
      };
    };
  };
}
