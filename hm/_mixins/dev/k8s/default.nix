{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.dev.k8s;
in
{
  options.host.hm.dev.k8s.enable = lib.mkEnableOption "Kubernetes development tools";

  config = lib.mkIf (config.host.hm.env.roles.developer && cfg.enable) {
    home.shellAliases.k = "kubectl";

    home.packages = with pkgs; [
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

  };
}
