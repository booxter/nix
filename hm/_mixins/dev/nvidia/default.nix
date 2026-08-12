{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  homeManagerPkgs = import ../../../pkgs pkgs;
  nvPkgs = import ./pkgs { inherit pkgs; };
in
lib.mkIf
  (
    osConfig.host.userEnvironment.features.dev.enable
    && osConfig.host.userEnvironment.features.dev.nvidia.enable
  )
  {
    home.sessionPath = [
      "$HOME/src/ngn2-ssh-utils"
      "$HOME/src/nvpn"
    ];

    home.packages = with pkgs; [
      dive
      gitlab-ci-local
      gpclient
      homeManagerPkgs.jinjanator
      nvPkgs.nico-cli
      teleport
      trivy
      vault-bin
    ];
  }
