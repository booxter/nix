{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.dev.k8s;
in
{
  options.host.hm.dev.k8s.enable = lib.mkEnableOption "Kubernetes development tools";

  config = lib.mkIf (osConfig.host.userEnvironment.features.dev.enable && cfg.enable) {
    home.shellAliases.k = "kubectl";

    home.packages = with pkgs; [
      devspace
      kind
      kubectl
      kubectx
      kubevirt
      (wrapHelm kubernetes-helm {
        plugins = with kubernetes-helmPlugins; [
          helm-unittest
        ];
      })
    ];

    programs.ssh = {
      # This file is managed by devspace (if project has useInclude = true).
      includes = [ "devspace_config" ];

      # Trick devspace into treating the SSH config as initialized.
      # https://github.com/devspace-sh/devspace/blob/de41dea8730c739e7b01765a3b63eb9fdba0d41c/pkg/devspace/services/ssh/config.go#L175-L180
      extraOptionOverrides."# DevSpace Start" = "";
    };
  };
}
