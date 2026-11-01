{ inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.virtualisation;
  hostPkgs = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfreePredicate = package: lib.getName package == "tart";
  };
  runner = pkgs.callPackage ../../../apps/macos-vm {
    pythonRuffCheckHook = pkgs.callPackage ../../../pkgs/python-ruff-check-hook { };
    tart = hostPkgs.tart;
  };
  specification = (pkgs.formats.json { }).generate "darwin-vm.json" {
    name = cfg.name;
    system = config.system.build.toplevel;
    inherit (cfg) cores graphics;
    memory_size = cfg.memorySize;
  };
in
{
  options.virtualisation = {
    name = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*";
      default = config.networking.hostName;
      description = "VM identity within a checkout. The name macos is reserved.";
    };
    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Number of virtual CPUs.";
    };
    memorySize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
      description = "Guest memory in MiB.";
    };
    graphics = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the guest display when running the VM.";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.name != "macos";
        message = "virtualisation.name must not use the reserved plain VM target macos";
      }
      {
        assertion = pkgs.stdenv.hostPlatform.system == "aarch64-darwin";
        message = "macOS VMs require an aarch64-darwin configuration";
      }
      {
        assertion = cfg.memorySize >= 1024;
        message = "macOS VMs require at least 1024 MiB memory";
      }
    ];

    # The derivation retains the guest closure. Restore images and mutable
    # disks are prepared by the runner, outside the Nix build sandbox.
    system.build.vm = pkgs.writeShellApplication {
      name = "run-${cfg.name}-vm";
      text = ''
        exec ${lib.getExe runner} --configuration ${specification} "$@"
      '';
    };
  };
}
