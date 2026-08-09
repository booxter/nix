{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.host) isDarwin isDesktop;
  cfg = config.programs.remote-control.client;
  remoteControlRunners = pkgs.callPackage ../remote-gui/pkgs { };
in
{
  options.programs.remote-control.client = {
    x11.enable = lib.mkEnableOption "the X11 remote nixpkgs runner";
    wayland.enable = lib.mkEnableOption "the Cocoa-Way remote nixpkgs runner";
  };

  config = {
    assertions =
      lib.optional cfg.wayland.enable {
        assertion = isDarwin && isDesktop;
        message = "programs.remote-control.client.wayland requires a Darwin desktop host";
      }
      ++ lib.optional (cfg.x11.enable && isDarwin) {
        assertion = config.programs.xquartz.enable;
        message = "programs.remote-control.client.x11 on Darwin requires programs.xquartz";
      };

    home.packages = lib.optional (cfg.x11.enable || cfg.wayland.enable) remoteControlRunners;
  };
}
