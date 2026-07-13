{
  lib,
  ...
}:
{
  imports = [
    ./grafana
    ./loki.nix
    ./prometheus.nix
    ./unpoller.nix
    ./monitoring
  ];

  host.observability.client = {
    nodeExporter = {
      listenAddress = "127.0.0.1";
      openFirewall = lib.mkForce false;
    };
  };
}
