{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.host.hm.env.roles.developer {
  home.packages = with pkgs; [
    devenv
    dive
    gitlab-ci-local
    (lima.override { withAdditionalGuestAgents = true; })
    pre-commit
    trivy
  ];
}
