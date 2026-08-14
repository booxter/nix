{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.dev.go;
in
{
  options.host.hm.dev.go.enable = lib.mkEnableOption "Go development tools";

  config.home.packages = lib.optionals (config.host.hm.env.preset != null && cfg.enable) [
    pkgs.delve
    pkgs.go
  ];
}
