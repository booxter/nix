{
  lib,
  osConfig,
  pkgs,
  ...
}:
{
  config = lib.mkIf (osConfig.host.desktop != null) {
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
