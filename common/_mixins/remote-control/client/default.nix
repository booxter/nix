{
  config,
  lib,
  system,
  ...
}:
let
  isDarwin = lib.hasSuffix "-darwin" system;
in
{
  imports =
    lib.optionals isDarwin [
      ./vnc.nix
      ./wayland.nix
    ]
    ++ [ ./x11.nix ];

  options.host.remote-control.client = {
    vnc.enable = lib.mkEnableOption "VNC remote-control client functionality";
    x11.enable = lib.mkEnableOption "X11 remote-control client functionality";
    wayland.enable = lib.mkEnableOption "Wayland remote-control client functionality";
  };

  config.assertions = [
    {
      assertion = !config.host.remote-control.client.vnc.enable || isDarwin;
      message = "host.remote-control.client.vnc currently requires Darwin";
    }
    {
      assertion = !config.host.remote-control.client.wayland.enable || isDarwin;
      message = "host.remote-control.client.wayland currently requires Darwin";
    }
  ];
}
