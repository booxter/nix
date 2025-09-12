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

  home.packages = with pkgs; ([
    gitlab-ci-local
  ]
  ++ lib.optionals isDesktop [
    jinjanator
    kind
    kubectl
    kubernetes-helm
    slack
    vault-bin
  ]);
}
