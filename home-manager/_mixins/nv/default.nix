{ pkgs, isDesktop, ... }:
{
  home.sessionPath = [
    "$HOME/.nvcodex/bin"
    "$HOME/src/ngn2-ssh-utils"
  ];

  home.packages =
    with pkgs;
    lib.optionals isDesktop [
      slack
    ];
}
