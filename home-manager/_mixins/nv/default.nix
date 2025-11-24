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
        devspace
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

  programs.ssh = {
    # This file is managed by devspace (if project has useInclude = true).
    includes = [
      "devspace_config"
    ];

    # Trick devspace to think it configured the config.
    # https://github.com/devspace-sh/devspace/blob/de41dea8730c739e7b01765a3b63eb9fdba0d41c/pkg/devspace/services/ssh/config.go#L175-L180
    extraOptionOverrides = {
      "# DevSpace Start" = "";
    };
  };
}
