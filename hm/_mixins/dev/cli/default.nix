{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf (config.host.hm.userEnvironment.preset != null) {
  home.packages = with pkgs; [
    devenv
    dive
    gitlab-ci-local
    (lima.override { withAdditionalGuestAgents = true; })
    pre-commit
    trivy
  ];
}
