{
  config,
  lib,
  ...
}:
{
  system.stateVersion = "25.11";
  home-manager.users.${config.host.username}.home.stateVersion = "25.11";

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
