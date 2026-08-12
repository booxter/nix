{
  imports = [
    ../../../common/_mixins/observability
    ./alertmanager-watchdog.nix
    ./blackbox.nix
    ./loki
    ./node-exporter.nix
    ./prometheus-endpoints.nix
    ./systemd-expectations.nix
    ./unifi
  ];
}
