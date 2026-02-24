{ pkgs, ... }:
{
  environment.systemPackages = (
    map (x: x.terminfo) (
      with pkgs.pkgsBuildBuild;
      [
        kitty
        rxvt-unicode-unwrapped
        tmux
      ]
    )
  );
}
