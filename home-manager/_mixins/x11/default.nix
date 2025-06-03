{ pkgs, ... }:
{
  home.packages = with pkgs; [
    awesome
    icewm
    windowmaker
    xarchiver
    xbill
    xchm
    xpdf
    xquartz
    xterm
  ];
}
