{
  config,
  lib,
  pkgs,
  ...
}:
{
  config.gtk = lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && config.host.hm.env.roles.workstation) {
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
