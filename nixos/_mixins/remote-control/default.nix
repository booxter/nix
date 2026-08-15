{ lib, ... }:
{
  imports = [
    ./server/vnc.nix
    ./server/wayland.nix
    ./server/x11.nix
  ];

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
}
