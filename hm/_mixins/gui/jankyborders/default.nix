{
  config,
  lib,
  osConfig,
  ...
}:
let
  inherit (osConfig.nixpkgs.hostPlatform) isDarwin;
  inherit (config.lib.stylix) colors;
  logPath = "${config.home.homeDirectory}/Library/Logs/nix-darwin/jankyborders.log";
in
{
  config = lib.mkIf isDarwin {
    services.jankyborders = {
      enable = true;
      settings = {
        active_color = "glow\\(0xff${colors.base0D}\\)";
        inactive_color = "0xff${colors.base03}";
        hidpi = "on";
      };
    };

    launchd.agents.jankyborders.config = {
      StandardOutPath = lib.mkForce logPath;
      StandardErrorPath = lib.mkForce logPath;
    };
  };
}
