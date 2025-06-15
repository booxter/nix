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
  ] ++ (with xorg; [
    xauth
    xcalc
    xconsole
    xev
    xeyes
    xfontsel
    xkill
    xload
    xmessage
    xmore
    xvinfo
    xwininfo
    twm
  ]);
}
