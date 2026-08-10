{
  config,
  facts,
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

  options.host.observability.enable = lib.mkEnableOption "host-side observability services";

  config = lib.mkMerge [
    {
      host.observability.enable = lib.mkDefault (realmObservability != null);
    }
    (lib.mkIf (realmObservability != null) {
      host.observability.nodeExporter.mtls.enable = lib.mkDefault realmObservability.nodeExporter.mtls;
    })
  ];
}
