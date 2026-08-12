{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = osConfig.host.userEnvironment.features.dev;
in
lib.mkIf (cfg.enable && cfg.cli.enable) {
  home.packages = with pkgs; [
    delve
    devenv
    go
    (lima.override { withAdditionalGuestAgents = true; })
    pre-commit
    python313
  ];
}
