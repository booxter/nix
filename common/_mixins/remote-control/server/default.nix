{
  lib,
  system,
  ...
}:
let
  isDarwin = lib.hasSuffix "-darwin" system;
  isLinux = lib.hasSuffix "-linux" system;
in
{
  imports =
    lib.optionals isLinux [
      ./vnc.nix
      ./wayland.nix
      ./x11.nix
    ]
    ++ lib.optional isDarwin ./vnc-darwin.nix;

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
