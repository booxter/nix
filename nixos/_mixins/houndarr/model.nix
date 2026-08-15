{ config, lib }:
let
  cfg = config.host.houndarr;
  apiModel = import ../web/api-model.nix { inherit config lib; };
  resolve =
    name: instance:
    instance
    // {
      inherit name;
      apiRegistration = apiModel.resolved.${instance.api} or null;
    };
in
{
  inherit cfg;
  instances = lib.mapAttrs resolve cfg.instances;
  enabledInstances = lib.filterAttrs (_: instance: instance.enable) (
    lib.mapAttrs resolve cfg.instances
  );
  webService = config.host.web.services.houndarr;
}
