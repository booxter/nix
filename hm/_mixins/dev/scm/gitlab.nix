{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.host.hm.env.roles.developer {
  home.packages = [ pkgs.glab ];
}
