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
    vnc = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
    };
    x11 = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
    };
    wayland = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
    };
  };
}
