{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.dev.nvidia;
  homeManagerPkgs = import ../../../pkgs pkgs;
  nvPkgs = import ./pkgs { inherit pkgs; };
in
{
  options.host.hm.dev.nvidia.enable = lib.mkEnableOption "NVIDIA development environment";

  config = lib.mkIf (osConfig.host.userEnvironment.roles.developer.enable && cfg.enable) {
    home.sessionPath = [
      "$HOME/src/ngn2-ssh-utils"
      "$HOME/src/nvpn"
    ];

    home.packages = with pkgs; [
      gpclient
      homeManagerPkgs.jinjanator
      nvPkgs.nico-cli
      teleport
      vault-bin
    ];
  };
}
