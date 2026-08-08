{
  imports = [
    ./alertmanager
    ./alertmanager-watchdog
    ./client.nix
    ./grafana
    ./lan-wan-accounting
    ./loki-server.nix
    ./prometheus
    ./systemd-expectations.nix
    ./unpoller.nix
    ./uptimerobot-sync
  ];
}
