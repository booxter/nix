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

  home.packages =
    with pkgs;
    (
      [
        gitlab-ci-local
        jinjanator
        kind
        kubectl
        kubernetes-helm
        vault-bin
      ]
      ++ lib.optionals isDesktop [
        slack
      ]
    );
}
