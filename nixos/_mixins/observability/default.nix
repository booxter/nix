{
  imports = [
    ./alertmanager
    ./alertmanager-watchdog
    ./client.nix
    ./grafana
    ./lan-wan-accounting
    ./loki-server.nix
    ./prometheus
    ./unpoller.nix
    ./uptimerobot-sync
  ];
}
