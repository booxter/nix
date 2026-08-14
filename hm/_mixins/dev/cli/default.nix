{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = osConfig.host.userEnvironment.features.dev;
in
lib.mkIf (osConfig.host.userEnvironment.roles.developer.enable && cfg.cli.enable) {
  home.packages = with pkgs; [
    devenv
    dive
    gitlab-ci-local
    (lima.override { withAdditionalGuestAgents = true; })
    pre-commit
    trivy
  ];
}
