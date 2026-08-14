{
  lib,
  ...
}:
{
  imports = [
    ./vnc.nix
    ./wayland.nix
    ./x11.nix
  ];

  options.host.remote-control.client = {
    vnc.enable = lib.mkEnableOption "VNC remote-control client functionality";
    x11.enable = lib.mkEnableOption "X11 remote-control client functionality";
    wayland.enable = lib.mkEnableOption "Wayland remote-control client functionality";
  };
}
