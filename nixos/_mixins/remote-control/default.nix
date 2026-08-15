{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./server/vnc.nix ];

  options.host.remote-control.server = {
    x11 = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
    };
    wayland = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
    };
    vnc = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options.basePort = lib.mkOption {
            type = lib.types.port;
            default = 5900;
            description = "First TCP port allocated to a VNC display.";
          };
        }
      );
      default = null;
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (config.host.remote-control.server.x11 != null) {
      services.openssh.settings.X11Forwarding = true;
    })
    (lib.mkIf (config.host.remote-control.server.wayland != null) {
      environment.systemPackages = [ pkgs.waypipe ];
    })
  ];
}
