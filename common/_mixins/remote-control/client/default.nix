{
  config,
  isDarwin,
  lib,
  ...
}:
{
  imports =
    lib.optionals isDarwin [
      ./vnc.nix
      ./wayland.nix
    ]
    ++ [ ./x11.nix ];

  options.host.remote-control.client = {
    enable = lib.mkEnableOption "remote-control client functionality";

    vnc.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to enable VNC remote-control client functionality.";
    };

    x11.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to enable X11 remote-control client functionality.";
    };

    wayland.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to enable Wayland remote-control client functionality.";
    };
  };

  config = {
    assertions = [
      {
        assertion = !config.host.remote-control.client.vnc.enable || isDarwin;
        message = "host.remote-control.client.vnc currently requires Darwin";
      }
      {
        assertion = !config.host.remote-control.client.wayland.enable || isDarwin;
        message = "host.remote-control.client.wayland currently requires Darwin";
      }
    ];

    host.remote-control.client = {
      vnc.enable = lib.mkDefault config.host.remote-control.client.enable;
      x11.enable = lib.mkDefault config.host.remote-control.client.enable;
      wayland.enable = lib.mkDefault config.host.remote-control.client.enable;
    };
  };
}
