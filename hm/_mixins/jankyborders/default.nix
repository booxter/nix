{
  config,
  lib,
  osConfig,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  inherit (config.lib.stylix) colors;
in
{
  services.jankyborders = lib.mkIf isDarwin {
    enable = true;
    settings = {
      active_color = "glow\\(0xff${colors.base0D}\\)";
      inactive_color = "0xff${colors.base03}";
      hidpi = "on";
    };
  };
}
