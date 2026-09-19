{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.nixpkgs.hostPlatform) isDarwin;
  cfg = config.programs.remote-control.client;
  remoteControlRunners = pkgs.callPackage ./pkgs { };
in
{
  options.programs.remote-control.client = {
    x11 = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
    };
    wayland = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
    };
  };

  config = {
    assertions =
      lib.optional (cfg.wayland != null) {
        assertion = isDarwin;
        message = "programs.remote-control.client.wayland requires Darwin";
      }
      ++ lib.optional (cfg.x11 != null && isDarwin) {
        assertion = osConfig.services.xquartz.enable;
        message = "programs.remote-control.client.x11 on Darwin requires services.xquartz";
      };

    home.packages = lib.optional (cfg.x11 != null || cfg.wayland != null) remoteControlRunners;
  };
}
