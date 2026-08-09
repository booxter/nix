{
  config,
  facts,
  hostSpec,
  lib,
  ...
}:
let
  realmObservability = facts.realms.${config.host.realm}.services.observability or null;
in
{
  imports = [ ./node-exporter.nix ];

  options.host.observability = {
    enable = lib.mkEnableOption "host-side observability services";

    capacityProfile = lib.mkOption {
      type = lib.types.enum (builtins.attrNames facts.observability.profiles.capacity);
      default = hostSpec.observability.capacityProfile or "standard";
      readOnly = true;
      internal = true;
      description = "Capacity alert policy selected by facts.";
    };

    thermalProfile = lib.mkOption {
      type = lib.types.enum (builtins.attrNames facts.observability.profiles.thermal);
      default =
        hostSpec.observability.thermalProfile or (if config.host.isVM then "none" else "standard");
      readOnly = true;
      internal = true;
      description = "Thermal alert policy selected by facts.";
    };
  };

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
