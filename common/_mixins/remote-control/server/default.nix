{
  config,
  isLinux,
  lib,
  ...
}:
{
  imports = lib.optionals isLinux [
    ./vnc.nix
    ./wayland.nix
    ./x11.nix
  ];

  options.remote-control.server = {
    enable = lib.mkEnableOption "remote-control server functionality";

    x11.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.remote-control.server.enable;
      description = "Whether to enable X11 remote-control server functionality.";
    };

    wayland.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.remote-control.server.enable;
      description = "Whether to enable Wayland remote-control server functionality.";
    };

    vnc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.remote-control.server.enable;
        description = "Whether to enable VNC remote-control server functionality.";
      };

      basePort = lib.mkOption {
        type = lib.types.port;
        default = 5900;
        description = "First TCP port allocated to a VNC display.";
      };
    };
  };
}
