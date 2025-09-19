{ pkgs, ... }:
{
  home.packages = with pkgs; [
    # needed by cursor for remote access
    nodejs
  ];

  programs.claude-code.enable = true;
}
