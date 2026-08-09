{
  inputs,
  lib,
  ...
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
in
{
  system.stateVersion = "25.11";

  imports = [
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
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
    ollama = {
      enable = true;
      enableMetrics = true;
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

  # It caused hangs on shutdown.
  security.lsm = lib.mkForce [
    "landlock"
    "yama"
  ];
}
