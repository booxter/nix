{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  graphical = pkgs.stdenv.hostPlatform.isDarwin || osConfig.host.desktop.enable;
in
{
  config = lib.mkIf graphical {
    fonts.fontconfig.enable = true;
    home.packages = with pkgs.nerd-fonts; [
      meslo-lg
      jetbrains-mono
      hack
      fira-code
      symbols-only
    ];
  };
}
