{
  lib,
  ...
}:
{
  system.stateVersion = "25.11";

  host.network = {
    macAddress = "bc:24:11:06:e8:8b";
    reservation = {
      enable = true;
      address = "192.168.13.110";
    };
  };

  imports = [
    ./grafana
    ./loki.nix
    ./prometheus.nix
    ./unpoller.nix
    ./monitoring
  ];

  host.observability = {
    nodeExporter = {
      listenAddress = "127.0.0.1";
      mtls.enable = false;
      openFirewall = lib.mkForce false;
    };
  };
}
