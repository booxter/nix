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
    ./monitoring
  ];

  host.observability = {
    loki.server.enable = true;
    prometheus.server.enable = true;
    unifi.enable = true;
    nodeExporter = {
      listenAddress = "127.0.0.1";
      mtls.enable = false;
      openFirewall = lib.mkForce false;
    };
  };

  host.ups.client.server = "prx1-lab";
}
