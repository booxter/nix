{
  lib,
  pkgs,
  isDesktop,
  ...
}:
{
  home.sessionPath = [
    "$HOME/.nvcodex/bin"
    "$HOME/src/ngn2-ssh-utils"
    "$HOME/src/nvpn"
    "$HOME/.krew/bin"
  ];

  home.packages = lib.optionals isDesktop [ pkgs.slack ];
}
