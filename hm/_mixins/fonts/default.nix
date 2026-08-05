{ pkgs, ... }:
{
  fonts.fontconfig.enable = true;
  home.packages = with pkgs.nerd-fonts; [
    meslo-lg
    jetbrains-mono
    hack
    fira-code
    symbols-only
  ];
}
