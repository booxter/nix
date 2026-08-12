{ osConfig, ... }:
{
  imports = [
    ./_mixins/apps
    ./_mixins/containers
    ./_mixins/dev
    ./_mixins/gui
    ./_mixins/net
    ./_mixins/remote
    ./_mixins/security
    ./_mixins/shell
    ./_mixins/ssh
  ];

  targets.darwin.copyApps.enable = osConfig.host.isDarwin; # populate apps dir for Spotlight
}
