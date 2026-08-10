{
  facts,
  inputs,
  lib,
  ...
}:
{
  system.stateVersion = "25.11";

  imports = [
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
  ];

  host = {
    desktop.hyprland.enable = true;
    nix.builder = {
      enable = true;
      speedFactor = 200;
    };
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
          facts.public-keys.users.mair
          facts.public-keys.users.mmini
        ];
      };
    };
    network = {
      macAddress = "9c:bf:0d:00:fa:0a";
      primaryInterface = "enp191s0";
      reservation = {
        enable = true;
        address = "192.168.11.228";
      };
    };
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
