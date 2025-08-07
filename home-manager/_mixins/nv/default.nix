{ pkgs, isDesktop, ... }:
{
  home.sessionPath = [
    "$HOME/.nvcodex/bin"
    "$HOME/src/ngn2-ssh-utils"
    "$HOME/src/nvpn"
  ];

  home.packages =
    with pkgs;
    lib.optionals isDesktop [
      slack
    ];
}
