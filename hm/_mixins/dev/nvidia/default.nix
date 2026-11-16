{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.dev.nvidia;
  homeManagerPkgs = import ../../../pkgs pkgs;
  nvPkgs = import ./pkgs { inherit pkgs; };
in
{
  imports = [ ./jiratui.nix ];

  options.host.hm.dev.nvidia.enable = lib.mkEnableOption "NVIDIA development environment";

  config = lib.mkIf (config.host.hm.env.roles.developer && cfg.enable) {
    # Remote hosts may not have terminfo for the local terminal emulator.
    home.shellAliases.tsh = "env TERM=xterm tsh";

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
