{
  lib,
  ...
}:
{
  system.stateVersion = "25.11";

  host.network = {
    macAddress = "bc:24:11:06:e8:8b";
    reservation = {
      address = "192.168.13.110";
    };
  };

  host.observability = {
    alertmanager.enable = true;
    grafana.enable = true;
    loki.server.enable = true;
    prometheus.server.enable = true;
    unifi.enable = true;
    nodeExporter = {
      listenAddress = "127.0.0.1";
      mtls.enable = false;
      openFirewall = lib.mkForce false;
    };
  };

  host.proxmox = {
    cluster = "lab";
    guest = {
      enable = true;
      cores = 8;
      memoryGiB = 16;
      diskGiB = 300;
    };
  };

  host.ups.client.server = "prx1-lab";
}
