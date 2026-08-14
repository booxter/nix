{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  devCfg = osConfig.host.userEnvironment.features.dev;
in
lib.mkIf (osConfig.host.userEnvironment.roles.developer.enable && devCfg.scm.enable) {
  home.packages = [ pkgs.glab ];
}
