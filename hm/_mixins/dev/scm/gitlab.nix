{
  lib,
  osConfig,
  pkgs,
  ...
}:
lib.mkIf osConfig.host.userEnvironment.roles.developer.enable {
  home.packages = [ pkgs.glab ];
}
