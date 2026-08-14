{
  imports = [
    ../../../common/_mixins/observability
    ./alertmanager
    ./alertmanager-watchdog.nix
    ./blackbox.nix
    ./grafana
    ./loki
    ./node-exporter.nix
    ./prometheus-endpoints.nix
    ./prometheus/server.nix
    ./systemd-expectations.nix
    ./textfile-producers.nix
    ./unifi
    ./uptimerobot
  ];
}
