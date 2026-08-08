{
  imports = [
    ../../../common/_mixins/observability
    ./blackbox.nix
    ./loki-client.nix
    ./node-exporter.nix
    ./prometheus-endpoints.nix
  ];
}
