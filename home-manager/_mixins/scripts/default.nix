{ pkgs, ... }:
{
  home.packages = with pkgs; [
    clean-uri-handlers
    kinit-pass
    meetings
    spot
    vpn
  ];
}
