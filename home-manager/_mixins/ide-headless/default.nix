{ pkgs, ... }:
{
  home.packages = with pkgs; [
    codex
    # needed by cursor for remote access
    nodejs
  ];
}
