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
    ./firefox
    ./gmailctl
    ./spicetify
    ./thunderbird.nix
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
