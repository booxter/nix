{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  devCfg = osConfig.host.userEnvironment.features.dev;
in
lib.mkIf (devCfg.enable && devCfg.scm.enable) {
  home.packages = [ pkgs.glab ];
}
