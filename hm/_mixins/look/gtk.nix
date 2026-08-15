{
  lib,
  osConfig,
  pkgs,
  ...
}:
{
  config.gtk = lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && osConfig.host.desktop != null) {
    enable = true;

    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };

    cursorTheme = {
      name = "Numix-Cursor";
      package = pkgs.numix-cursor-theme;
    };

    gtk3.extraConfig.gtk-application-prefer-dark-theme = 1;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = 1;
  };
}
