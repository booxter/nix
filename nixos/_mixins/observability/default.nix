{
  imports = [
    ../../../common/_mixins/observability
    ./blackbox.nix
    ./loki.nix
    ./node-exporter.nix
    ./prometheus-endpoints.nix
  ];
}
