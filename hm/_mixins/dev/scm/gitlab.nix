{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  devCfg = osConfig.host.userEnvironment.features.dev;
  scmPkgs = import ./pkgs { inherit pkgs; };
in
lib.mkIf (devCfg.enable && devCfg.scm.enable) {
  home.packages = [
    pkgs.glab
    scmPkgs.glab-mr-create
  ];
}
