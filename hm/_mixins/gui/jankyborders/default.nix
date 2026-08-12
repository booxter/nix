{
  config,
  lib,
  osConfig,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  desktopEnvironmentEnabled = osConfig.host.userEnvironment.features.gui.enable;
  inherit (config.lib.stylix) colors;
in
{
  services.jankyborders = lib.mkIf (desktopEnvironmentEnabled && isDarwin) {
    enable = true;
    settings = {
      active_color = "glow\\(0xff${colors.base0D}\\)";
      inactive_color = "0xff${colors.base03}";
      hidpi = "on";
    };
  };
}
