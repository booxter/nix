{
  config,
  hostInventory,
  lib,
  ...
}:
let
  realmObservability = hostInventory.realms.${config.host.realm}.services.observability or null;
in
{
  imports = [ ./node-exporter.nix ];

  options.host.observability.enable = lib.mkEnableOption "host-side observability services";

  config = lib.mkMerge [
    {
      host.observability.enable = lib.mkDefault (realmObservability != null);
      assertions = [
        {
          assertion = !config.host.observability.enable || realmObservability != null;
          message = "realm '${config.host.realm}' does not define observability services";
        }
      ];
    }
    (lib.mkIf (realmObservability != null) {
      host.observability.nodeExporter.mtls.enable = lib.mkDefault realmObservability.nodeExporter.mtls;
    })
  ];
}
