{
  config,
  isLinux,
  lib,
  ...
}:
{
  imports = lib.optional isLinux ./x11.nix;

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

    vpn.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.remote-control.server.enable;
      description = "Whether to enable VPN remote-control server functionality.";
    };
  };
}
