{
  config,
  lib,
  ...
}:
{
  imports = [
    ./vnc.nix
    ./wayland.nix
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

  config = lib.mkIf (config.host.remote-control.client.x11 != null) {
    home-manager.users.${config.host.username} = {
      programs.remote-control.client.x11 = { };
      host.hm.xquartz.enable = true;
    };
  };
}
