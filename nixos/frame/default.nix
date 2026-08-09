{
  inputs,
  lib,
  pkgs,
  ...
}:
let
  framePkgs = import ./pkgs pkgs;
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
in
{
  system.stateVersion = "25.11";

  _module.args.framePkgs = framePkgs;

  imports = [
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
    ./ollama.nix
  ];

  host = {
    desktop.hyprland.enable = true;
    hardware = {
      drmCard = "card1";
      displayMode = {
        width = 3840;
        height = 2160;
        refreshRate = 60;
      };
      scale = 1.5;
      displays = [
        {
          position = "left";
          connector = "DP-4";
          x = 0;
          primary = true;
        }
        {
          position = "right";
          connector = "DP-2";
          x = 2560;
        }
      ];
      gpu = {
        vendors = [ "amd" ];
        compute = "rocm";
        collector.enable = true;
      };
    };
    # This host needs manual local or remote unlock after boot; never
    # auto-reboot on upgrades.
    luks = {
      enable = true;
      remoteUnlock = {
        enable = true;
        kernelModules = [ "r8169" ];
        authorizedKeys = [
          (readPublicKey ../../public-keys/users/mair.pub)
          (readPublicKey ../../public-keys/users/mmini.pub)
        ];
      };
    };
    network.primaryInterface = "enp191s0";
    observability = {
      alertmanagerWatchdog.enable = true;
      blackbox.remote.enable = true;
    };
    remote-control.server = {
      vnc = {
        enable = true;
        basePort = 5933;
      };
      wayland.enable = true;
      x11.enable = true;
    };
    ups.server = {
      description = "APC UPS 1500VA";
    };
  };

  # systemd's global bpf-restrict-fs link took roughly three minutes to detach
  # during reboot while the kernel waited for a Tasks RCU grace period. No
  # service on this host uses RestrictFileSystems=, so keep the other default
  # LSMs without enabling the BPF LSM solely for that unused systemd feature.
  security.lsm = lib.mkForce [
    "landlock"
    "yama"
  ];
}
