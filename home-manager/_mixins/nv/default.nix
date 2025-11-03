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
        dive
        gitlab-ci-local
        jinjanator
        kind
        kubectl
        (wrapHelm kubernetes-helm {
          plugins = with kubernetes-helmPlugins; [
            helm-unittest
          ];
        })
        trivy
        vault-bin
      ]
      ++ lib.optionals isDesktop [
        code-cursor
        slack
      ]
    );

  programs.claude-code.enable = true;
}
