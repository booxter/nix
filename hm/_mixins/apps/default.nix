{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = osConfig.host.userEnvironment.features.apps;
in
{
  imports = [
    ./email
    ./firefox
    ./spicetify
  ];

  config = lib.mkIf cfg.enable {
    home.packages =
      lib.optionals cfg.communication.enable [
        pkgs.element-desktop
        pkgs.telegram-desktop
      ]
      ++ lib.optional cfg.notes.enable pkgs.obsidian;
  };
}
