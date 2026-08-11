{
  lib,
  osConfig,
  pkgs,
  ...
}:
{
  home = {
    packages = with pkgs; [
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

    sessionVariables =
      lib.optionalAttrs
        (osConfig.host.isDarwin && osConfig.host.userEnvironment.features.podmanMachine.enable)
        {
          KIND_EXPERIMENTAL_PROVIDER = "podman";
        };

    shellAliases.k = "kubectl";
  };
}
