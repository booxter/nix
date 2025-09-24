{ pkgs, ... }:
{
  home.packages = with pkgs; [
    codex
    # needed by cursor for remote access
    nodejs
  ];

  programs.claude-code.enable = true;
}
