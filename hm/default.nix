{ osConfig, ... }:
let
  inherit (osConfig.host) isDarwin;
  username = osConfig.host.username;
in
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

  home = {
    inherit username;
    homeDirectory = if isDarwin then "/Users/${username}" else "/home/${username}";
  };

  targets.darwin.copyApps.enable = isDarwin; # populate apps dir for Spotlight
}
