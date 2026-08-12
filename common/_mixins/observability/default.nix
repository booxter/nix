{
  config,
  lib,
  outputs,
  ...
}:
let
  lokiModel = import ./loki-model.nix {
    inherit config lib outputs;
  };
in
{
  imports = [
    ./node-exporter.nix
  ];

  options.host.observability.enable = lib.mkEnableOption "host-side observability services";

  config = lib.mkMerge [
    {
      host.observability.enable = lib.mkDefault (lokiModel.server != null);
    }
    (lib.mkIf config.host.observability.enable {
      host.observability.nodeExporter.mtls.enable = lib.mkDefault true;
    })
  ];
}
