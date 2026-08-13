{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  instances = builtins.attrValues model.instances;
  selectedApis = map (instance: instance.api) instances;
  supportedInterfaces = [
    "lidarr"
    "radarr"
    "readarr"
    "sonarr"
    "whisparr-v2"
    "whisparr-v3"
  ];
in
{
  config.assertions = lib.optionals cfg.enable (
    [
      {
        assertion = cfg.instances != { };
        message = "host.houndarr.instances must select at least one application API";
      }
      {
        assertion = cfg.authProxy.gate != null;
        message = "host.houndarr.authProxy.gate must select an oauth2-proxy gate";
      }
      {
        assertion =
          cfg.authProxy.gate == null || builtins.hasAttr cfg.authProxy.gate config.host.sso.oauth2ProxyGates;
        message = "host.houndarr.authProxy.gate must select a registered oauth2-proxy gate";
      }
      {
        assertion = builtins.length selectedApis == builtins.length (lib.unique selectedApis);
        message = "host.houndarr.instances cannot select the same application API twice";
      }
      {
        assertion = builtins.hasAttr cfg.user config.host.accounts.users;
        message = "host.houndarr.user must select a registered host account";
      }
    ]
    ++ map (instance: {
      assertion = instance.apiRegistration != null;
      message = "host.houndarr.instances.${instance.name}.api must select a registered host.web.api";
    }) instances
    ++ map (instance: {
      assertion =
        instance.apiRegistration == null
        || builtins.elem instance.apiRegistration.interface supportedInterfaces;
      message = "host.houndarr.instances.${instance.name}.api selects an interface unsupported by Houndarr";
    }) instances
    ++ map (instance: {
      assertion = instance.apiRegistration == null || instance.apiRegistration.allowedCidrs != [ ];
      message = "host.web.api.${instance.api}.allowedCidrs must allow the Houndarr host";
    }) instances
  );
}
