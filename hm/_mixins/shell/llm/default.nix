{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  shellCfg = osConfig.host.userEnvironment.features.shell;
  cfg = shellCfg.llm;
in
{
  home.packages = lib.optionals (shellCfg.enable && cfg.enable && cfg.ramalama.enable) [
    pkgs.ramalama
  ];
}
