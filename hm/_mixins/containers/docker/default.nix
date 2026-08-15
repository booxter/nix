{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.docker;
in
{
  options.host.hm.docker.enable = lib.mkEnableOption "Docker client environment";

  config.home.packages = lib.optional cfg.enable pkgs.docker-client;
}
