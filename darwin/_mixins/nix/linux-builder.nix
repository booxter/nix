{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.nix.rosetta;
in
{
  options.host.nix.rosetta.acceptLicense = lib.mkEnableOption ''
    installation of Rosetta after accepting Apple's software license agreement
  '';

  config = {
    host.nix.nixpkgs.additional-builders = lib.filter (
      builder: builder.hostName == "linux-builder"
    ) config.nix.buildMachines;

    assertions = [
      {
        assertion = cfg.acceptLicense;
        message = "The Rosetta Linux builder requires host.nix.rosetta.acceptLicense";
      }
    ];

    nix.linux-builder = {
      enable = true;
      maxJobs = 4;
      package = pkgs.darwin.linux-builder-vz;
      # Both backends name their incompatible data disks nixos.qcow2.
      workingDirectory = "/var/lib/linux-builder-vz";
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      supportedFeatures = [
        "benchmark"
        "big-parallel"
        "kvm"
        "nixos-test"
      ];
      config.virtualisation.cores = 8;
      config.virtualisation.diskSize = lib.mkForce (40 * 1024);
      config.virtualisation.memorySize = lib.mkForce 8192;
      config.virtualisation.vz.nestedVirtualization = true;
    };

    launchd.daemons.linux-builder.serviceConfig = {
      StandardOutPath = "/var/log/nix-darwin/linux-builder.log";
      StandardErrorPath = "/var/log/nix-darwin/linux-builder.log";
    };

    # Temporary migration: remove once hosts have retired their QEMU disks.
    # launchd reload failures are ignored upstream, so check the loaded service
    # and open files before deleting anything in postActivation.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      cleanup_old_builder_disk() {
        local disk=/var/lib/linux-builder/nixos.qcow2
        local service disk_users

        [ -f "$disk" ] || return 0

        if ! service=$(/bin/launchctl print system/org.nixos.linux-builder); then
          echo "Skipping old builder disk cleanup: cannot inspect the service." >&2
          return 0
        fi

        if ! echo "$service" | /usr/bin/grep -Fxq $'\tstate = running' ||
           ! echo "$service" | /usr/bin/grep -Fxq $'\tworking directory = /var/lib/linux-builder-vz'; then
          echo "Skipping old builder disk cleanup: vz builder is not running." >&2
          return 0
        fi

        if disk_users=$(/usr/sbin/lsof -nP -F p -- "$disk" 2>&1); then
          echo "Skipping old builder disk cleanup: disk is still open." >&2
        elif [ -n "$disk_users" ]; then
          echo "Skipping old builder disk cleanup: lsof failed: $disk_users" >&2
        else
          echo "Removing unused QEMU builder disk: $disk"
          /bin/rm -f -- "$disk"
        fi
      }

      cleanup_old_builder_disk
    '';

    system.activationScripts.preActivation.text = lib.mkIf cfg.acceptLicense (
      lib.mkBefore ''
        if ! /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
          echo "Installing Rosetta and accepting its license."
          /usr/sbin/softwareupdate --install-rosetta --agree-to-license
        fi
      ''
    );
  };
}
