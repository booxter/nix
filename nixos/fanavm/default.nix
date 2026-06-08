{
  lib,
  ...
}:
{
  imports = [
    ./grafana
    ./loki.nix
    ./prometheus.nix
    ./monitoring
  ];

  sops = {
    defaultSopsFile = ../../secrets/prox-fanavm.yaml;
  };

  host.observability.client = {
    nodeExporter = {
      listenAddress = "127.0.0.1";
      openFirewall = lib.mkForce false;
    };
  };
}
