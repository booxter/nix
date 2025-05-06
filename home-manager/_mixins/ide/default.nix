{ pkgs, ... }:
{
  home.packages = with pkgs; [
    code-cursor
  ];
  programs.vscode = {
    enable = true;
    mutableExtensionsDir = false; # at least for now
    profiles.default = {
      enableExtensionUpdateCheck = false;
      enableUpdateCheck = false;
    };
  };
}
