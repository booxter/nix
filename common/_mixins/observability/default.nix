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
  imports = [
    ./assertions.nix
    ./node-exporter.nix
  ];

  options.host.observability = {
    enable = lib.mkEnableOption "host-side observability services";

    capacityProfile = lib.mkOption {
      type = lib.types.enum (builtins.attrNames facts.observability.profiles.capacity);
      default = hostSpec.observability.capacityProfile or "standard";
      readOnly = true;
      internal = true;
      description = "Capacity alert policy selected by facts.";
    };
  };

  config = lib.mkMerge [
    {
      host.observability.enable = lib.mkDefault (realmObservability != null);
    }
    (lib.mkIf (realmObservability != null) {
      host.observability.nodeExporter.mtls.enable = lib.mkDefault realmObservability.nodeExporter.mtls;
    })
  ];
}
