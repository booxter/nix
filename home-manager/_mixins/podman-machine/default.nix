{
  config,
  isDarwin,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.podman-machine;
  machineConfig = pkgs.writeText "podman-machine.conf" ''
    [machine]
    cpus = ${toString cfg.cpus}
    disk_size = ${toString cfg.diskSizeGiB}
    memory = ${toString cfg.memoryMiB}
    provider = ${builtins.toJSON cfg.provider}
  '';
  podmanMachineEnsure = pkgs.callPackage ./pkgs/podman-machine-ensure {
    podman = cfg.package;
  };
  ensureArguments = [
    (lib.getExe podmanMachineEnsure)
    "--name"
    cfg.name
    "--provider"
    cfg.provider
    "--cpus"
    (toString cfg.cpus)
    "--memory"
    (toString cfg.memoryMiB)
    "--disk-size"
    (toString cfg.diskSizeGiB)
    "--containers-config"
    "${machineConfig}"
  ];
in
{
  options.programs.podman-machine = {
    enable = lib.mkEnableOption "declarative Podman machine management on Darwin";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.podman;
      description = "Podman package used to manage the machine.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "podman-machine-default";
      description = "Name of the managed Podman machine.";
    };

    provider = lib.mkOption {
      type = lib.types.enum [
        "applehv"
        "libkrun"
      ];
      default = "libkrun";
      description = "Virtualization provider used by the managed Podman machine.";
    };

    cpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Number of virtual CPUs assigned to the managed machine.";
    };

    memoryMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
      description = "Memory in MiB assigned to the managed machine.";
    };

    diskSizeGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 100;
      description = "Minimum disk size in GiB assigned to the managed machine.";
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to create, reconcile, and start the machine at login.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = isDarwin;
        message = "programs.podman-machine is only supported on Darwin.";
      }
    ];

    home.packages = [
      cfg.package
      podmanMachineEnsure
    ];

    xdg.configFile."containers/containers.conf.d/50-podman-machine.conf".source = machineConfig;

    launchd.agents.podman-machine = lib.mkIf cfg.autoStart {
      enable = true;
      config = {
        ProgramArguments = ensureArguments;
        RunAtLoad = true;
        AbandonProcessGroup = true;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/podman-machine.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/podman-machine.log";
      };
    };
  };
}
