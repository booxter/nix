{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf (config.host.hm.userEnvironment.preset != null) {
  home.packages = [ pkgs.glab ];
}
