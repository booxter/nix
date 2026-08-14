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
  home.packages = [ pkgs.devspace ];

  programs.ssh = {
    # This file is managed by devspace (if project has useInclude = true).
    includes = [ "devspace_config" ];

    # Trick devspace into treating the SSH config as initialized.
    # https://github.com/devspace-sh/devspace/blob/de41dea8730c739e7b01765a3b63eb9fdba0d41c/pkg/devspace/services/ssh/config.go#L175-L180
    extraOptionOverrides."# DevSpace Start" = "";
  };
}
