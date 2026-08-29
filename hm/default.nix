{
  inputs,
  lib,
  osConfig,
  ...
}:
{
  imports = lib.optional (!osConfig.stylix.enable) inputs.stylix.homeModules.stylix ++ [
    ./_mixins/apps
    ./_mixins/containers
    ./_mixins/dev
    ./_mixins/gui
    ./_mixins/look
    ./_mixins/net
    ./_mixins/remote-control
    ./_mixins/security
    ./_mixins/shell
    ./_mixins/ssh
    ./_mixins/user
    ./_mixins/env
  ];

  # Home Manager must not add overlays when using the system package set.
  stylix.overlays.enable = false;
}
