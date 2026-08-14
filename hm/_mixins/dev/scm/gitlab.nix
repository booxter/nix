{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf (config.host.hm.env.preset != null) {
  home.packages = [ pkgs.glab ];
}
