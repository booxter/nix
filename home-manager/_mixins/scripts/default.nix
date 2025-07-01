{ pkgs, ... }:
{
  home.packages = with pkgs; [
    clean-uri-handlers
    spot
  ];
}
