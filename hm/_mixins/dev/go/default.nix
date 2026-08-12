{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.dev.go;
in
{
  options.host.hm.dev.go.enable = lib.mkEnableOption "Go development tools";

  config.home.packages =
    lib.optionals (osConfig.host.userEnvironment.features.dev.enable && cfg.enable)
      [
        pkgs.delve
        pkgs.go
      ];
}
