{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  homeManagerPkgs = import ../../pkgs pkgs;
  nvPkgs = import ./pkgs { inherit pkgs; };
in
{
  home.sessionPath = [
    "$HOME/src/ngn2-ssh-utils"
    "$HOME/src/nvpn"
  ];

  home.packages =
    with pkgs;
    (
      [
        devspace
        dive
        docker-client
        gitlab-ci-local
        gpclient
        homeManagerPkgs.jinjanator
        nvPkgs.nico-cli
        teleport
        trivy
        vault-bin
      ]
      ++ lib.optionals osConfig.host.isDesktop [
        slack
        zoom-us
      ]
    );

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
