{ pkgs, ... }:
{
  environment.systemPackages = (
    map (x: x.terminfo) (
      with pkgs.pkgsBuildBuild;
      [
        alacritty
        kitty
        mtm
        rxvt-unicode-unwrapped
        tmux
      ]
    )
  );
}
