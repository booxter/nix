{ lib, ... }:
{
  imports = [
    ./server/vnc.nix
    ./server/wayland.nix
    ./server/x11.nix
  ];

  options.host.remote-control.server = {
    x11.enable = lib.mkEnableOption "X11 remote-control server functionality";
    wayland.enable = lib.mkEnableOption "Wayland remote-control server functionality";

    vnc = {
      enable = lib.mkEnableOption "VNC remote-control server functionality";

      basePort = lib.mkOption {
        type = lib.types.port;
        default = 5900;
        description = "First TCP port allocated to a VNC display.";
      };
    };
  };
}
