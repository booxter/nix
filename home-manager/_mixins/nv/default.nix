{ pkgs, isDesktop, ... }:
{
  home.sessionPath = [
    "$HOME/.nvcodex/bin"
  ];

  home.packages =
    with pkgs; lib.optionals isDesktop [
      slack
    ];
}
