{ pkgs, ... }:
{
  fonts.packages = with pkgs.nerd-fonts; [
    meslo-lg
    jetbrains-mono
    hack
    fira-code
    symbols-only
  ];
}
