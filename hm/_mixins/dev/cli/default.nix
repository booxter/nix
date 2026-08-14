{
  lib,
  osConfig,
  pkgs,
  ...
}:
lib.mkIf osConfig.host.userEnvironment.roles.developer.enable {
  home.packages = with pkgs; [
    devenv
    dive
    gitlab-ci-local
    (lima.override { withAdditionalGuestAgents = true; })
    pre-commit
    trivy
  ];
}
